import AhenkKit
import SwiftUI

struct LyricsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        PaneForm(
            pane: .lyrics,
            summary: "Synced lyrics on the desktop, line by line, beside the album cover.".l10n
        ) {
            Section {
                ToggleRow(title: "Show lyrics on the desktop".l10n, isOn: $settings.lyrics.enabled)
            }

            Section("Look".l10n) {
                Picker("Style".l10n, selection: $settings.lyrics.style) {
                    ForEach(LyricStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                SliderRow(
                    title: "Text size".l10n, value: $settings.lyrics.textScale,
                    range: LyricsSettings.textScaleRange, step: 0.05, format: ValueFormat.percent
                )
                Toggle("Show the album cover beside the lyrics".l10n, isOn: $settings.lyrics.showAlbumArt)
                Toggle("Color the lines from the album cover".l10n, isOn: $settings.lyrics.useAlbumColors)
                Toggle("Count down to the next line in instrumental parts".l10n, isOn: $settings.lyrics.instrumentalCountdown)
            }

            Section("Timing".l10n) {
                ToggleRow(
                    title: "Sync automatically".l10n,
                    detail: "Listens to the song on this Mac to keep the lines on time. Nothing is recorded.".l10n,
                    isOn: $settings.lyrics.autoSync
                )
                SliderRow(
                    title: "Timing offset".l10n, value: $settings.lyrics.globalOffset,
                    range: LyricsSettings.offsetRange, step: 0.1, format: ValueFormat.signedSeconds
                )
            }

            Section {
                ToggleRow(
                    title: "Align lyrics on this Mac (Beta)".l10n,
                    detail: "For songs without synced lyrics. Everything runs on this Mac.".l10n,
                    isOn: $settings.lyrics.localAlignment
                )
            }
        }
    }
}
