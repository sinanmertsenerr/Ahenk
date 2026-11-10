import AhenkKit
import AppKit
import QuartzCore

// The lyric styles (Plain and Drift are in LyricStylesPlain.swift). Each builds a line's layers once (sprites drawn
// with its own font) and then, every frame, only moves, scales and fades
// them from the scene and the beat. The motion's numbers come from
// AhenkKit's LyricsStyleMath.

extension LyricStyle {
    func makeRenderer() -> LyricStyleRenderer {
        switch self {
        case .plain: PlainStyle(style: self)
        case .glitch: GlitchStyle(style: self)
        case .cinema: CinemaStyle(style: self)
        case .karaoke: KaraokeStyle(style: self)
        case .typewriter: TypewriterStyle(style: self)
        case .drift: DriftStyle(style: self)
        }
    }
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

/// The usual ink: the line's colour with a soft dark shadow under it.
private func readableInk(_ color: SRGBColor, shade: Double = 0.55, blur: Double = 8) -> LyricInk {
    LyricInk(color: color, shade: shade, shadeBlur: blur)
}

// MARK: - Karaoke

/// Two lines as on a karaoke screen: the one being sung lights up from its
/// first letter to its last (a glowing edge leads the fill), the next one
/// waits below; once sung, the line glows with the beat and moves up.
final class KaraokeStyle: LyricStyleRenderer {
    override var maxRows: Int { 2 }
    override var rowSpacing: CGFloat { 1.1 }

    private var edgeSprite: CGImage?

    override func didConfigure() {
        edgeSprite = Self.makeEdge(scale: context?.scale ?? 2)
    }

    override func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {
        let lit = context.accent(0).mixed(with: .white, amount: 0.18)
        visual.addRows("base", scale: context.scale) { sprite($0.text, ink: LyricInk(color: context.ink.mixed(with: .white, amount: 0.5), alpha: 0.62, shade: 0.5, shadeBlur: 7), for: visual) }
        let lits = visual.addRows("lit", scale: context.scale) {
            sprite($0.text, ink: LyricInk(color: lit, shade: 0.35, shadeBlur: 6, glow: 0.75, glowColor: context.accent(0), glowBlur: 9), for: visual)
        }
        // Lit rows show only their sung part: anchored at their left, cut by
        // `contentsRect` (masks would not survive offscreen rendering).
        for layer in lits {
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer.frame = frame
        }
        var edges: [CALayer] = []
        for row in visual.layout.rows {
            let edge = LyricLayers.plain()
            edge.contents = edgeSprite
            edge.contentsScale = context.scale
            let height = row.rect.height * 1.05
            edge.bounds = CGRect(x: 0, y: 0, width: height * 0.3, height: height)
            edge.opacity = 0
            visual.container.addSublayer(edge)
            edges.append(edge)
        }
        visual.extras["edge"] = edges
    }

    override func render(_ scene: LyricsScene, frame: LyricsFrame) {
        // The next line waits below; in an instrumental part it shows up
        // for the last seconds of the countdown.
        let remaining = scene.gap?.remaining
        let waiting = scene.gap == nil || (remaining ?? .infinity) < 2.5
        keep(indices(of: scene, upcoming: waiting))
        let current = scene.current.flatMap { state in visual(state.index).map { (state, $0) } }
        let previous = scene.previous.flatMap { state in visual(state.index).map { (state, $0) } }
        let next = waiting ? scene.upcoming.flatMap { index in index == scene.current?.index ? nil : visual(index) } : nil
        let enter = current?.0.enter ?? 1
        let e = LyricsEasing.outCubic(enter)
        let currentScale = mix(0.8, 1, e)
        let previousScale = current == nil ? 1 : mix(1, 0.86, e)
        let spots = stack(
            current: current.map { $0.1.height * currentScale }, previous: previous.map { $0.1.height * previousScale },
            upcoming: next.map { $0.height * 0.8 }, enter: current == nil ? (scene.previous?.exit ?? 0) : enter, spacing: 14,
            arrivingFrom: current.map { $0.1.height * 0.8 }
        )
        if let (state, visual) = current {
            fill(visual, progress: state.sung, frame: frame)
            place(visual, centerY: spots.current, scale: currentScale, opacity: mix(0.45, 1, e))
        }
        if let (state, visual) = previous {
            fill(visual, progress: 1, frame: frame)
            let fade = current == nil ? LyricsEasing.inOutCubic(state.exit) : e
            place(visual, centerY: spots.previous, scale: previousScale, opacity: CGFloat(1 - fade))
        }
        if let visual = next {
            fill(visual, progress: 0, frame: frame)
            let appear = remaining.map { 1 - LyricsEasing.unit(($0 - 0.5) / 2) } ?? LyricsEasing.unit(enter * 1.5)
            let y = current == nil ? currentCenter - (scene.gap.map { _ in (context?.size.height ?? 200) * 0.36 } ?? 0) : spots.upcoming
            place(visual, centerY: y, scale: 0.8, opacity: 0.45 * CGFloat(appear))
        }
    }

    private func fill(_ visual: LyricLineVisual, progress: Double, frame: LyricsFrame) {
        guard let lits = visual.extras["lit"], let edges = visual.extras["edge"] else { return }
        let layout = visual.layout
        let lit = KaraokeFill.litPerRow(progress: progress, counts: layout.rows.map(\.characters.count))
        let complete = progress >= 1
        for (index, row) in layout.rows.enumerated() where index < lits.count {
            let layer = lits[index]
            let spriteWidth = visual.rest(layer).size.width
            guard spriteWidth > 0 else { continue }
            let inset = (spriteWidth - row.rect.width) / 2
            let x = CGFloat(KaraokeFill.width(lit: lit[index], boundaries: row.boundaries.map(Double.init)))
            let filled = lit[index] >= Double(row.characters.count)
            let width = lit[index] <= 0 ? 0 : (filled ? spriteWidth : inset + (x - row.rect.minX))
            if visual.changed("w\(index)", Double(width), tolerance: 0.25) {
                layer.bounds = CGRect(x: 0, y: 0, width: max(0, width), height: layer.bounds.height)
                layer.contentsRect = CGRect(x: 0, y: 0, width: max(0, min(1, width / spriteWidth)), height: 1)
                layer.isHidden = width <= 0
            }
            layer.setOpacity(complete ? 0.88 + 0.12 * frame.beat : 1)
            let edge = edges[index]
            let sweeping = lit[index] > 0 && !filled
            edge.setPosition(CGPoint(x: x, y: layout.size.height - row.rect.midY))
            edge.setOpacity(sweeping ? 0.65 : 0)
        }
    }

    /// A soft vertical light that leads the fill.
    private static func makeEdge(scale: CGFloat) -> CGImage? {
        let width = Int(24 * scale), height = Int(48 * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])
        else { return nil }
        context.scaleBy(x: 1, y: CGFloat(height) / CGFloat(width))
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(width) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(width) / 2, options: [])
        return context.makeImage()
    }
}

// MARK: - Typewriter

/// Letters strike the page one after another while the line is sung, with
/// a caret that blinks when the line is typed; each new line feeds the
/// page up, the two lines before it fading above.
final class TypewriterStyle: LyricStyleRenderer {
    override var units: LyricsTypesetter.Units { .letters }
    override var rowSpacing: CGFloat { 1.12 }
    override var animatesContinuously: Bool { true }

    override func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {
        let ink = context.ink.mixed(with: SRGBColor(red: 1, green: 0.97, blue: 0.9), amount: 0.45)
        visual.addUnits(scale: context.scale) { sprite($0.text, ink: readableInk(ink, shade: 0.5, blur: 6), for: visual) }
        let caret = LyricLayers.plain()
        caret.backgroundColor = context.accent(0).mixed(with: .white, amount: 0.25).cgColor
        caret.cornerRadius = 1
        let height = (visual.layout.rows.first?.rect.height ?? 30) * 0.78
        caret.bounds = CGRect(x: 0, y: 0, width: max(2, height * 0.07), height: height)
        caret.shadowColor = CGColor(gray: 0, alpha: 1)
        caret.shadowOpacity = 0.4
        caret.shadowRadius = 3
        caret.shadowOffset = .zero
        visual.container.addSublayer(caret)
        visual.extras["caret"] = [caret]
    }

    override func render(_ scene: LyricsScene, frame: LyricsFrame) {
        guard let context else { return }
        var shown: Set<Int> = []
        let base = context.size.height * 0.4
        let gapExit = scene.gap.map { LyricsEasing.inOutCubic($0.enter) } ?? 0
        if let current = scene.current, let visual = visual(current.index) {
            shown.insert(current.index)
            type(visual, progress: current.sung, frame: frame, showsCaret: true)
            let enter = LyricsEasing.outCubic(current.enter)
            place(visual, centerY: base - (1 - CGFloat(enter)) * visual.height * 0.6, opacity: 1)
            // The page: the lines before, fed up by the new one.
            var top = base + visual.height / 2
            for back in 1...2 {
                let index = current.index - back
                guard index >= 0, sameVerse(index, current.index), let line = self.visual(index) else { continue }
                shown.insert(index)
                type(line, progress: 1, frame: frame, showsCaret: false)
                let gap: CGFloat = 10
                let target = top + gap + line.height / 2
                let from = top - visual.height + line.height / 2
                let y = mix(from, target, enter)
                let opacity = (back == 1 ? 0.52 : 0.24) * (back == 2 ? enter : 1)
                place(line, centerY: y, opacity: CGFloat(opacity))
                top = target + line.height / 2
            }
        }
        if let previous = scene.previous, scene.current == nil, let visual = visual(previous.index) {
            // The page clears for an instrumental part.
            shown.insert(previous.index)
            type(visual, progress: 1, frame: frame, showsCaret: false)
            place(visual, centerY: base + 20 * CGFloat(gapExit), opacity: CGFloat(1 - previous.exit))
        }
        keep(shown)
    }

    private func sameVerse(_ earlier: Int, _ later: Int) -> Bool {
        guard let timeline else { return false }
        return !timeline.gaps.contains { gap in
            guard let previous = gap.previousLine else { return false }
            return previous >= earlier && previous < later
        }
    }

    private func type(_ visual: LyricLineVisual, progress: Double, frame: LyricsFrame, showsCaret: Bool) {
        let count = visual.units.count
        let typed = TypewriterReveal.typed(progress: progress, count: count)
        for (index, layer) in visual.units.enumerated() {
            let strike = TypewriterReveal.strike(index: index, typed: typed)
            let base = visual.basePositions[index]
            layer.setOpacity(strike > 0 ? min(1, strike * 2.5) : 0)
            layer.setPosition(CGPoint(x: base.x, y: base.y + CGFloat(1 - strike) * 6))
            layer.setScale(CGFloat(1 + (1 - strike) * 0.28))
        }
        guard let caret = visual.extras["caret"]?.first else { return }
        guard showsCaret else {
            caret.setOpacity(0)
            return
        }
        let last = Int(typed.rounded(.down)) - 1
        let point: CGPoint
        if last >= 0, last < count {
            let unit = visual.layout.units[last]
            point = CGPoint(x: unit.rect.maxX + 3, y: visual.layout.size.height - unit.rect.midY)
        } else if let first = visual.layout.units.first {
            point = CGPoint(x: first.rect.minX - 2, y: visual.layout.size.height - first.rect.midY)
        } else {
            point = .zero
        }
        caret.setPosition(point)
        let typing = typed < Double(count)
        let blink = sin(frame.hostTime * 2 * .pi * 1.1) > -0.2 ? 1.0 : 0.12
        caret.setOpacity(typing ? 1 : blink)
    }
}

// MARK: - Glitch

/// A new line decodes out of random characters from left to right, with a
/// coloured split that widens on every onset; strong beats tear it into
/// slices for a moment; a leaving line scrambles away.
final class GlitchStyle: LyricStyleRenderer {
    override var units: LyricsTypesetter.Units { .letters }
    override var rowSpacing: CGFloat { 1.14 }
    override var animatesContinuously: Bool { true }

    private static let alphabet = Array("#%&*+/<=>?@[]{}~01$!")

    /// The random characters, drawn with `visual`'s font.
    private func glyphs(for visual: LyricLineVisual) -> [LyricSprite?] {
        guard let context else { return [] }
        let ink = readableInk(context.ink.mixed(with: .white, amount: 0.55), shade: 0.5, blur: 6)
        return Self.alphabet.map { sprite(String($0), ink: ink, for: visual) }
    }

    override func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {
        let white = context.ink.mixed(with: .white, amount: 0.55)
        visual.addRows("red", scale: context.scale) { sprite($0.text, ink: LyricInk(color: context.accent(0), alpha: 0.85, shade: 0), for: visual) }
        visual.addRows("cyan", scale: context.scale) { sprite($0.text, ink: LyricInk(color: context.accent(1), alpha: 0.85, shade: 0), for: visual) }
        visual.addUnits(scale: context.scale) { sprite($0.text, ink: readableInk(white, shade: 0.5, blur: 6), for: visual) }
        // Torn slices: bands of the whole row, shown only during a tear.
        var slices: [CALayer] = []
        for row in visual.layout.rows {
            guard let image = sprite(row.text, ink: readableInk(white, shade: 0.5, blur: 6), for: visual) else { continue }
            let frame = visual.spriteFrame(for: row.rect, sprite: image)
            for band in 0..<4 {
                let layer = LyricLayers.sprite(image, scale: context.scale)
                let share = 0.25
                layer.contentsRect = CGRect(x: 0, y: Double(band) * share, width: 1, height: share)
                layer.frame = CGRect(x: frame.minX, y: frame.minY + frame.height * CGFloat(Double(band) * share), width: frame.width, height: frame.height * CGFloat(share))
                layer.isHidden = true
                visual.container.addSublayer(layer)
                visual.remember(layer)
                slices.append(layer)
            }
        }
        visual.extras["slices"] = slices
    }

    override func render(_ scene: LyricsScene, frame: LyricsFrame) {
        keep(indices(of: scene, upcoming: false))
        let center = currentCenter
        if let current = scene.current, let visual = visual(current.index) {
            glitch(visual, sinceStart: current.sinceStart + lead, leaving: 0, frame: frame)
            // After the old line has scrambled away.
            let shows = scene.previous == nil ? current.enter > 0 : current.enter >= 0.2
            place(visual, centerY: center, opacity: shows ? 1 : 0)
        }
        if let previous = scene.previous, let visual = visual(previous.index) {
            // Gone within the first third of the glide; the new line then
            // decodes in its place.
            let exit = LyricsEasing.unit(previous.exit * 3.3)
            glitch(visual, sinceStart: 10, leaving: exit, frame: frame)
            let jitter = LyricsNoise.signed(UInt64(previous.index), Int(exit * 30)) * 7 * exit
            place(visual, centerY: center + 6 * CGFloat(exit), dx: CGFloat(jitter), opacity: CGFloat(1 - LyricsEasing.inOutCubic(exit)))
        }
    }

    private func glitch(_ visual: LyricLineVisual, sinceStart: Double, leaving: Double, frame: LyricsFrame) {
        let features = frame
        let count = visual.units.count
        let decoding = sinceStart < GlitchMotion.decodeDuration
        // Leaving: letters scramble again from the right.
        let scrambleTime = leaving > 0 ? GlitchMotion.decodeDuration * (1 - leaving) : sinceStart
        var anyScrambled = false
        let glyphs = self.glyphs(for: visual)
        for (index, layer) in visual.units.enumerated() {
            let order = leaving > 0 ? count - 1 - index : index
            if let glyph = GlitchMotion.scramble(index: order, count: count, sinceStart: scrambleTime, seed: UInt64(visual.index), alphabetSize: glyphs.count),
               let sprite = glyphs[glyph] {
                anyScrambled = true
                if (layer.contents as AnyObject?) !== (sprite.image as AnyObject) {
                    layer.contents = sprite.image
                    layer.bounds = CGRect(origin: .zero, size: sprite.size)
                }
            } else if let original = visual.sprites[index], (layer.contents as AnyObject?) !== (original.image as AnyObject) {
                layer.contents = original.image
                layer.bounds = CGRect(origin: .zero, size: original.size)
            }
        }
        let tear = leaving > 0 ? 0 : GlitchMotion.tear(beatIndex: features.beatIndex, sinceBeat: frame.sinceBeat, strength: features.beat > 0 ? max(features.beat, 0.8) : 0)
        let split = GlitchMotion.split(onset: features.onset, decoding: decoding || anyScrambled)
        for (key, sign) in [("red", -1.0), ("cyan", 1.0)] {
            for layer in visual.extras[key] ?? [] {
                let rest = visual.rest(layer).position
                layer.setPosition(CGPoint(x: Double(rest.x) + sign * split * (1 + tear * 3), y: Double(rest.y)))
                layer.setOpacity((decoding ? 0.85 : 0.7) * (1 - leaving))
            }
        }
        let slices = visual.extras["slices"] ?? []
        let tearing = tear > 0.02
        for (index, layer) in slices.enumerated() {
            if layer.isHidden == tearing { layer.isHidden = !tearing }
            guard tearing else { continue }
            let rest = visual.rest(layer).position
            let offset = GlitchMotion.sliceOffset(slice: index, beatIndex: features.beatIndex, intensity: tear, maximum: 16)
            layer.setPosition(CGPoint(x: Double(rest.x) + offset, y: Double(rest.y)))
        }
        for layer in visual.units { layer.setOpacity(tearing ? 0 : 1) }
    }
}

// MARK: - Cinema

/// A film title: the line fades in on a soft dark band, settling from a
/// slow zoom; a hairline grows under it as it is sung; lines dissolve into
/// each other. Always centred.
final class CinemaStyle: LyricStyleRenderer {
    override var maxRows: Int { 2 }
    override var tracking: CGFloat { 1.4 }
    override var rowSpacing: CGFloat { 1.16 }
    override var alwaysCentered: Bool { true }
    override var animatesContinuously: Bool { true }
    override var glide: TimeInterval { 0.9 }
    override var lead: TimeInterval { 0.35 }

    private let band = CAGradientLayer()

    override func didConfigure() {
        guard let context else { return }
        band.actions = LyricLayers.noActions
        // A wide, soft ellipse: darkest behind the words, gone at its edges.
        band.type = .radial
        band.colors = [CGColor(gray: 0, alpha: 0.46), CGColor(gray: 0, alpha: 0.32), CGColor(gray: 0, alpha: 0)]
        band.locations = [0, 0.55, 1]
        band.startPoint = CGPoint(x: 0.5, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 1)
        band.frame = CGRect(x: -context.size.width * 0.06, y: currentCenter - 90, width: context.size.width * 1.12, height: 180)
        band.opacity = 0
        root.insertSublayer(band, at: 0)
    }

    override func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {
        let ink = context.ink.mixed(with: SRGBColor(red: 1, green: 0.96, blue: 0.9), amount: 0.6)
        visual.addRows("rows", scale: context.scale) { sprite($0.text, ink: readableInk(ink, shade: 0.6, blur: 10), for: visual) }
        let line = LyricLayers.plain()
        line.backgroundColor = context.accent(0).cgColor(alpha: 0.9)
        line.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let last = visual.layout.rows.last?.rect ?? .zero
        line.bounds = CGRect(x: 0, y: 0, width: last.width, height: 1.5)
        line.position = CGPoint(x: last.midX, y: visual.layout.size.height - last.maxY - 9)
        visual.container.addSublayer(line)
        visual.extras["hairline"] = [line]
    }

    override func render(_ scene: LyricsScene, frame: LyricsFrame) {
        keep(indices(of: scene, upcoming: false))
        let center = currentCenter
        var bandOpacity = 0.0
        if let current = scene.current, let visual = visual(current.index) {
            // The new line fades in once the old one is mostly gone.
            let enter = scene.previous == nil ? current.enter : LyricsEasing.unit((current.enter - 0.35) / 0.65)
            let motion = CinemaMotion.frame(enter: enter, exit: 0, sinceStart: current.sinceStart)
            place(visual, centerY: center + CGFloat(motion.rise) - 6, scale: CGFloat(motion.scale), opacity: CGFloat(motion.opacity))
            hairline(visual, share: CinemaMotion.hairline(sung: current.sung, exit: 0))
            bandOpacity = max(bandOpacity, current.enter)
        }
        if let previous = scene.previous, let visual = visual(previous.index) {
            let motion = CinemaMotion.frame(enter: 1, exit: LyricsEasing.unit(previous.exit * 1.6), sinceStart: previous.sinceStart)
            place(visual, centerY: center + CGFloat(motion.rise), scale: CGFloat(motion.scale), opacity: CGFloat(motion.opacity))
            hairline(visual, share: CinemaMotion.hairline(sung: 1, exit: previous.exit))
            bandOpacity = max(bandOpacity, 1 - previous.exit)
        }
        band.setOpacity(bandOpacity)
    }

    private func hairline(_ visual: LyricLineVisual, share: Double) {
        guard let line = visual.extras["hairline"]?.first else { return }
        line.setAffineTransform(CGAffineTransform(scaleX: CGFloat(max(0.0001, share)), y: 1))
        line.setOpacity(share > 0.001 ? 1 : 0)
    }
}
