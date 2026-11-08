import AhenkKit
import SwiftUI

struct LightPane: View {
    @Bindable var settings: AppSettings
    @State private var displays = DisplayIdentity.currentDisplays()

    var body: some View {
        PaneForm(
            pane: .light,
            summary: "The edges of the screen glow in the colors of the album cover and move with the beat.".l10n
        ) {
            Section {
                ToggleRow(title: "Show the edge light".l10n, isOn: $settings.light.enabled)
            }

            Section("Look".l10n) {
                Picker("Style".l10n, selection: $settings.light.style) {
                    ForEach(LightStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Position".l10n, selection: $settings.light.position) {
                    ForEach(LightPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                SliderRow(title: "Thickness".l10n, value: $settings.light.thickness, range: LightSettings.thicknessRange, step: 1, format: ValueFormat.points)
                SliderRow(title: "Glow".l10n, value: $settings.light.glow, range: LightSettings.glowRange, format: ValueFormat.percent)
                SliderRow(title: "Intensity".l10n, value: $settings.light.intensity, range: LightSettings.intensityRange, format: ValueFormat.percent)
                SliderRow(title: "Speed".l10n, value: $settings.light.speed, range: LightSettings.speedRange, format: ValueFormat.multiplier)
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
