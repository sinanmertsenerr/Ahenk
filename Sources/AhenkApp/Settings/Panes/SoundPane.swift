import AhenkKit
import SwiftUI

struct SoundPane: View {
    let audio: AudioTapEngine
    let apps: AppDirectory
    @Bindable var settings: AppSettings

    var body: some View {
        PaneForm(
            pane: .sound,
            summary: "Ahenk listens only to the sound of the music app, never to the microphone, and records nothing.".l10n
        ) {
            Section {
                LabeledContent("Status".l10n) {
                    Text(audio.statusText(appName: apps.name(for:)))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if !audio.isDemo {
                    LabeledContent("System audio access".l10n) {
                        HStack(spacing: 10) {
                            Text(audio.permission.title)
                                .foregroundStyle(.secondary)
                            switch audio.permission {
                            case .notDetermined, .unknown:
                                Button("Allow Listening…".l10n) { audio.requestPermission() }
                            case .denied:
                                Button("Open System Settings…".l10n) { audio.openPrivacySettings() }
                            case .authorized:
                                EmptyView()
                            }
                        }
                    }
                }
            } header: {
                Text("Listening".l10n)
            } footer: {
                if audio.permission == .denied, !audio.isDemo {
                    Text("Turn Ahenk on under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then come back.".l10n)
                } else {
                    Text("macOS asks once whether Ahenk may hear your Mac's sound. Ahenk hears only the app that plays your music, never the microphone; the sound is analyzed in memory and never recorded or saved. Videos and podcasts do not move the light.".l10n)
                }
            }

            Section("Beat".l10n) {
                SliderRow(
                    title: "Sensitivity".l10n, value: $settings.audio.sensitivity,
                    range: AudioAnalysisSettings.sensitivityRange, step: 0.05, format: ValueFormat.multiplier
                )
                AudioMonitor(audio: audio, idleText: audio.monitorIdleText)
                    .frame(height: AudioMonitorView.height)
                    .accessibilityLabel("Live spectrum".l10n)
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
        .onAppear { audio.refreshPermission() }
    }
}

extension AudioCapturePermission {
    @MainActor
    var title: String {
        switch self {
        case .authorized: "Allowed".l10n
        case .denied: "Denied".l10n
        case .notDetermined: "Not asked yet".l10n
        case .unknown: "Unknown".l10n
        }
    }
}

extension AudioTapEngine {
    /// "Listening to Spotify", "Waiting for music", …
    func statusText(appName: (String) -> String) -> String {
        if !isDemo {
            switch permission {
            case .denied: return "Not allowed in System Settings".l10n
            case .notDetermined: return "Waiting for your permission".l10n
            case .unknown, .authorized: break
            }
        }
        switch status.state {
        case .idle: return "Waiting for music".l10n
        case .notMusic: return "Not listening: what plays is not music".l10n
        case .needsPermission: return "Waiting for your permission".l10n
        case .denied: return "Not allowed in System Settings".l10n
        case .retrying: return "Could not start listening; trying again".l10n
        case .listening(.demo): return "Listening to the demo beat".l10n
        case .listening(.own): return "Listening to Ahenk's own player".l10n
        case .listening(.everything): return "Listening to every app (the music app's sound was not found)".l10n
        case .listening(.app(let target)):
            let name = target.bundleIdentifier.map(appName) ?? target.source.title
            return L10n.format("Listening to %@", name)
        }
    }

    /// Shown over the monitor while nothing is analysed.
    var monitorIdleText: String {
        if !isDemo, permission == .denied || permission == .notDetermined { return "Listening is not allowed yet".l10n }
        if case .notMusic = status.state { return "Not music".l10n }
        return "Waiting for music".l10n
    }
}
