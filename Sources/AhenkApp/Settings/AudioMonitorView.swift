import AhenkKit
import AppKit
import SwiftUI

/// Settings › Sound's live analysis: the 32-band spectrum, the level and
/// the five bands, a beat light that swells on every beat (its ring
/// brightens on every onset), the tempo and whether it has settled.
///
/// Built from Core Animation layers: each frame only moves solid layers
/// (composited on the GPU, nothing is rasterized) and text layers change
/// only when their text does. It follows the ticker (30 fps) only while
/// its window is visible and something plays; SwiftUI never re-renders per
/// frame (Step 1: a per-frame SwiftUI update in this Form cost tens of
/// percent CPU).
final class AudioMonitorView: NSView {
    var ticker: AudioFeatureTicker? {
        didSet { updateSubscription() }
    }
    /// Level, sub-bass, bass, low-mid, mid, high.
    var meterTitles: [String] = [] {
        didSet {
            guard meterTitles != oldValue else { return }
            for (layer, title) in zip(meterLabels, meterTitles) { layer.string = title }
        }
    }
    /// Shown over the empty spectrum while nothing is analysed.
    var idleText = "" {
        didSet { if idleText != oldValue { render() } }
    }
    var bpmText: (Float) -> String = { _ in "" } {
        didSet { formattedBPM = -1 }
    }
    var searchingText = "" {
        didSet { if searchingText != oldValue { render() } }
    }
    var steadyText = "" {
        didSet { if steadyText != oldValue { render() } }
    }

    static let height: CGFloat = 132
    private static let beatColumnWidth: CGFloat = 108
    private static let meterHeight: CGFloat = 34

    private var features = AudioFeatures.silence
    private var subscription: AudioFeatureSubscription?
    private var occlusionObserver: NSObjectProtocol?
    private let bars = (0..<AudioFeatures.spectrumCount).map { _ in CALayer() }
    private let meterTracks = (0..<6).map { _ in CALayer() }
    private let meterFills = (0..<6).map { _ in CALayer() }
    private let meterLabels = (0..<6).map { _ in CATextLayer() }
    private let ring = CAShapeLayer()
    private let pulse = CALayer()
    private let tempoLabel = CATextLayer()
    private let stateLabel = CATextLayer()
    private let idleLabel = CATextLayer()
    private var shownTempo = ""
    private var shownState = ""
    /// The rounded tempo `tempoText` was formatted for.
    private var formattedBPM = -1
    private var tempoText = "\u{2013}"

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        for layer in bars + meterTracks + meterFills {
            layer.cornerRadius = 1.5
            root.addSublayer(layer)
        }
        for layer in meterFills + meterTracks { layer.cornerRadius = 2.5 }
        for label in meterLabels + [tempoLabel, stateLabel, idleLabel] {
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
            label.fontSize = NSFont.smallSystemFontSize - 1
            root.addSublayer(label)
        }
        tempoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        tempoLabel.fontSize = 15
        idleLabel.fontSize = NSFont.systemFontSize
        for label in [tempoLabel, stateLabel, idleLabel] { label.alignmentMode = .center }
        ring.fillColor = nil
        ring.lineWidth = 1.5
        root.addSublayer(ring)
        root.addSublayer(pulse)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AudioMonitorView is never decoded")
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSubscription() }
            }
        }
        updateScale()
        updateSubscription()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateSubscription()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateSubscription()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        for label in meterLabels + [tempoLabel, stateLabel, idleLabel] { label.contentsScale = scale }
    }

    private var isOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updateSubscription() {
        guard isOnScreen, let ticker else {
            subscription = nil
            return
        }
        guard subscription == nil else { return }
        subscription = ticker.subscribe(framesPerSecond: 30) { [weak self] features in
            self?.features = features
            self?.render()
        }
    }

    // MARK: Drawing

    /// Colours follow the light or dark appearance.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor.cgColor
            let track = NSColor.quaternaryLabelColor.cgColor
            let secondary = NSColor.secondaryLabelColor.cgColor
            for layer in bars + meterFills { layer.backgroundColor = accent }
            for layer in meterTracks { layer.backgroundColor = track }
            for label in meterLabels + [stateLabel, idleLabel] { label.foregroundColor = secondary }
            tempoLabel.foregroundColor = NSColor.labelColor.cgColor
            ring.strokeColor = secondary
            pulse.backgroundColor = accent
        }
        render()
    }

    override func layout() {
        super.layout()
        render()
    }

    /// Places every layer for the current features (bottom-left origin).
    private func render() {
        let f = features
        let height = bounds.height
        let width = bounds.width - Self.beatColumnWidth - 12
        guard width > 40 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Spectrum, above the meters.
        let spectrumBottom = Self.meterHeight + 10
        let spectrumHeight = height - spectrumBottom - 2
        let slot = width / CGFloat(bars.count)
        for (band, bar) in bars.enumerated() {
            let level = CGFloat(min(1, max(0, f.spectrum[band])))
            bar.frame = CGRect(x: CGFloat(band) * slot + 1, y: spectrumBottom, width: max(1.5, slot - 2.5), height: max(2, level * spectrumHeight))
            bar.opacity = Float(level > 0 ? 0.35 + 0.65 * level : 0.25)
        }
        idleLabel.string = f.isSilent ? idleText : ""
        idleLabel.frame = CGRect(x: 0, y: spectrumBottom + spectrumHeight / 2 - 4, width: width, height: 18)

        // Level and the five bands.
        let levels = [f.energy, f.bands.subBass, f.bands.bass, f.bands.lowMid, f.bands.mid, f.bands.high]
        let column = width / CGFloat(levels.count)
        for (index, level) in levels.enumerated() {
            let x = CGFloat(index) * column
            meterLabels[index].frame = CGRect(x: x, y: 13, width: column - 4, height: 15)
            let track = CGRect(x: x, y: 2, width: column - 10, height: 5)
            meterTracks[index].frame = track
            let filled = track.width * CGFloat(min(1, max(0, level)))
            meterFills[index].frame = CGRect(x: x, y: 2, width: filled, height: 5)
            // A rounded layer narrower than its corners would still show a sliver.
            meterFills[index].isHidden = filled < 5
        }

        // The beat light: swells on every beat, its ring brightens on onsets.
        let center = CGPoint(x: bounds.width - Self.beatColumnWidth / 2, y: height - 40)
        let beat = CGFloat(min(1, max(0, f.beat)))
        let radius = 13 + 9 * beat
        pulse.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        pulse.cornerRadius = radius
        pulse.opacity = Float(f.isSilent ? 0.12 : 0.18 + 0.82 * beat)
        ring.path = CGPath(ellipseIn: CGRect(x: center.x - 27, y: center.y - 27, width: 54, height: 54), transform: nil)
        ring.opacity = Float(0.25 + 0.75 * min(1, max(0, f.onset)))

        let rounded = Int(f.bpm.rounded())
        if rounded != formattedBPM {
            formattedBPM = rounded
            tempoText = rounded > 0 ? bpmText(Float(rounded)) : "\u{2013}"
        }
        let tempo = tempoText
        let state = f.isSilent ? "" : (f.bpm > 0 ? steadyText : searchingText)
        tempoLabel.frame = CGRect(x: center.x - Self.beatColumnWidth / 2, y: height - 98, width: Self.beatColumnWidth, height: 20)
        stateLabel.frame = CGRect(x: center.x - Self.beatColumnWidth / 2, y: height - 118, width: Self.beatColumnWidth, height: 15)
        if tempo != shownTempo || state != shownState {
            shownTempo = tempo
            shownState = state
            tempoLabel.string = tempo
            stateLabel.string = state
            setAccessibilityLabel([tempo, state].filter { !$0.isEmpty && $0 != "\u{2013}" }.joined(separator: ", "))
        }
        CATransaction.commit()
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
}

/// The monitor in a SwiftUI Form.
struct AudioMonitor: NSViewRepresentable {
    let audio: AudioTapEngine
    let idleText: String

    func makeNSView(context: Context) -> AudioMonitorView {
        let view = AudioMonitorView()
        view.ticker = audio.ticker
        return view
    }

    func updateNSView(_ view: AudioMonitorView, context: Context) {
        view.bpmText = { bpm in L10n.format("%@ BPM", ValueFormat.number(Double(bpm), digits: 0)) }
        view.meterTitles = ["Level".l10n, "Sub".l10n, "Bass".l10n, "Low-mid".l10n, "Mid".l10n, "High".l10n]
        view.idleText = idleText
        view.searchingText = "Finding the beat…".l10n
        view.steadyText = "Steady beat".l10n
    }
}
