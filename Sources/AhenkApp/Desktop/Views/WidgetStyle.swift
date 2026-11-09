import AhenkKit
import AppKit
import SwiftUI

// The widgets' shared look: dark glass tinted with the album (Liquid Glass
// on macOS 26, a blurred material before), white type, round icon buttons.

private struct WidgetSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Drawn into a bitmap (`--smoke --snapshots`): glass is rendered by the
    /// window server and comes out blank there, so surfaces are painted.
    var widgetSnapshot: Bool {
        get { self[WidgetSnapshotKey.self] }
        set { self[WidgetSnapshotKey.self] = newValue }
    }
}

extension View {
    /// The widgets' surface in `shape`, tinted with `tint`.
    func widgetGlass<S: InsettableShape>(_ shape: S, tint: Color) -> some View {
        modifier(WidgetGlass(shape: shape, tint: tint))
    }

    /// Clicks reach a window only where it has paint, so clear areas that
    /// should take clicks and drags (the clock, the cover flow) get a fill
    /// nobody can see.
    func hitArea() -> some View {
        background(Color.white.opacity(0.006))
    }

    /// White text with a soft shadow, readable on any wallpaper.
    func desktopTextShadow() -> some View {
        shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// Rows fade out at the bottom (and a little at the top) of a scrolling
    /// list instead of being cut off.
    func fadesScrollEdges(top: CGFloat = 8, bottom: CGFloat = 26) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
        }
    }
}

private struct WidgetGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    @Environment(\.widgetSnapshot) private var snapshot

    func body(content: Content) -> some View {
        if snapshot {
            content
                .background(shape.fill(Color(white: 0.11)).overlay(shape.fill(tint.opacity(0.55))))
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            // A faint shade under the content keeps white text readable on
            // bright wallpapers, where small glass turns almost clear.
            content
                .background(shape.fill(.black.opacity(0.14)))
                .glassEffect(.regular.tint(tint.opacity(0.5)), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        } else {
            content
                .background {
                    ZStack {
                        VisualEffectBackground()
                        shape.fill(tint.opacity(0.34))
                    }
                    .clipShape(shape)
                }
                .overlay(shape.strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
        }
    }
}

/// A dark, blurred view of what is behind the window (macOS 14–15).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // Desktop widgets are never in an active window.
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A round, borderless icon button: white, the accent when on, a soft
/// highlight under the pointer and while pressed.
struct WidgetIconButton: View {
    let symbol: String
    var pointSize: CGFloat = 14
    var side: CGFloat = 30
    var weight: Font.Weight = .semibold
    var isOn = false
    var accent: Color = .white
    var isEnabled = true
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: pointSize, weight: weight))
                .foregroundStyle(isOn ? accent : .white.opacity(isEnabled ? 0.92 : 0.32))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(isOn: isOn, accent: accent))
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shrinks a little and lights up its circle while pressed; a faint circle
/// under the pointer.
struct PressableStyle: ButtonStyle {
    var isOn = false
    var accent: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, isOn: isOn, accent: accent)
    }
}

private struct PressableBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let accent: Color
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .background {
                Circle().fill(fill)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 && isEnabled }
    }

    private var fill: Color {
        if configuration.isPressed { return .white.opacity(0.18) }
        if isOn { return accent.opacity(0.18) }
        return .white.opacity(isHovering ? 0.09 : 0)
    }
}

/// A capsule button with a symbol and a title (Play, Shuffle, Add Songs).
struct CapsuleButton: View {
    let title: String
    let symbol: String
    var filled = false
    var accent: Color = .white
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(filled ? Color.black.opacity(0.85) : .white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(filled ? accent.opacity(isHovering ? 0.9 : 1) : .white.opacity(isHovering ? 0.18 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(CapsulePressStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityLabel(title)
    }
}

private struct CapsulePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// A list row's highlight: the accent for the playing song, a faint light
/// under the pointer.
struct RowHighlight: ViewModifier {
    let isPlaying: Bool
    let accent: Color
    var cornerRadius: CGFloat = 12
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isPlaying ? accent.opacity(0.26) : .white.opacity(isHovering ? 0.075 : 0))
                    .overlay {
                        if isPlaying {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(accent.opacity(0.42), lineWidth: 0.75)
                        }
                    }
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

extension View {
    func rowHighlight(isPlaying: Bool, accent: Color, cornerRadius: CGFloat = 12) -> some View {
        modifier(RowHighlight(isPlaying: isPlaying, accent: accent, cornerRadius: cornerRadius))
    }
}

/// A section title inside a widget ("Songs", "Up Next").
struct WidgetSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .textCase(.uppercase)
            .kerning(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A calm message in the middle of an area: loading, empty, failed.
struct WidgetMessage: View {
    var symbol: String?
    let text: String
    var isLoading = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                CapsuleButton(title: actionTitle, symbol: "arrow.clockwise", action: action)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Three bars that bounce while a song plays (Core Animation at a low frame
/// rate: no SwiftUI update per frame, nothing while the window is hidden).
struct EqualizerBars: NSViewRepresentable {
    let isPlaying: Bool
    let color: Color

    func makeNSView(context: Context) -> EqualizerBarsView {
        EqualizerBarsView()
    }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.color = NSColor(color)
        view.isPlaying = isPlaying
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerBarsView, context: Context) -> CGSize? {
        CGSize(width: 14, height: 12)
    }
}

final class EqualizerBarsView: NSView {
    var isPlaying = false { didSet { if isPlaying != oldValue { refresh() } } }
    var color: NSColor = .white { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    private var bars: [CALayer] = []
    private var occlusion: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<3 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EqualizerBarsView is never decoded")
    }

    deinit {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width: CGFloat = 3
        let gap = (bounds.width - width * 3) / 2
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
        }
        CATransaction.commit()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    private var isVisible: Bool {
        window.map { $0.occlusionState.contains(.visible) } ?? false
    }

    private func refresh() {
        let animate = isPlaying && isVisible
        let rest: [CGFloat] = [0.45, 0.8, 0.6]
        for (index, bar) in bars.enumerated() {
            if animate {
                guard bar.animation(forKey: "bounce") == nil else { continue }
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.25
                bounce.toValue = 1
                bounce.duration = [0.42, 0.33, 0.5][index]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bounce.timeOffset = Double(index) * 0.13
                // A small indicator needs no more than this.
                bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
                bar.add(bounce, forKey: "bounce")
            } else {
                bar.removeAnimation(forKey: "bounce")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bar.transform = CATransform3DMakeScale(1, rest[index], 1)
                CATransaction.commit()
            }
        }
    }
}

/// Every SF Symbol the desktop widgets use (checked by `--smoke`).
enum DesktopSymbols {
    static let all = [
        "arrow.clockwise", "arrow.down.right.and.arrow.up.left", "arrow.up.left.and.arrow.down.right", "backward.fill",
        "checkmark", "checkmark.circle.fill", "chevron.down", "chevron.left", "e.square.fill", "ellipsis",
        "exclamationmark.triangle.fill", "eye.slash", "forward.fill", "gearshape", "globe", "heart", "heart.fill",
        "list.bullet", "magnifyingglass", "minus.circle", "minus.circle.fill", "moon", "moon.fill", "music.mic",
        "music.note", "music.note.list", "pause.fill", "play.fill", "plus", "quote.bubble", "quote.bubble.fill",
        "rectangle.3.group", "repeat", "repeat.1", "shuffle", "sparkles", "speaker.slash.fill", "speaker.wave.1.fill",
        "speaker.wave.2.fill", "speaker.wave.3.fill", "square.stack", "text.append",
        "text.line.first.and.arrowtriangle.forward", "wifi.exclamationmark", "xmark", "xmark.circle.fill",
    ]
}

/// "3:07" or "1:02:45".
enum DurationText {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

extension AlbumKind {
    @MainActor
    var title: String {
        switch self {
        case .album: "Album".l10n
        case .ep: "EP".l10n
        case .single: "Single".l10n
        case .compilation: "Compilation".l10n
        }
    }
}

extension CatalogAlbum {
    /// "2025 · Album" (the year without digit grouping).
    @MainActor
    var yearAndKind: String {
        guard let year else { return kind.title }
        return "\(year) \u{00B7} \(kind.title)"
    }
}

extension MusicSource {
    /// The search field's prompt for this source. Whole sentences per
    /// source, so Turkish gets the right ending for each name.
    @MainActor
    var searchPrompt: String {
        switch self {
        case .appleMusic: "Search Apple Music".l10n
        case .spotify, .spotifyWeb: "Search Spotify".l10n
        case .youtubeMusic: "Search YouTube Music".l10n
        case .soundCloud: "Search SoundCloud".l10n
        case .amazonMusic: "Search Amazon Music".l10n
        case .deezer: "Search Deezer".l10n
        case .tidal: "Search TIDAL".l10n
        case .youtube: "Search YouTube".l10n
        case .demo: "Search the demo library".l10n
        case .otherApp, .local: "Search".l10n
        }
    }

    /// The source picker's badge colour (a hint, not a logo).
    var badgeColor: Color {
        switch self {
        case .appleMusic: Color(red: 0.98, green: 0.18, blue: 0.30)
        case .spotify, .spotifyWeb: Color(red: 0.11, green: 0.73, blue: 0.33)
        case .youtubeMusic: Color(red: 0.94, green: 0.12, blue: 0.20)
        case .youtube: Color(red: 0.86, green: 0.16, blue: 0.12)
        case .soundCloud: Color(red: 1.0, green: 0.38, blue: 0.10)
        case .amazonMusic: Color(red: 0.16, green: 0.72, blue: 0.80)
        case .deezer: Color(red: 0.62, green: 0.27, blue: 0.98)
        case .tidal: Color(white: 0.55)
        case .otherApp, .local, .demo: Color(white: 0.5)
        }
    }

    /// The badge's glyph: a note for apps, a globe for sites.
    var badgeSymbol: String {
        switch self {
        case .demo: "sparkles"
        case .appleMusic, .spotify, .otherApp, .local: "music.note"
        case .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube: "globe"
        }
    }
}
