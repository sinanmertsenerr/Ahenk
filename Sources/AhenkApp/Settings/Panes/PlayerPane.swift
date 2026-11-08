import AhenkKit
import SwiftUI

struct PlayerPane: View {
    @Bindable var settings: AppSettings
    @State private var displays = DisplayIdentity.currentDisplays()

    var body: some View {
        PaneForm(
            pane: .player,
            summary: "A glass player on the desktop, under your windows: a big clock, Continue Playing, the artist's albums and search.".l10n
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
                Toggle("Date".l10n, isOn: $settings.player.showDate)
                Picker("Clock format".l10n, selection: $settings.player.clockFormat) {
                    ForEach(ClockFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .disabled(!settings.player.showClock)
                Toggle("Continue Playing".l10n, isOn: $settings.player.showContinuePlaying)
                Toggle("The artist's albums".l10n, isOn: $settings.player.showAlbums)
                Toggle("Search bar".l10n, isOn: $settings.player.showSearch)
            }

            Section("Playback".l10n) {
                ToggleRow(
                    title: "Start every song at 0:15".l10n,
                    detail: "Skips the intro of each new song.".l10n,
                    isOn: $settings.player.startAtFifteenSeconds
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayIdentity.currentDisplays()
        }
    }
}
