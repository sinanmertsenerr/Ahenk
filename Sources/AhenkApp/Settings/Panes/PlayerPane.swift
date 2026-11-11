import AhenkKit
import SwiftUI

struct PlayerPane: View {
    @Bindable var settings: AppSettings
    /// Puts the widgets back in their default places (the desktop player).
    var resetLayout: () -> Void = {}
    @State private var displays = DisplayIdentity.currentDisplays()

    var body: some View {
        PaneForm(
            pane: .player,
            summary: "A glass player on the desktop, under your windows: a big clock, Continue Playing and search.".l10n
        ) {
            Section {
                ToggleRow(title: "Show the desktop player".l10n, isOn: $settings.player.enabled)
                Picker("Size".l10n, selection: $settings.player.size) {
                    ForEach(PlayerSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Display".l10n, selection: $settings.player.displayID) {
                    Text("Main display".l10n).tag(String?.none)
                    ForEach(displays.filter { !$0.isMain }) { display in
                        Text(display.name).tag(String?.some(display.id))
                    }
                }
            }

            Section("Show".l10n) {
                Toggle("Clock".l10n, isOn: $settings.player.showClock)
                Toggle("Continue Playing".l10n, isOn: $settings.player.showContinuePlaying)
                Toggle("Search bar".l10n, isOn: $settings.player.showSearch)
                Toggle("Player bar".l10n, isOn: $settings.player.showPlayerBar)
            }
            .disabled(!settings.player.enabled)

            Section("Clock".l10n) {
                Toggle("Date".l10n, isOn: $settings.player.showDate)
                Picker("Clock format".l10n, selection: $settings.player.clockFormat) {
                    ForEach(ClockFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                SliderRow(
                    title: "Clock size".l10n, value: $settings.player.clockScale, range: PlayerSettings.clockScaleRange, step: 0.05,
                    format: ValueFormat.percent
                )
            }
            .disabled(!settings.player.enabled || !settings.player.showClock)

            Section("Playback".l10n) {
                Picker("Play picked songs in".l10n, selection: $settings.player.listeningSource) {
                    Text("Automatic".l10n).tag(MusicSource?.none)
                    ForEach(ListeningSourceChoice.offered) { source in
                        Text(source.title).tag(MusicSource?.some(source))
                    }
                }
                ToggleRow(
                    title: "Start every song at 0:15".l10n,
                    detail: "Skips the intro of each new song.".l10n,
                    isOn: $settings.player.startAtFifteenSeconds
                )
            }

            Section {
                ToggleRow(
                    title: "Show the playing song's cover in the Dock".l10n,
                    detail: "Ahenk's own icon comes back when nothing plays.".l10n,
                    isOn: $settings.dock.albumArtIcon
                )
                ToggleRow(title: "A ring that beats along".l10n, isOn: $settings.dock.beatRing)
                    .disabled(!settings.dock.albumArtIcon)
            } header: {
                Text("Dock".l10n)
            } footer: {
                Text("The ring changes a few times a second and stays still while Low Power Mode is on.".l10n)
            }

            Section("Layout".l10n) {
                LabeledContent {
                    Button("Reset Layout".l10n, action: resetLayout)
                        .disabled(!settings.player.enabled)
                } label: {
                    Text("Places".l10n)
                    Text("Drag the clock, the list or the player by an empty spot to move it. Each display keeps its own places.".l10n)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayIdentity.currentDisplays()
        }
    }
}
