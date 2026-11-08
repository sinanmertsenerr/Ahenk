import AhenkKit
import SwiftUI

struct SoundPane: View {
    let model: NowPlayingModel
    @Bindable var settings: AppSettings

    var body: some View {
        PaneForm(
            pane: .sound,
            summary: "Ahenk listens only to the sound of the music app, never to the microphone, and records nothing.".l10n
        ) {
            Section("Beat".l10n) {
                SliderRow(
                    title: "Sensitivity".l10n, value: $settings.audio.sensitivity,
                    range: AudioAnalysisSettings.sensitivityRange, step: 0.05, format: ValueFormat.multiplier
                )
                LabeledContent("Live spectrum".l10n) {
                    SpectrumView(model: model)
                        .frame(width: 230, height: 24)
                }
            }

            Section("Sound Effects".l10n) {
                ToggleRow(
                    title: "Use sound effects".l10n,
                    detail: "Changes the sound of the song as it plays.".l10n,
                    isOn: $settings.effects.enabled
                )
                Picker("Preset".l10n, selection: $settings.effects.preset) {
                    ForEach(SoundPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                SliderRow(title: "Speed".l10n, value: $settings.effects.speed, range: SoundEffectSettings.speedRange, step: 0.05, format: ValueFormat.multiplier)
                SliderRow(title: "Pitch (semitones)".l10n, value: $settings.effects.pitch, range: SoundEffectSettings.pitchRange, step: 1, format: ValueFormat.semitones)
                SliderRow(title: "Reverb".l10n, value: $settings.effects.reverb, range: SoundEffectSettings.reverbRange, format: ValueFormat.percent)
            }

            Section {
                Toggle("Use the equalizer".l10n, isOn: $settings.effects.equalizerEnabled)
                ForEach(SoundEffectSettings.equalizerFrequencies.indices, id: \.self) { band in
                    SliderRow(
                        title: ValueFormat.frequency(SoundEffectSettings.equalizerFrequencies[band]),
                        value: $settings.effects.equalizerBands[band],
                        range: SoundEffectSettings.gainRange, step: 1, format: ValueFormat.decibels
                    )
                    .disabled(!settings.effects.equalizerEnabled)
                }
                LabeledContent("") {
                    Button("Flatten".l10n) {
                        settings.effects.equalizerBands = SoundEffectSettings.flatEqualizer
                    }
                    .disabled(settings.effects.equalizerBands == SoundEffectSettings.flatEqualizer)
                }
            } header: {
                Text("Equalizer".l10n)
            }
        }
    }
}

/// Live bars from the current audio features.
///
/// Drawn by a leaf AppKit view that redraws itself: a SwiftUI timeline in
/// this long Form would re-lay out the whole window on every frame (tens of
/// percent CPU). Runs only while music plays and the window is visible.
struct SpectrumView: NSViewRepresentable {
    let model: NowPlayingModel

    func makeNSView(context: Context) -> SpectrumBarsView {
        let view = SpectrumBarsView()
        view.features = { [weak model] in
            guard let model, model.isPlaying else { return nil }
            return model.featureSource?.currentFeatures()
        }
        return view
    }

    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.isActive = model.isPlaying
        view.idleText = "Waiting for music".l10n
        view.bpmText = { bpm in L10n.format("%@ BPM", ValueFormat.number(Double(bpm), digits: 0)) }
    }
}

final class SpectrumBarsView: NSView {
    var features: () -> AudioFeatures? = { nil }
    var idleText = "" { didSet { needsDisplay = true } }
    var bpmText: (Float) -> String = { _ in "" }
    var isActive = false { didSet { if isActive != oldValue { updateTimer() } } }

    private var timer: Timer?
    private static let barCount = AudioFeatures.bandCount
    private static let labelWidth: CGFloat = 70

    override var intrinsicContentSize: NSSize { NSSize(width: 230, height: 24) }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        let shouldRun = isActive && window != nil
        if shouldRun, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self, let window = self.window, window.occlusionState.contains(.visible) else { return }
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldRun {
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let current = isActive ? features() : nil
        let barsWidth = bounds.width - Self.labelWidth - 8
        let slot = barsWidth / CGFloat(Self.barCount)
        NSColor.controlAccentColor.setFill()
        for band in 0..<Self.barCount {
            let level = CGFloat(current?.bands[band] ?? 0)
            let height = max(2, level * bounds.height)
            let rect = NSRect(x: CGFloat(band) * slot + 1, y: bounds.height - height, width: max(2, slot - 3), height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
        let text = current.map { bpmText($0.bpm) } ?? idleText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.width - size.width, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    deinit {
        timer?.invalidate()
    }
}
