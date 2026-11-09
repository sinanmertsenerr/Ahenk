import AhenkKit
import SwiftUI

/// The sound effects, opened from the button beside the lyrics: the switch,
/// what the effects are applied to (or why they cannot be), the presets,
/// speed, pitch and reverb, and the ten-band equalizer. Everything changes
/// the sound at once, while the song plays.
struct SoundEffectsPanel: View {
    let effects: SoundEffectsController
    let audio: AudioTapEngine
    @Bindable var settings: AppSettings
    let theme: PlayerTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
            presets
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 6) {
                    EffectSlider(
                        title: "Speed".l10n, value: $settings.effects.speed, range: SoundEffectSettings.speedRange, step: 0.05,
                        text: ValueFormat.multiplier(settings.effects.speed), accent: theme.accent, isDimmed: effects.speedIsIgnored
                    )
                    EffectSlider(
                        title: "Pitch".l10n, value: $settings.effects.pitch, range: SoundEffectSettings.pitchRange, step: 1,
                        text: ValueFormat.semitones(settings.effects.pitch), accent: theme.accent
                    )
                    EffectSlider(
                        title: "Reverb".l10n, value: $settings.effects.reverb, range: SoundEffectSettings.reverbRange, step: 0.01,
                        text: ValueFormat.percent(settings.effects.reverb), accent: theme.accent
                    )
                    if effects.speedIsIgnored {
                        Text("This player cannot change its speed, so only the pitch moves.".l10n)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: 252)
                equalizer
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(settings.effects.enabled ? 1 : 0.72)
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(effects.isApplied ? theme.accent : .white.opacity(0.3))
                .frame(width: 7, height: 7)
            Text(effects.statusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            switch effects.route {
            case .unavailable(.needsPermission):
                CapsuleButton(title: "Allow Listening…".l10n, symbol: "ear", accent: theme.accent) { audio.requestPermission() }
            case .unavailable(.permissionDenied):
                CapsuleButton(title: "Open System Settings…".l10n, symbol: "gearshape", accent: theme.accent) { audio.openPrivacySettings() }
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Presets

    private var presets: some View {
        ChipRows(spacing: 6) {
            ForEach(SoundPreset.allCases) { preset in
                PresetChip(
                    title: preset.title, isOn: settings.effects.enabled && settings.effects.preset == preset, accent: theme.accent
                ) {
                    effects.select(preset)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Equalizer

    private var equalizer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    settings.effects.equalizerEnabled.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: settings.effects.equalizerEnabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Equalizer".l10n)
                            .font(.system(size: 11.5, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.5)
                    }
                    .foregroundStyle(settings.effects.equalizerEnabled ? theme.accent : .white.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use the equalizer".l10n)
                .accessibilityAddTraits(settings.effects.equalizerEnabled ? .isSelected : [])
                Spacer(minLength: 4)
                Button("Flatten".l10n) {
                    settings.effects.equalizerBands = SoundEffectSettings.flatEqualizer
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(settings.effects.equalizerBands == SoundEffectSettings.flatEqualizer ? 0.3 : 0.8))
                .disabled(settings.effects.equalizerBands == SoundEffectSettings.flatEqualizer)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(SoundEffectSettings.equalizerFrequencies.indices, id: \.self) { band in
                    BandSlider(
                        gain: Binding {
                            settings.effects.equalizerBands.indices.contains(band) ? settings.effects.equalizerBands[band] : 0
                        } set: { gain in
                            var bands = SoundEffectSettings.normalizedBands(settings.effects.equalizerBands)
                            bands[band] = gain
                            settings.effects.equalizerBands = bands
                            // Moving a band is asking for the equalizer.
                            settings.effects.equalizerEnabled = true
                        },
                        label: ValueFormat.shortFrequency(SoundEffectSettings.equalizerFrequencies[band]),
                        name: ValueFormat.frequency(SoundEffectSettings.equalizerFrequencies[band]),
                        accent: theme.accent, isActive: settings.effects.equalizerEnabled
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The panel's switch in its title row.
struct SoundEffectsSwitch: View {
    let effects: SoundEffectsController
    @Bindable var settings: AppSettings
    let accent: Color

    var body: some View {
        HStack(spacing: 2) {
            Button("Reset".l10n) { settings.effects.reset() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.trailing, 6)
                .help("Put every slider back".l10n)
            WidgetIconButton(
                symbol: "power", pointSize: 13, side: 28, isOn: settings.effects.enabled, accent: accent,
                help: settings.effects.enabled ? "Turn the Sound Effects Off".l10n : "Turn the Sound Effects On".l10n
            ) {
                effects.setEnabled(!settings.effects.enabled)
            }
        }
    }
}

/// Chips one after another, on as many rows as the width asks for.
private struct ChipRows: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

/// One preset to choose.
private struct PresetChip: View {
    let title: String
    let isOn: Bool
    let accent: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : .white.opacity(0.92))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(isOn ? accent : .white.opacity(isHovering ? 0.2 : 0.11)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A thin slider with its name on the left and its value on the right;
/// follows the pointer and snaps to `step`. A double click puts it back in
/// the middle of what it changes (speed 1, pitch 0, no reverb).
private struct EffectSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String
    let accent: Color
    var isDimmed = false
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - 12)
                let fraction = (value.clamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                    Capsule().fill(accent.opacity(isDimmed ? 0.4 : 1)).frame(width: 6 + width * fraction, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 14 : 11, height: isDragging ? 14 : 11)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - (isDragging ? 1 : 0))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isDragging = true
                            let raw = range.lowerBound + min(1, max(0, (drag.location.x - 6) / width)) * (range.upperBound - range.lowerBound)
                            value = ((raw / step).rounded() * step).clamped(to: range)
                        }
                        .onEnded { _ in isDragging = false }
                )
                .animation(.snappy(duration: 0.12), value: isDragging)
            }
            .frame(height: 24)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(isDimmed ? 0.45 : 0.92))
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + step).clamped(to: range)
            case .decrement: value = (value - step).clamped(to: range)
            @unknown default: break
            }
        }
    }
}

/// One band of the equalizer: a vertical track from −12 to +12 dB with the
/// zero line in its middle and the frequency under it.
private struct BandSlider: View {
    @Binding var gain: Double
    let label: String
    let name: String
    let accent: Color
    let isActive: Bool
    @State private var isDragging = false

    private var range: ClosedRange<Double> { SoundEffectSettings.gainRange }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let height = max(1, proxy.size.height - 10)
                let fraction = (gain.clamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
                let knob = 5 + height * (1 - fraction)
                let middle = 5 + height * 0.5
                ZStack(alignment: .top) {
                    Capsule().fill(.white.opacity(0.16)).frame(width: 4)
                    Capsule()
                        .fill(accent.opacity(isActive ? 1 : 0.35))
                        .frame(width: 4, height: max(0, abs(knob - middle)))
                        .offset(y: min(knob, middle))
                    Circle()
                        .fill(.white.opacity(isActive ? 1 : 0.6))
                        .frame(width: isDragging ? 13 : 10, height: isDragging ? 13 : 10)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(y: knob - (isDragging ? 6.5 : 5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isDragging = true
                            let raw = range.upperBound - min(1, max(0, (drag.location.y - 5) / height)) * (range.upperBound - range.lowerBound)
                            gain = raw.rounded().clamped(to: range)
                        }
                        .onEnded { _ in isDragging = false }
                )
                .animation(.snappy(duration: 0.12), value: isDragging)
            }
            Text(label)
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(ValueFormat.decibels(gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: gain = (gain + 1).clamped(to: range)
            case .decrement: gain = (gain - 1).clamped(to: range)
            @unknown default: break
            }
        }
    }
}

extension SoundEffectsController {
    /// One line about what the effects do right now, for the panel and
    /// Settings › Sound.
    var statusText: String {
        if let localFailure, route == .ownPlayer {
            _ = localFailure
            return "The effects could not be started for this song.".l10n
        }
        switch route {
        case .off:
            return settings.effects.enabled ? "Waiting for music".l10n : "Off".l10n
        case .ownPlayer:
            return isApplied ? "On for the song files Ahenk plays".l10n : "On; this preset changes nothing yet".l10n
        case .tap:
            if isApplied { return "On: Ahenk plays this app's sound with the effects".l10n }
            return chain.processesSound || chain.changesSpeed
                ? "Starts as soon as the music plays".l10n
                : "On; this preset changes nothing yet".l10n
        case .demo:
            return "Demo: the effects are shown, the demo's songs make no sound".l10n
        case .unavailable(let obstacle):
            switch obstacle {
            case .needsPermission:
                return "Ahenk has to hear this app to change its sound. Allow listening first.".l10n
            case .permissionDenied:
                return "System audio access is denied, so this app's sound cannot be changed.".l10n
            case .needsNewerSystem:
                return "Changing another app's sound needs macOS 14.2 or later.".l10n
            case .notHeardSeparately:
                return "This app's sound cannot be told apart from other apps, so it is left as it is.".l10n
            case .notMusic:
                return "What plays is not music, so its sound is left as it is.".l10n
            case .unknownPlayer:
                return "Ahenk cannot tell which app plays, so its sound is left as it is.".l10n
            }
        }
    }
}
