import AhenkKit
import AppKit
import SwiftUI

/// The artist's albums as a 3D carousel: the centre cover faces the viewer
/// with its title and "2025 · Album" under it; the others turn away and
/// stack up at the sides. Drag, swipe or scroll to browse; a side cover
/// comes to the centre when clicked; the centre one opens its songs (its
/// play button plays it). SwiftUI only redraws while it moves.
struct CoverFlowView: View {
    let model: DesktopPlayerModel

    static let geometry = CoverFlowGeometry(
        cardSide: 170, centerGap: 128, sideSpacing: 54, maxAngle: 52, sideScale: 0.8, visibleRadius: 3
    )

    var body: some View {
        Group {
            switch model.albums {
            case .loaded(let albums) where !albums.isEmpty:
                CoverFlowCarousel(model: model, albums: albums)
            case .loaded:
                message(WidgetMessage(symbol: "square.stack", text: "No albums found for this artist.".l10n))
            case .loading:
                message(WidgetMessage(text: "Loading the artist's albums…".l10n, isLoading: true))
            case .failed(let text):
                message(WidgetMessage(symbol: "wifi.exclamationmark", text: text, actionTitle: "Try Again".l10n) {
                    model.retryAlbums()
                })
            case .idle:
                message(WidgetMessage(symbol: "square.stack", text: "Play a song to see the artist's albums here.".l10n))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ content: WidgetMessage) -> some View {
        content
            .frame(width: 330, height: 150)
            .widgetGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: model.theme.glass)
            .movesWidget()
    }
}

private struct CoverFlowCarousel: View {
    let model: DesktopPlayerModel
    let albums: [CatalogAlbum]

    /// Continuous position in cards (2.5 is halfway between the third and
    /// the fourth album).
    @State private var position: Double = 0
    @State private var dragStart: Double?
    @State private var isScrolling = false
    /// The artist and the playing album the carousel last centred on.
    @State private var centredKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var geometry: CoverFlowGeometry { CoverFlowView.geometry }

    private var settleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.12)
    }

    var body: some View {
        let count = albums.count
        let centre = CoverFlowGeometry.nearestIndex(to: position, count: count)
        let isMoving = dragStart != nil || isScrolling
        VStack(spacing: 12) {
            ZStack {
                ForEach(visibleAlbums, id: \.album.id) { index, album in
                    let card = geometry.card(atOffset: Double(index) - position)
                    AlbumCoverCard(
                        album: album, side: geometry.cardSide, shade: card.shade,
                        isCentre: index == centre && !isMoving, accent: model.theme.accent,
                        onPlay: { model.playAlbum(album) }
                    )
                    .scaleEffect(card.scale)
                    .rotation3DEffect(.degrees(card.angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.42)
                    .offset(x: card.x)
                    .zIndex(card.zIndex)
                    .opacity(card.opacity)
                    .onTapGesture { tapped(index) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(album.title), \(album.yearAndKind)")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .frame(width: geometry.width + 60, height: geometry.cardSide + 16)

            caption(albums[centre])
                .id(albums[centre].id)
                .transition(.opacity)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hitArea()
        .gesture(drag(count: count))
        .background(ScrollWheelCatcher(onScroll: scrolled, onEnd: settle))
        .animation(.easeOut(duration: 0.18), value: centre)
        .onAppear { centreOnPlaying(animated: false) }
        .onChange(of: recentreKey) { centreOnPlaying(animated: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The artist's albums".l10n)
        .accessibilityScrollAction { edge in
            switch edge {
            case .leading: move(to: centre - 1)
            case .trailing: move(to: centre + 1)
            default: break
            }
        }
    }

    /// The cards near the position, with their indices.
    private var visibleAlbums: [(index: Int, album: CatalogAlbum)] {
        guard let range = geometry.visibleIndices(around: position, count: albums.count) else { return [] }
        return range.map { ($0, albums[$0]) }
    }

    private func caption(_ album: CatalogAlbum) -> some View {
        VStack(spacing: 3) {
            Text(album.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(album.yearAndKind)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
        }
        .frame(maxWidth: 360)
        .desktopTextShadow()
        .allowsHitTesting(false)
    }

    // MARK: Centring

    private var recentreKey: String {
        "\(albums.map(\.id).joined(separator: ","))|\(model.playingAlbumID ?? "")"
    }

    /// The playing song's album, else the newest release.
    private func centreOnPlaying(animated: Bool) {
        let key = recentreKey
        guard key != centredKey else { return }
        centredKey = key
        let target = model.playingAlbumID.flatMap { id in albums.firstIndex { $0.id == id } } ?? albums.count - 1
        if animated {
            withAnimation(settleAnimation) { position = Double(target) }
        } else {
            position = Double(target)
        }
    }

    // MARK: Interaction

    private func tapped(_ index: Int) {
        let centre = CoverFlowGeometry.nearestIndex(to: position, count: albums.count)
        if index == centre {
            model.open(.album(albums[index]))
        } else {
            move(to: index)
        }
    }

    private func move(to index: Int) {
        let target = min(max(0, index), albums.count - 1)
        withAnimation(settleAnimation) { position = Double(target) }
    }

    private func drag(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStart ?? position
                if dragStart == nil { dragStart = start }
                position = geometry.position(dragging: value.translation.width, from: start, count: count)
            }
            .onEnded { value in
                let target = geometry.restingIndex(position: position, velocity: value.velocity.width, count: count)
                dragStart = nil
                withAnimation(settleAnimation) { position = Double(target) }
            }
    }

    private func scrolled(_ delta: CGFloat) {
        isScrolling = true
        let last = Double(albums.count - 1)
        var next = position - Double(delta) / geometry.dragStep
        // Past the ends it moves at a third of the pace.
        if next < 0 { next = position < 0 ? position - Double(delta) / geometry.dragStep / 3 : next / 3 }
        if next > last { next = position > last ? position - Double(delta) / geometry.dragStep / 3 : last + (next - last) / 3 }
        position = max(-0.6, min(last + 0.6, next))
    }

    private func settle() {
        isScrolling = false
        move(to: CoverFlowGeometry.nearestIndex(to: position, count: albums.count))
    }
}

/// One album in the carousel: its cover, a darkening as it turns away, and
/// on the centre cover a glow in the song's colour and a play button under
/// the pointer.
private struct AlbumCoverCard: View {
    let album: CatalogAlbum
    let side: CGFloat
    let shade: Double
    let isCentre: Bool
    let accent: Color
    let onPlay: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        CoverArt(artwork: album.artwork, side: side, cornerRadius: 14)
            .overlay(shape.fill(.black.opacity(shade)))
            .overlay(alignment: .bottomTrailing) {
                if isCentre, isHovering {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.white))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .help("Play the album".l10n)
                    .accessibilityLabel("Play the album".l10n)
                }
            }
            .background {
                if isCentre {
                    shape.fill(accent.opacity(0.55))
                        .blur(radius: 26)
                        .offset(y: 10)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(0.42), radius: 12, y: 7)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.25), value: isCentre)
    }
}

/// Hands the carousel the scroll wheel and trackpad swipes over it (a local
/// event monitor: SwiftUI on macOS has no scroll events for plain views).
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> ScrollWheelCatcherView {
        ScrollWheelCatcherView()
    }

    func updateNSView(_ view: ScrollWheelCatcherView, context: Context) {
        view.onScroll = onScroll
        view.onEnd = onEnd
    }
}

final class ScrollWheelCatcherView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var monitor: Any?
    private var endTimer: DispatchWorkItem?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, MainActor.assumeIsolated({ self.handle(event) }) else { return event }
            return nil
        }
    }

    /// `true` when the event was over the carousel and used.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        let horizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        var delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        // A mouse wheel moves in lines; a trackpad in points.
        if !event.hasPreciseScrollingDeltas { delta *= 14 }
        if delta != 0 { onScroll?(delta) }
        let finished = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended
        endTimer?.cancel()
        if finished && event.momentumPhase != .changed {
            // A momentum phase may follow the fingers lifting.
            scheduleEnd(after: event.momentumPhase == .ended ? 0 : 0.12)
        } else if event.phase == [] && event.momentumPhase == [] {
            // A wheel without phases: settle when it stops.
            scheduleEnd(after: 0.16)
        }
        return true
    }

    private func scheduleEnd(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.onEnd?() }
        endTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
