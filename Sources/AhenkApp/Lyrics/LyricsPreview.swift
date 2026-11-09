import AhenkKit
import AppKit
import QuartzCore
import SwiftUI

/// A style's live miniature for Settings › Lyrics: invented lines looping
/// in that style (with a short instrumental part and its countdown), in the
/// colours of the song that plays.
///
/// Drawn by `LyricsPreviewClock` only while the tile is on screen and
/// scrolled into view; SwiftUI never redraws it per frame.
final class LyricsPreviewView: NSView {
    let stage = LyricsStageView(frame: .zero)
    private var occlusion: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.1, blue: 0.14, alpha: 1).cgColor
        stage.isPreview = true
        addSubview(stage)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LyricsPreviewView is never decoded")
    }

    deinit {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        stage.frame = bounds
        LyricsPreviewClock.shared.drawSoon(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRegistration() }
            }
        }
        updateRegistration()
        LyricsPreviewClock.shared.drawSoon(self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRegistration()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRegistration()
    }

    private func updateRegistration() {
        if let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor {
            LyricsPreviewClock.shared.add(self)
        } else {
            LyricsPreviewClock.shared.remove(self)
        }
    }

    /// Scrolled into view (the gallery sits in a scrolling form).
    var isInView: Bool {
        window != nil && !visibleRect.isEmpty && bounds.width >= 20 && bounds.height >= 20
    }
}

/// One display link at 30 fps for every visible preview, running only while
/// one is on screen.
@MainActor
final class LyricsPreviewClock: NSObject {
    static let shared = LyricsPreviewClock()

    private var views: [ObjectIdentifier: Weak] = [:]
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var pending: [Weak] = []

    private struct Weak {
        weak var view: LyricsPreviewView?
    }

    static let framesPerSecond: Float = 30

    func add(_ view: LyricsPreviewView) {
        views[ObjectIdentifier(view)] = Weak(view: view)
        guard link == nil else { return }
        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let fps = Self.framesPerSecond
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func remove(_ view: LyricsPreviewView) {
        views[ObjectIdentifier(view)] = nil
        if views.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    /// One frame soon for `view` (a new style, a first frame).
    func drawSoon(_ view: LyricsPreviewView) {
        let scheduled = !pending.isEmpty
        pending.append(Weak(view: view))
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let views = self.pending.compactMap(\.view)
            self.pending = []
            let now = CACurrentMediaTime()
            for view in views { view.stage.renderPreview(elapsed: now - self.start, hostTime: now) }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        views = views.filter { $0.value.view != nil }
        guard !views.isEmpty else {
            link.invalidate()
            self.link = nil
            return
        }
        let time = link.targetTimestamp
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in views.values.compactMap(\.view) where view.isInView {
            view.stage.renderPreview(elapsed: time - start, hostTime: time)
        }
        CATransaction.commit()
    }
}

/// SwiftUI wrapper for one preview.
struct LyricsPreview: NSViewRepresentable {
    let style: LyricStyle
    let palette: Palette
    let useAlbumColors: Bool
    let language: AppLanguage

    func makeNSView(context: Context) -> LyricsPreviewView {
        LyricsPreviewView(frame: .zero)
    }

    func updateNSView(_ view: LyricsPreviewView, context: Context) {
        let turkish = language == .turkish
        let lyrics = DemoCatalog.previewLyrics(turkish: turkish)
        let song = DemoCatalog.songs[turkish ? 3 : 0]
        view.stage.content = LyricsStageContent(
            phase: .lyrics,
            timeline: LyricsTimeline(lyrics, minimumGap: DemoCatalog.previewMinimumGap),
            songID: "preview-\(language.rawValue)",
            title: song.track.title,
            artist: song.track.artist,
            style: style,
            palette: palette,
            useAlbumColors: useAlbumColors,
            textScale: 0.36,
            showsCover: false,
            countdown: true
        )
        LyricsPreviewClock.shared.drawSoon(view)
    }
}

/// Every style as a live miniature with its name and typeface; clicking one
/// picks it.
struct LyricsStyleGallery: View {
    @Binding var selection: LyricStyle
    let palette: Palette
    let useAlbumColors: Bool
    let language: AppLanguage

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(LyricStyle.allCases) { style in
                Button {
                    selection = style
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        LyricsPreview(style: style, palette: palette, useAlbumColors: useAlbumColors, language: language)
                            .aspectRatio(2.1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(style == selection ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: style == selection ? 2.5 : 1)
                            }
                        HStack(spacing: 6) {
                            Text(style.title)
                                .font(.callout)
                                .fontWeight(style == selection ? .semibold : .regular)
                            Text(LyricsFonts.face(for: style).name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(style == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
