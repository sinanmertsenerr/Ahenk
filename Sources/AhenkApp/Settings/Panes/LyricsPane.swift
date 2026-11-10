import AhenkKit
import SwiftUI

struct LyricsPane: View {
    @Bindable var settings: AppSettings
    let lyrics: LyricsController
    let nowPlaying: NowPlayingModel
    let aligner: LyricsAlignmentController

    var body: some View {
        PaneForm(
            pane: .lyrics,
            summary: "Synced lyrics on the desktop, line by line, beside the album cover.".l10n
        ) {
            Section {
                ToggleRow(title: "Show lyrics on the desktop".l10n, detail: status, isOn: $settings.lyrics.enabled)
            }

            Section {
                LyricsStyleGallery(
                    selection: $settings.lyrics.style,
                    palette: nowPlaying.artwork?.palette ?? DemoCatalog.songs[0].palette,
                    useAlbumColors: settings.lyrics.useAlbumColors,
                    language: settings.general.language
                )
            } header: {
                Text("Style".l10n)
            } footer: {
                Text("Each style has its own typeface. The previews play invented lines in the colors of the song that plays.".l10n)
            }

            Section {
                SliderRow(
                    title: "Text size".l10n, value: $settings.lyrics.textScale,
                    range: LyricsSettings.textScaleRange, step: 0.05, format: ValueFormat.percent
                )
                Picker("Position".l10n, selection: $settings.lyrics.position) {
                    ForEach(LyricsPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                Toggle("Show the album cover beside the lyrics".l10n, isOn: $settings.lyrics.showAlbumArt)
                Toggle("Color the lines from the album cover".l10n, isOn: $settings.lyrics.useAlbumColors)
                Toggle("Count down to the next line in instrumental parts".l10n, isOn: $settings.lyrics.instrumentalCountdown)
            } header: {
                Text("Look".l10n)
            } footer: {
                Text("Drag the lyrics to put them anywhere; picking a position here moves them back.".l10n)
            }

            Section {
                ToggleRow(
                    title: "Sync automatically".l10n,
                    detail: "Listens to the song on this Mac to keep the lines on time. Nothing is kept or sent anywhere.".l10n,
                    isOn: $settings.lyrics.autoSync
                )
                SliderRow(
                    title: "All songs".l10n, value: $settings.lyrics.globalOffset,
                    range: LyricsSettings.offsetRange, step: 0.1, format: ValueFormat.signedSeconds
                )
                if lyrics.phase == .synced {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button {
                                lyrics.nudge(by: -LyricsController.nudgeStep)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .help("Show the lines later".l10n)
                            Text(ValueFormat.signedSeconds(lyrics.songOffset))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 52)
                            Button {
                                lyrics.nudge(by: LyricsController.nudgeStep)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .help("Show the lines earlier".l10n)
                            Button("Reset".l10n) { lyrics.resetOffset() }
                                .disabled(lyrics.songOffset == 0)
                        }
                    } label: {
                        Text("This song".l10n)
                        Text(songDetail)
                    }
                }
            } header: {
                Text("Timing".l10n)
            } footer: {
                Text("Positive values show the lines earlier. A song's own timing is kept for that song.".l10n)
            }

            Section {
                ForEach(LyricsChain.standardProviderNames, id: \.self) { name in
                    Toggle(name, isOn: providerEnabled(name))
                }
                LabeledContent("Saved lyrics".l10n) {
                    Button("Clear".l10n) { lyrics.clearCache() }
                }
            } header: {
                Text("Sources".l10n)
            } footer: {
                Text("While a song plays, its title, artist, album and length are sent to these services to find its lyrics. Found lyrics are kept on this Mac.".l10n)
            }

            Section {
                ToggleRow(
                    title: "Align lyrics on this Mac (Beta)".l10n,
                    detail: "For songs without synced lyrics. Everything runs on this Mac.".l10n,
                    isOn: $settings.lyrics.localAlignment
                )
                if settings.lyrics.localAlignment {
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(aligner.tools.executable?.path ?? "Not found".l10n)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…".l10n) { aligner.chooseExecutable() }
                        }
                    } label: {
                        Text(verbatim: "whisper-cli")
                    }
                    LabeledContent("Speech model".l10n) {
                        HStack(spacing: 10) {
                            switch aligner.download {
                            case .running(let done):
                                ProgressView(value: done).frame(width: 90)
                                Button("Cancel".l10n) { aligner.cancelDownload() }
                            case .none, .failed:
                                Text(aligner.tools.model?.lastPathComponent ?? (aligner.download == .failed ? "The model could not be downloaded.".l10n : "Not found".l10n))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if aligner.tools.model == nil {
                                    Button("Download the Model".l10n) { aligner.downloadModel() }
                                }
                                Button("Choose…".l10n) { aligner.chooseModel() }
                            }
                        }
                    }
                }
            } footer: {
                Text("Ahenk uses whisper.cpp and a speech model that are already on this Mac; it looks in the usual places (Homebrew, your whisper model folders, its own Models folder). Nothing is downloaded unless you press Download the Model.".l10n)
            }
            .onAppear { aligner.refreshTools() }
        }
    }

    /// What the lyrics are doing now, under the switch.
    private var status: String {
        guard settings.lyrics.enabled else { return "Off".l10n }
        switch lyrics.phase {
        case .idle: return "Waiting for a song".l10n
        case .loading: return "Finding the lyrics…".l10n
        case .synced:
            let source = lyrics.source.map(LyricsController.displayName(ofProvider:)) ?? ""
            return L10n.format("Synced lyrics from %@", source)
        case .plain: return "Only words without timing were found".l10n
        case .instrumental: return "Instrumental".l10n
        case .notFound: return "No lyrics for this song".l10n
        case .failed: return "The lyrics could not be loaded".l10n
        }
    }

    private var songDetail: String {
        if lyrics.manualOffset != nil { return "Set by you".l10n }
        if lyrics.autoOffset != nil { return "Measured automatically".l10n }
        return lyrics.song?.title ?? ""
    }

    private func providerEnabled(_ name: String) -> Binding<Bool> {
        Binding {
            !settings.lyrics.disabledProviders.contains(name)
        } set: { on in
            if on {
                settings.lyrics.disabledProviders.remove(name)
            } else {
                settings.lyrics.disabledProviders.insert(name)
            }
        }
    }
}
