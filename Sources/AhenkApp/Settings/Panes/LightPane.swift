import AhenkKit
import SwiftUI

struct LightPane: View {
    @Bindable var settings: AppSettings
    let light: EdgeLightController
    @State private var displays = DisplayIdentity.currentDisplays()

    var body: some View {
        PaneForm(
            pane: .light,
            summary: "The edges of the screen glow in the colors of the album cover and move with the beat.".l10n
        ) {
            Section {
                ToggleRow(title: "Show the edge light".l10n, detail: light.status.title, isOn: $settings.light.enabled)
            }

            Section {
                LightStyleGallery(selection: $settings.light.style)
            } header: {
                Text("Style".l10n)
            } footer: {
                Text("Each preview moves with the music, or with a demo beat while nothing plays.".l10n)
            }

            Section {
                Picker("Position".l10n, selection: $settings.light.position) {
                    ForEach(LightPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                SliderRow(title: "Thickness".l10n, value: $settings.light.thickness, range: LightSettings.thicknessRange, step: 1, format: ValueFormat.points)
                SliderRow(title: "Glow".l10n, value: $settings.light.glow, range: LightSettings.glowRange, format: ValueFormat.percent)
                SliderRow(title: "Intensity".l10n, value: $settings.light.intensity, range: LightSettings.intensityRange, format: ValueFormat.percent)
                SliderRow(title: "Speed".l10n, value: $settings.light.speed, range: LightSettings.speedRange, format: ValueFormat.multiplier)
            } header: {
                Text("Look".l10n)
            } footer: {
                Text("While nothing plays, a change shows on your screens for a few seconds.".l10n)
            }

            Section("Color".l10n) {
                Picker("Colors".l10n, selection: $settings.light.colorSource) {
                    ForEach(LightColorSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                if settings.light.colorSource == .custom {
                    customColors
                }
            }

            Section {
                ToggleRow(
                    title: "Only on the desktop".l10n,
                    detail: "The light steps back when an app comes to the front.".l10n,
                    isOn: $settings.light.onlyOnDesktop
                )
                ToggleRow(title: "Step aside for full-screen apps".l10n, isOn: $settings.light.stepAsideInFullScreen)
            }

            Section {
                ForEach(displays) { display in
                    Toggle(isOn: lightsUp(display)) {
                        Text(display.name)
                        if display.isMain {
                            Text("Main display".l10n)
                        }
                    }
                }
            } header: {
                Text("Displays".l10n)
            } footer: {
                Text("Keep the display you work on calm and let the others glow.".l10n)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayIdentity.currentDisplays()
        }
    }

    private var customColors: some View {
        LabeledContent("Custom Colors".l10n) {
            HStack(spacing: 8) {
                ForEach(settings.light.customColors.indices, id: \.self) { index in
                    ColorPicker("", selection: color(at: index), supportsOpacity: false)
                        .labelsHidden()
                }
                Button {
                    settings.light.customColors.append(settings.light.customColors.last ?? .white)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(settings.light.customColors.count >= LightSettings.maxCustomColors)
                .help("Add a color".l10n)
                Button {
                    settings.light.customColors.removeLast()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(settings.light.customColors.count <= 1)
                .help("Remove the last color".l10n)
            }
        }
    }

    private func color(at index: Int) -> Binding<Color> {
        Binding {
            settings.light.customColors.indices.contains(index) ? Color(settings.light.customColors[index]) : .white
        } set: { color in
            guard settings.light.customColors.indices.contains(index) else { return }
            settings.light.customColors[index] = SRGBColor(color)
        }
    }

    private func lightsUp(_ display: DisplayInfo) -> Binding<Bool> {
        Binding {
            !settings.light.disabledDisplays.contains(display.id)
        } set: { on in
            if on {
                settings.light.disabledDisplays.remove(display.id)
            } else {
                settings.light.disabledDisplays.insert(display.id)
            }
        }
    }
}

/// Every style as a live miniature; clicking one picks it.
struct LightStyleGallery: View {
    @Binding var selection: LightStyle

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(LightStyle.allCases) { style in
                LightStyleTile(style: style, isSelected: style == selection) {
                    selection = style
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// One style: its live preview and its name; the chosen one is outlined.
struct LightStyleTile: View {
    let style: LightStyle
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                LightPreview(style: style)
                    .aspectRatio(1.6, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(style.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension EdgeLightController.Status {
    /// One line under the switch: what the light is doing now.
    @MainActor
    var title: String {
        switch self {
        case .off: "Off".l10n
        case .starting: "Starting…".l10n
        case .waitingForMusic: "Waiting for music".l10n
        case .glowing(let reason):
            switch reason {
            case .normal, .hidden: "On".l10n
            case .battery: "On, lighter on battery".l10n
            case .lowPowerMode: "On, lighter in Low Power Mode".l10n
            case .thermal: "On, lighter while the Mac is hot".l10n
            }
        case .steppedAside: "Stepped aside".l10n
        case .unavailable: "Not available on this Mac".l10n
        }
    }
}
