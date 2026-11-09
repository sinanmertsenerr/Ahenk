import AhenkKit
import AppKit
import SwiftUI

/// The song's position as a thin line under the title. A timer moves it
/// about one pixel per step (`ProgressSchedule`: at most four steps a
/// second), only while the song plays and the window is visible, so a
/// playing song costs SwiftUI nothing and the window server a few tiny
/// redraws a second. Click or drag to seek. While a song starts, a soft
/// light runs along the line instead.
struct ProgressLine: NSViewRepresentable {
    let snapshot: NowPlayingSnapshot?
    let isStarting: Bool
    let accent: Color
    let onSeek: (TimeInterval) -> Void

    func makeNSView(context: Context) -> ProgressLineView {
        ProgressLineView()
    }

    func updateNSView(_ view: ProgressLineView, context: Context) {
        view.onSeek = onSeek
        let state: ProgressLineView.State?
        if let snapshot, snapshot.track.duration > 0 {
            state = .init(
                duration: snapshot.track.duration, elapsed: snapshot.elapsedTime, anchor: snapshot.timestamp,
                rate: snapshot.playbackRate, canSeek: snapshot.capabilities.contains(.seek)
            )
        } else {
            state = nil
        }
        view.update(state: state, isStarting: isStarting, accent: NSColor(accent))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProgressLineView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 10)
    }
}

final class ProgressLineView: NSView {
    struct State: Equatable {
        var duration: TimeInterval
        /// Position at `anchor`.
        var elapsed: TimeInterval
        var anchor: Date
        var rate: Double
        var canSeek: Bool
    }

    var onSeek: ((TimeInterval) -> Void)?
    private var state: State?
    private var isStarting = false
    private var accent: NSColor = .white
    private var scrubFraction: Double?
    private var isHovering = false
    private var timer: Timer?
    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private let shimmer = CAGradientLayer()
    private var occlusion: NSObjectProtocol?
    private var hoverArea: NSTrackingArea?
    private static let lineHeight: CGFloat = 3
    private static let hoverLineHeight: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        track.masksToBounds = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.isHidden = true
        knob.cornerRadius = 5
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowOpacity = 0.35
        knob.shadowRadius = 2
        knob.shadowOffset = .zero
        knob.isHidden = true
        layer?.addSublayer(track)
        track.addSublayer(fill)
        track.addSublayer(shimmer)
        layer?.addSublayer(knob)
        for sublayer in [track, fill, knob, shimmer] as [CALayer] {
            sublayer.actions = [
                "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "hidden": NSNull(),
                "backgroundColor": NSNull(), "frame": NSNull(), "cornerRadius": NSNull(),
            ]
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Song position".l10n)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ProgressLineView is never decoded")
    }

    deinit {
        timer?.invalidate()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(state: State?, isStarting: Bool, accent: NSColor) {
        let changed = state != self.state || isStarting != self.isStarting || accent != self.accent
        self.state = state
        self.isStarting = isStarting
        self.accent = accent
        if changed {
            scrubFraction = nil
            refresh()
        }
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = state?.canSeek == true && !isStarting
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
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

    private func fraction(at date: Date) -> Double {
        guard let state else { return 0 }
        return ProgressSchedule.fraction(elapsed: state.elapsed, anchor: state.anchor, rate: state.rate, duration: state.duration, at: date)
    }

    /// Draws the line for now and (re)starts the steps while it moves.
    private func refresh() {
        let height = isHovering || scrubFraction != nil ? Self.hoverLineHeight : Self.lineHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        track.cornerRadius = height / 2
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        fill.position = CGPoint(x: 0, y: height / 2)
        fill.cornerRadius = height / 2
        shimmer.frame = CGRect(x: -bounds.width * 0.4, y: 0, width: bounds.width * 0.4, height: height)
        knob.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        fill.backgroundColor = accent.cgColor
        shimmer.colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.9).cgColor, accent.withAlphaComponent(0).cgColor]
        shimmer.removeAnimation(forKey: "shimmer")
        shimmer.isHidden = !isStarting
        fill.isHidden = isStarting
        knob.isHidden = scrubFraction == nil && !isHovering
        CATransaction.commit()
        step()

        timer?.invalidate()
        timer = nil
        guard isVisible, bounds.width > 0 else { return }
        if isStarting {
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -bounds.width * 0.2
            sweep.toValue = bounds.width * 1.2
            sweep.duration = 1.4
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shimmer.add(sweep, forKey: "shimmer")
            return
        }
        guard scrubFraction == nil, let state, state.rate > 0, fraction(at: Date()) < 1 else { return }
        let pixels = Double(bounds.width * (window?.backingScaleFactor ?? 2))
        let interval = ProgressSchedule.interval(duration: state.duration, pixels: pixels, rate: state.rate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        step()
        if fraction(at: Date()) >= 1 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Sets the fill and the knob for now, without animation.
    private func step() {
        let current = scrubFraction ?? fraction(at: Date())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.transform = CATransform3DMakeScale(CGFloat(max(0.0001, current)), 1, 1)
        knob.position = CGPoint(x: bounds.width * CGFloat(current), y: bounds.height / 2)
        CATransaction.commit()
        if let state {
            setAccessibilityValue(DurationText.string(state.duration * current))
        }
    }

    // MARK: Seeking

    private func scrub(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        scrubFraction = min(1, max(0, Double(point.x / max(1, bounds.width))))
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        guard let state, state.canSeek, !isStarting else { return }
        scrub(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard scrubFraction != nil else { return }
        scrub(to: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let fraction = scrubFraction, let state else { return }
        onSeek?(fraction * state.duration)
        // The hub shows the new position at once; until it arrives, the
        // line stays where it was dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.scrubFraction == fraction else { return }
            self.scrubFraction = nil
            self.refresh()
        }
    }
}
