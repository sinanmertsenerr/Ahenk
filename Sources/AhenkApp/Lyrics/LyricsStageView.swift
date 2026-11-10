import AhenkKit
import AppKit
import QuartzCore

/// What the lyrics view shows instead of (or besides) timed lines.
enum LyricsStagePhase: Equatable {
    /// Timed lines (`LyricsStageContent.timeline`).
    case lyrics
    /// Words without timing: they scroll along with the song.
    case plain([String])
    /// Looking for the lyrics.
    case loading
    /// No lines to show: the song's title with a short note.
    case message(String, symbol: String?)
}

/// Everything the view draws, except the time.
struct LyricsStageContent: Equatable {
    var phase: LyricsStagePhase = .loading
    var timeline: LyricsTimeline?
    /// Identifies the song (a new one starts afresh).
    var songID = ""
    var title = ""
    var artist = ""
    var style: LyricStyle = .fisheye
    var palette: Palette = .neutral
    var useAlbumColors = true
    var textScale: Double = 1
    var showsCover = true
    var countdown = true
}

/// Where the song is, to turn a moment into a lyric time.
struct LyricsStageClock: Equatable {
    /// The song's position at `anchor`.
    var elapsed: TimeInterval
    var anchor: Date
    /// 0 while paused.
    var rate: Double
    /// Seconds added to the position (positive shows the lines earlier).
    var offset: TimeInterval
    var duration: TimeInterval

    func position(at date: Date) -> TimeInterval {
        let position = elapsed + rate * date.timeIntervalSince(anchor)
        return duration > 0 ? min(duration, max(0, position)) : max(0, position)
    }

    func lyricTime(at date: Date) -> TimeInterval {
        position(at: date) + offset
    }

    var isRunning: Bool { rate > 0 }
}

/// Draws synced lyrics beside the album cover with Core Animation layers.
///
/// SwiftUI never redraws for it: content and the clock are set when they
/// change, and a display link moves the layers only while the view can be
/// seen and the song plays (full rate while lines glide, less in between,
/// nothing when paused, hidden or covered). Previews in Settings are
/// driven from outside (`renderPreview`).
final class LyricsStageView: NSView {
    var content = LyricsStageContent() {
        didSet { if content != oldValue { contentChanged(from: oldValue) } }
    }

    var clock: LyricsStageClock? {
        didSet {
            guard clock != oldValue else { return }
            updateRunning()
            drawSoon()
        }
    }

    var cover: CGImage? {
        didSet { if cover !== oldValue { coverLayer.contents = cover; updateCoverVisibility() } }
    }

    /// The audio the lines move with; silence means no beat motion.
    var features: (any AudioFeatureSource)?
    /// The most frames a second to draw (lighter on battery).
    var maximumFrameRate: Float = 60 {
        didSet { if maximumFrameRate != oldValue { updateRunning() } }
    }
    /// Driven by `renderPreview` instead of its own display link.
    var isPreview = false

    private let coverLayer = CALayer()
    private let coverShadow = CALayer()
    private let textArea = CALayer()
    private let scrim = CAGradientLayer()
    private var renderer: LyricStyleRenderer?
    private let gap = LyricsGapVisual()
    private let message = LyricsMessageVisual()
    private let plain = LyricsPlainVisual()
    private let sprites = LyricSpriteCache()
    private var link: CADisplayLink?
    private var occlusion: NSObjectProtocol?
    private var pendingDraw = false
    private var lastBeatIndex: Int?
    private var lastBeatTime: CFTimeInterval = -.infinity
    private var lastScene: LyricsScene?
    private(set) var framesDrawn = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.actions = LyricLayers.noActions
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for layer in [coverLayer, coverShadow, textArea, scrim] as [CALayer] {
            layer.actions = LyricLayers.noActions
        }
        coverShadow.shadowColor = CGColor(gray: 0, alpha: 1)
        coverShadow.shadowOpacity = 0.45
        coverShadow.shadowRadius = 18
        coverShadow.shadowOffset = CGSize(width: 0, height: -6)
        coverLayer.masksToBounds = true
        coverLayer.contentsGravity = .resizeAspectFill
        coverLayer.borderColor = CGColor(gray: 1, alpha: 0.12)
        coverLayer.borderWidth = 0.5
        scrim.type = .radial
        scrim.colors = [CGColor(gray: 0, alpha: 0.24), CGColor(gray: 0, alpha: 0.1), CGColor(gray: 0, alpha: 0)]
        scrim.locations = [0, 0.55, 1]
        scrim.startPoint = CGPoint(x: 0.5, y: 0.5)
        scrim.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(coverShadow)
        root.addSublayer(coverLayer)
        root.addSublayer(scrim)
        root.addSublayer(textArea)
        textArea.addSublayer(message.root)
        textArea.addSublayer(plain.root)
        textArea.addSublayer(gap.root)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LyricsStageView is never decoded")
    }

    deinit {
        link?.invalidate()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    /// Clicks and drags go to the SwiftUI view around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    // MARK: Layout

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sprites.removeAll()
        rebuild()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Lays out the cover and the text area and hands the style its context.
    private func rebuild() {
        let bounds = self.bounds
        guard bounds.width > 20, bounds.height > 20 else { return }
        let textScale = content.textScale
        let margin = CGFloat(LyricsLayout.scaled(LyricsLayout.margin, textScale: min(1, textScale)))
        let side = CGFloat(LyricsLayout.coverSide(textScale: textScale))
        let gapWidth = CGFloat(LyricsLayout.scaled(LyricsLayout.coverGap, textScale: (textScale + 2) / 3))
        let showsCover = content.showsCover && bounds.width > side * 2
        let coverFrame = CGRect(x: margin, y: (bounds.height - side) / 2, width: side, height: side)
        let textX = showsCover ? coverFrame.maxX + gapWidth : margin
        let area = CGRect(x: textX, y: margin * 0.5, width: max(40, bounds.width - textX - margin), height: max(40, bounds.height - margin))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coverLayer.frame = coverFrame
        coverLayer.cornerRadius = side * 0.08
        coverShadow.frame = coverFrame
        coverShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: coverFrame.size), cornerWidth: side * 0.08, cornerHeight: side * 0.08, transform: nil)
        coverLayer.contentsScale = scale
        textArea.frame = area
        scrim.frame = area.insetBy(dx: -area.width * 0.08, dy: -area.height * 0.12)
        updateCoverVisibility()

        let colors = LyricsColors(palette: content.palette, useAlbumColors: content.useAlbumColors)
        let context = LyricsRenderContext(
            size: area.size, scale: scale, centered: !showsCover, textScale: CGFloat(textScale), ink: colors.ink,
            accents: colors.accents, sprites: sprites
        )
        if renderer?.style != content.style {
            renderer?.root.removeFromSuperlayer()
            let renderer = content.style.makeRenderer()
            textArea.insertSublayer(renderer.root, below: gap.root)
            self.renderer = renderer
        }
        renderer?.root.frame = CGRect(origin: .zero, size: area.size)
        renderer?.configure(context, timeline: content.timeline)
        gap.configure(context: context, style: content.style, title: content.title, artist: content.artist)
        message.configure(context: context, style: content.style, title: content.title, artist: content.artist, phase: content.phase)
        plain.configure(context: context, style: content.style, phase: content.phase, note: "Not synced".l10n)
        CATransaction.commit()
        lastScene = nil
        updateRunning()
        drawSoon()
    }

    private func updateCoverVisibility() {
        let shows = content.showsCover && cover != nil && bounds.width > CGFloat(LyricsLayout.coverSide(textScale: content.textScale)) * 2
        coverLayer.isHidden = !shows
        coverShadow.isHidden = !shows
    }

    private func contentChanged(from old: LyricsStageContent) {
        if content.songID != old.songID {
            lastBeatIndex = nil
        }
        rebuild()
        setAccessibilityLabel([content.title, content.artist].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    // MARK: Running

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateRunning()
                    self?.drawSoon()
                }
            }
        }
        updateRunning()
        drawSoon()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRunning()
        drawSoon()
    }

    var isVisibleOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible) || (Self.drawsWhenCovered && window.isVisible)
    }

    /// `--draw-covered` (demo only): keep drawing while app windows cover
    /// the lyrics, for captures and measurements.
    static var drawsWhenCovered = false

    private var hasMovingContent: Bool {
        switch content.phase {
        case .lyrics: content.timeline.map { !$0.isEmpty } ?? false
        case .plain: true
        case .loading, .message: false
        }
    }

    /// Starts or stops the display link.
    private func updateRunning() {
        let wanted = !isPreview && isVisibleOnScreen && hasMovingContent && (clock?.isRunning ?? false)
        if wanted, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            setRate(fast: true)
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    private var currentRate: Float = 0

    private func setRate(fast: Bool) {
        guard let link else { return }
        let steady: Float = (renderer?.animatesContinuously ?? false) ? 30 : 20
        let rate = fast ? maximumFrameRate : min(maximumFrameRate, steady)
        guard rate != currentRate else { return }
        currentRate = rate
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 15), maximum: rate, preferred: rate)
    }

    @objc private func tick(_ link: CADisplayLink) {
        draw(atHostTime: link.targetTimestamp)
    }

    /// One frame soon (content, size or the clock changed).
    private func drawSoon() {
        guard !pendingDraw, !isPreview else { return }
        pendingDraw = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDraw = false
            self.draw(atHostTime: CACurrentMediaTime())
        }
    }

    /// Draws the moment at `hostTime` (`CACurrentMediaTime` base).
    func draw(atHostTime hostTime: CFTimeInterval) {
        let date = Date().addingTimeInterval(hostTime - CACurrentMediaTime())
        let time = clock?.lyricTime(at: date) ?? 0
        draw(lyricTime: time, hostTime: hostTime, isPlaying: clock?.isRunning ?? false, position: clock.map { ($0.position(at: date), $0.duration) })
    }

    /// Previews: the invented lines at `elapsed` seconds into their loop.
    func renderPreview(elapsed: TimeInterval, hostTime: CFTimeInterval) {
        draw(lyricTime: DemoCatalog.previewTime(elapsed: elapsed), hostTime: hostTime, isPlaying: true, position: nil)
    }

    /// Draws the lyrics at a lyric time (also used by offscreen checks).
    func draw(lyricTime time: TimeInterval, hostTime: CFTimeInterval, isPlaying: Bool, position: (TimeInterval, TimeInterval)?) {
        var features = isPlaying ? (features?.features(at: hostTime) ?? .silence) : .silence
        if isPreview, features.isSilent { features = DemoBeat.features(at: time) }
        if features.beatIndex != lastBeatIndex {
            if lastBeatIndex != nil, features.beat > 0 { lastBeatTime = hostTime }
            lastBeatIndex = features.beatIndex
        }
        let frame = LyricsFrame(time: time, hostTime: hostTime, features: features, sinceBeat: hostTime - lastBeatTime, isPlaying: isPlaying)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch content.phase {
        case .lyrics:
            if let timeline = content.timeline {
                let scene = timeline.scene(at: time, glide: renderer?.glide ?? LyricsScene.glide, lead: renderer?.lead ?? LyricsScene.lead)
                renderer?.render(scene, frame: frame)
                gap.render(scene.gap, frame: frame, countdown: content.countdown)
                setRate(fast: scene.isGliding)
                lastScene = scene
            }
            message.root.isHidden = true
            plain.root.isHidden = true
            renderer?.root.isHidden = false
        case .plain:
            plain.root.isHidden = false
            plain.render(position: position, frame: frame)
            message.root.isHidden = true
            renderer?.root.isHidden = true
            gap.render(nil, frame: frame, countdown: false)
        case .loading, .message:
            message.root.isHidden = false
            plain.root.isHidden = true
            renderer?.root.isHidden = true
            gap.render(nil, frame: frame, countdown: false)
        }
        let pulse = isPlaying && !coverLayer.isHidden ? 1 + 0.012 * CGFloat(features.beat) : 1
        coverLayer.setScale(pulse)
        coverShadow.setScale(pulse)
        CATransaction.commit()
        framesDrawn += 1
    }

    /// The line on screen now (accessibility and checks).
    var currentLineIndex: Int? { lastScene?.current?.index }
    var currentScene: LyricsScene? { lastScene }
    var isAnimating: Bool { link != nil }
}

// MARK: - Instrumental parts

/// The instrumental part: a music note in a ring that empties until the
/// next line, the seconds left under it; before the first line, the song's
/// title and artist above it; after the last line, the note alone.
final class LyricsGapVisual {
    let root = CALayer()
    private let title = LyricLayers.plain()
    private let artist = LyricLayers.plain()
    private let note = LyricLayers.plain()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let digits = LyricLayers.plain()
    private var context: LyricsRenderContext?
    private var style: LyricStyle = .fisheye
    private var shownNumber: Int?
    private var ringSize: CGFloat = 64

    init() {
        root.actions = LyricLayers.noActions
        root.anchorPoint = .zero
        for shape in [track, ring] {
            shape.actions = LyricLayers.noActions
            shape.fillColor = nil
            shape.lineCap = .round
        }
        track.strokeColor = CGColor(gray: 1, alpha: 0.16)
        [track, ring, note, digits, title, artist].forEach { root.addSublayer($0) }
        root.opacity = 0
    }

    func configure(context: LyricsRenderContext, style: LyricStyle, title text: String, artist byline: String) {
        self.context = context
        self.style = style
        root.frame = CGRect(origin: .zero, size: context.size)
        ringSize = 64 * min(1.3, max(0.75, context.textScale))
        let font = LyricsFonts.font(for: style, looking: 30 * context.textScale)
        let small = LyricsFonts.font(for: style, looking: 16 * context.textScale)
        setSprite(title, context.sprites.sprite(text, font: font, ink: LyricInk(color: context.ink, shade: 0.55, shadeBlur: 8), scale: context.scale))
        setSprite(artist, context.sprites.sprite(byline, font: small, ink: LyricInk(color: context.ink, alpha: 0.72, shade: 0.55, shadeBlur: 6), scale: context.scale))
        let accent = context.accent(0)
        ring.strokeColor = accent.cgColor
        ring.lineWidth = max(2.5, ringSize * 0.045)
        track.lineWidth = ring.lineWidth
        let path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: ringSize, height: ringSize), transform: nil)
        // Starts at the top and empties clockwise.
        var flip = CGAffineTransform(translationX: ringSize / 2, y: ringSize / 2).rotated(by: .pi / 2).scaledBy(x: -1, y: 1).translatedBy(x: -ringSize / 2, y: -ringSize / 2)
        let rotated = path.copy(using: &flip) ?? path
        for shape in [track, ring] {
            shape.bounds = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
            shape.path = rotated
        }
        let noteImage = LyricsSymbols.image("music.note", pointSize: ringSize * 0.42, color: accent.mixed(with: .white, amount: 0.35), scale: context.scale)
        note.contents = noteImage?.image
        note.contentsScale = context.scale
        note.bounds = CGRect(origin: .zero, size: noteImage?.size ?? .zero)
        shownNumber = nil
        digits.contents = nil
    }

    private func setSprite(_ layer: CALayer, _ sprite: LyricSprite?) {
        layer.contents = sprite?.image
        layer.contentsScale = context?.scale ?? 2
        layer.bounds = CGRect(origin: .zero, size: sprite?.size ?? .zero)
    }

    func render(_ state: LyricsScene.GapState?, frame: LyricsFrame, countdown: Bool) {
        guard let state, let context else {
            root.setOpacity(0)
            return
        }
        let size = context.size
        let visibility = LyricsEasing.outCubic(state.enter) * (1 - LyricsEasing.inOutCubic(state.exit))
        root.setOpacity(visibility)
        guard visibility > 0.001 else { return }
        let centerX = context.centered ? size.width / 2 : ringSize / 2 + 8
        let hop = CGFloat(LyricsCountdown.hop(beatPhase: frame.beatPhase, beat: frame.beat, amplitude: 3))
        let showsRing = countdown && state.remaining != nil
        let isIntro = state.kind == .intro
        let titleHeight = isIntro ? title.bounds.height + artist.bounds.height * 0.8 : 0
        let ringCenterY = isIntro ? size.height * 0.5 - titleHeight / 2 - 4 : size.height * 0.54
        let ringCenter = CGPoint(x: centerX, y: ringCenterY)
        let appear = CGFloat(0.85 + 0.15 * LyricsEasing.outBack(state.enter))

        track.isHidden = !showsRing
        ring.isHidden = !showsRing
        track.setPosition(ringCenter)
        ring.setPosition(ringCenter)
        track.setScale(appear)
        ring.setScale(appear)
        if showsRing {
            let left = LyricsCountdown.ring(fraction: state.fraction)
            if abs(Double(ring.strokeEnd) - left) > 0.001 { ring.strokeEnd = CGFloat(left) }
        }
        note.setPosition(CGPoint(x: ringCenter.x, y: ringCenter.y + hop))
        note.setScale(appear * (1 + 0.06 * CGFloat(frame.beat)))
        note.setOpacity(state.kind == .outro ? 0.55 : 1)

        let number = showsRing ? state.countdown : nil
        if number != shownNumber {
            shownNumber = number
            if let number, number > 0 {
                let font = LyricsFonts.font(for: style, looking: 17 * context.textScale)
                let sprite = context.sprites.sprite(String(number), font: font, ink: LyricInk(color: context.ink, alpha: 0.85, shade: 0.5, shadeBlur: 6), scale: context.scale)
                digits.contents = sprite?.image
                digits.contentsScale = context.scale
                digits.bounds = CGRect(origin: .zero, size: sprite?.size ?? .zero)
            } else {
                digits.contents = nil
            }
        }
        digits.setPosition(CGPoint(x: ringCenter.x, y: ringCenter.y - ringSize / 2 - digits.bounds.height * 0.32 - 4))

        title.isHidden = !isIntro
        artist.isHidden = !isIntro
        if isIntro {
            let top = ringCenterY + ringSize / 2 + 12
            let x = context.centered ? size.width / 2 : title.bounds.width / 2 - 6
            artist.setPosition(CGPoint(x: context.centered ? size.width / 2 : artist.bounds.width / 2 - 4, y: top + artist.bounds.height / 2 - 6))
            title.setPosition(CGPoint(x: x, y: top + artist.bounds.height * 0.62 + title.bounds.height / 2 - 6))
        }
    }
}

// MARK: - Messages

/// Loading, "no lyrics", "instrumental", "could not load": the song's title
/// in the style's font with a short line under it, and a quiet animation
/// where one fits (pulsing dots while loading). Drawn once; Core Animation
/// runs the pulse, no display link.
final class LyricsMessageVisual {
    let root = CALayer()
    private let title = LyricLayers.plain()
    private let artist = LyricLayers.plain()
    private let caption = LyricLayers.plain()
    private let symbol = LyricLayers.plain()
    private var dots: [CALayer] = []

    init() {
        root.actions = LyricLayers.noActions
        root.anchorPoint = .zero
        [title, artist, caption, symbol].forEach { root.addSublayer($0) }
        for _ in 0..<3 {
            let dot = LyricLayers.plain()
            root.addSublayer(dot)
            dots.append(dot)
        }
    }

    func configure(context: LyricsRenderContext, style: LyricStyle, title text: String, artist byline: String, phase: LyricsStagePhase) {
        root.frame = CGRect(origin: .zero, size: context.size)
        let font = LyricsFonts.font(for: style, looking: 32 * context.textScale)
        let small = LyricsFonts.font(for: style, looking: 17 * context.textScale)
        let fitted = Self.fitted(font, text: text, width: context.size.width)
        let titleSprite = context.sprites.sprite(text, font: fitted, ink: LyricInk(color: context.ink, shade: 0.55, shadeBlur: 8), scale: context.scale)
        let artistSprite = context.sprites.sprite(byline, font: Self.fitted(small, text: byline, width: context.size.width), ink: LyricInk(color: context.ink, alpha: 0.7, shade: 0.55, shadeBlur: 6), scale: context.scale)
        var captionText = ""
        var symbolName: String?
        var loading = false
        switch phase {
        case .loading:
            loading = true
        case .message(let text, let name):
            captionText = text
            symbolName = name
        case .lyrics, .plain:
            break
        }
        let captionFont = NSFont.systemFont(ofSize: 13.5 * min(1.3, max(0.85, context.textScale)), weight: .semibold)
        let captionSprite = captionText.isEmpty ? nil : context.sprites.sprite(captionText, font: captionFont, ink: LyricInk(color: .white, alpha: 0.78, shade: 0.6, shadeBlur: 6), scale: context.scale)
        let symbolImage = symbolName.flatMap { LyricsSymbols.image($0, pointSize: 15 * min(1.3, max(0.85, context.textScale)), color: context.accent(0).mixed(with: .white, amount: 0.3), scale: context.scale) }
        for (layer, sprite) in [(title, titleSprite), (artist, artistSprite), (caption, captionSprite)] {
            layer.contents = sprite?.image
            layer.contentsScale = context.scale
            layer.bounds = CGRect(origin: .zero, size: sprite?.size ?? .zero)
        }
        symbol.contents = symbolImage?.image
        symbol.contentsScale = context.scale
        symbol.bounds = CGRect(origin: .zero, size: symbolImage?.size ?? .zero)

        // A block: title, artist, then the caption (or the dots), centred
        // vertically, aligned like the lines.
        let size = context.size
        let titleHeight = (titleSprite?.size.height ?? 0) - 2 * (titleSprite?.inset ?? 0)
        let artistHeight = (artistSprite?.size.height ?? 0) - 2 * (artistSprite?.inset ?? 0)
        let captionHeight: CGFloat = 26
        let block = titleHeight + artistHeight + captionHeight + 10
        var y = size.height / 2 + block / 2
        func place(_ layer: CALayer, height: CGFloat, width: CGFloat, inset: CGFloat) {
            let x = context.centered ? size.width / 2 : width / 2 - inset
            layer.position = CGPoint(x: x, y: y - height / 2)
            y -= height
        }
        place(title, height: titleHeight, width: title.bounds.width, inset: titleSprite?.inset ?? 0)
        place(artist, height: artistHeight + 4, width: artist.bounds.width, inset: artistSprite?.inset ?? 0)
        y -= 6
        let rowCenter = y - captionHeight / 2
        let symbolWidth = symbol.bounds.width
        let captionWidth = caption.bounds.width - 2 * (captionSprite?.inset ?? 0)
        let total = symbolWidth + (symbolWidth > 0 ? 6 : 0) + captionWidth
        let start = context.centered ? size.width / 2 - total / 2 : 0
        symbol.position = CGPoint(x: start + symbolWidth / 2, y: rowCenter)
        caption.position = CGPoint(x: start + symbolWidth + (symbolWidth > 0 ? 6 : 0) + captionWidth / 2, y: rowCenter)

        let dotSize: CGFloat = 7 * min(1.3, max(0.85, context.textScale))
        let dotsStart = context.centered ? size.width / 2 - dotSize * 2 : dotSize / 2 + 2
        for (index, dot) in dots.enumerated() {
            dot.isHidden = !loading
            dot.removeAllAnimations()
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = context.accent(index).mixed(with: .white, amount: 0.3).cgColor
            dot.position = CGPoint(x: dotsStart + CGFloat(index) * dotSize * 2, y: rowCenter)
            guard loading else { continue }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
            dot.add(pulse, forKey: "pulse")
        }
    }

    /// `font`, smaller if needed so `text` fits `width` on one row.
    static func fitted(_ font: NSFont, text: String, width: CGFloat) -> NSFont {
        let measured = NSAttributedString(string: text, attributes: [.font: font]).size().width
        guard measured > width * 0.96, measured > 0 else { return font }
        let size = max(10, font.pointSize * width * 0.96 / measured)
        return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }
}

// MARK: - Plain lyrics

/// Words without timing: shown in the style's font at a smaller size and
/// scrolled at the song's pace (the middle line is the brightest), with a
/// note that they are not synced.
final class LyricsPlainVisual {
    let root = CALayer()
    private let column = LyricLayers.plain()
    private let note = LyricLayers.plain()
    private var rows: [CALayer] = []
    private var height: CGFloat = 0
    private var size: CGSize = .zero

    init() {
        root.actions = LyricLayers.noActions
        root.anchorPoint = .zero
        root.masksToBounds = true
        column.anchorPoint = .zero
        root.addSublayer(column)
        root.addSublayer(note)
    }

    func configure(context: LyricsRenderContext, style: LyricStyle, phase: LyricsStagePhase, note text: String) {
        rows.forEach { $0.removeFromSuperlayer() }
        rows = []
        size = context.size
        root.frame = CGRect(origin: .zero, size: context.size)
        guard case .plain(let lines) = phase else { return }
        let font = LyricsFonts.font(for: style, looking: 22 * context.textScale)
        var y: CGFloat = 0
        var placed: [(CALayer, CGFloat)] = []
        for line in lines.prefix(160) {
            let fitted = LyricsMessageVisual.fitted(font, text: line, width: context.size.width)
            guard let sprite = context.sprites.sprite(line, font: fitted, ink: LyricInk(color: context.ink, shade: 0.55, shadeBlur: 6), scale: context.scale) else { continue }
            let layer = LyricLayers.sprite(sprite, scale: context.scale)
            let rowHeight = sprite.size.height - 2 * sprite.inset
            let x = context.centered ? context.size.width / 2 : sprite.size.width / 2 - sprite.inset
            placed.append((layer, y + rowHeight / 2))
            layer.position = CGPoint(x: x, y: 0)
            column.addSublayer(layer)
            rows.append(layer)
            y += rowHeight * 1.25
        }
        height = y
        // Rows go downwards from the column's top.
        for (layer, center) in placed {
            layer.position = CGPoint(x: layer.position.x, y: height - center)
        }
        column.bounds = CGRect(x: 0, y: 0, width: context.size.width, height: max(1, height))
        let caption = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let sprite = context.sprites.sprite(text, font: caption, ink: LyricInk(color: .white, alpha: 0.6, shade: 0.6, shadeBlur: 5), scale: context.scale)
        note.contents = sprite?.image
        note.contentsScale = context.scale
        note.bounds = CGRect(origin: .zero, size: sprite?.size ?? .zero)
        note.position = CGPoint(x: context.centered ? context.size.width / 2 : (sprite?.size.width ?? 0) / 2 - (sprite?.inset ?? 0), y: 8)
    }

    func render(position: (TimeInterval, TimeInterval)?, frame: LyricsFrame) {
        guard height > 0 else { return }
        let progress = position.map { $0.1 > 0 ? $0.0 / $0.1 : 0 } ?? 0
        // The column's point at `progress` sits in the middle.
        let focus = CGFloat(progress) * height
        let top = size.height * 0.55 + focus
        column.setPosition(CGPoint(x: 0, y: top - height))
        // Brightest in the middle, gone before the edges (and the note).
        let reach = size.height * 0.46
        for layer in rows {
            let distance = abs((top - height + layer.position.y) - size.height * 0.55)
            let fade = max(0, 1 - Double(distance / reach))
            layer.setOpacity(pow(fade, 1.4))
        }
    }
}

/// SF Symbols as tinted images for layers.
enum LyricsSymbols {
    static func image(_ name: String, pointSize: CGFloat, color: SRGBColor, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color)]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        let padding: CGFloat = 6
        let size = CGSize(width: ceil(symbol.size.width + 2 * padding), height: ceil(symbol.size.height + 2 * padding))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 4
        shadow.set()
        symbol.draw(in: NSRect(x: padding, y: padding, width: symbol.size.width, height: symbol.size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return nil }
        return (image, size)
    }
}
