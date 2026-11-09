import AhenkKit
import SwiftUI

/// White symbol on a coloured rounded square, as in System Settings.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.symbolName)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Icon, title and a one-paragraph description at the top of a pane.
struct PaneHeader: View {
    let pane: SettingsPane
    let summary: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PaneIcon(pane: pane, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.title3.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A switch with an optional explanation under its title.
struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let detail {
                Text(detail)
            }
        }
    }
}

/// A slider with its title on the left and its formatted value on the right.
/// `step` snaps the stored value without drawing a tick mark per step.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    private var snapped: Binding<Double> {
        Binding {
            value
        } set: { newValue in
            guard let step, step > 0 else {
                value = newValue
                return
            }
            let steps = ((newValue - range.lowerBound) / step).rounded()
            value = min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: snapped, in: range)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .frame(maxWidth: 300)
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Locale-aware value formatting for the sliders.
@MainActor
enum ValueFormat {
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(L10n.locale))
    }

    static func points(_ value: Double) -> String {
        L10n.format("%@ pt", number(value, digits: 0))
    }

    static func multiplier(_ value: Double) -> String {
        L10n.format("%@×", number(value, digits: 2))
    }

    static func seconds(_ value: Double) -> String {
        L10n.format("%@ s", number(value, digits: 1))
    }

    /// "+0.5 s", "−1.2 s", "0 s".
    static func signedSeconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "\u{2212}" : "")
        return sign + seconds(abs(rounded))
    }

    static func decibels(_ value: Double) -> String {
        let rounded = value.rounded()
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "\u{2212}" : "")
        return sign + L10n.format("%@ dB", number(abs(rounded), digits: 0))
    }

    static func semitones(_ value: Double) -> String {
        let rounded = value.rounded()
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "\u{2212}" : "")
        return sign + number(abs(rounded), digits: 0)
    }

    /// "32", "500", "1k", "16k": under an equalizer band.
    static func shortFrequency(_ hertz: Double) -> String {
        hertz >= 1000 ? number(hertz / 1000, digits: 0) + "k" : number(hertz, digits: 0)
    }

    static func frequency(_ hertz: Double) -> String {
        hertz >= 1000
            ? L10n.format("%@ kHz", number(hertz / 1000, digits: 0))
            : L10n.format("%@ Hz", number(hertz, digits: 0))
    }
}

/// A grouped settings form with the pane header on top.
struct PaneForm<Content: View>: View {
    let pane: SettingsPane
    let summary: String
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section {
                PaneHeader(pane: pane, summary: summary)
            }
            content
        }
        .formStyle(.grouped)
    }
}

/// Muted text for an empty list.
struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }
}
