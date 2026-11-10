import AhenkKit
import SwiftUI

struct GeneralPane: View {
    let environment: AppEnvironment
    @Bindable var settings: AppSettings
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            if environment.options.usesDemoContent {
                // Outside the Form on purpose: live content inside a grouped
                // Form makes AppKit re-lay out the whole table on every tick.
                DemoBanner(model: environment.nowPlaying, lyrics: environment.lyrics)
                Divider()
            }
            form
        }
        .confirmationDialog("Reset all settings?".l10n, isPresented: $confirmsReset) {
            Button("Reset".l10n, role: .destructive) {
                settings.resetToDefaults()
            }
            Button("Cancel".l10n, role: .cancel) {}
        } message: {
            Text("Every setting returns to its default value. This cannot be undone.".l10n)
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Language".l10n, selection: $settings.general.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
            } footer: {
                Text("Ahenk keeps this language even when your Mac uses another one.".l10n)
            }

            Section {
                LoginItemToggle(loginItem: environment.loginItem)
                LabeledContent {
                    Button("Open the Guide…".l10n) { environment.showOnboarding() }
                } label: {
                    Text("Getting started".l10n)
                    Text("The permissions Ahenk uses, the browser extension and where everything is.".l10n)
                }
            } header: {
                Text("Startup".l10n)
            }

            Section("Performance".l10n) {
                ToggleRow(
                    title: "Run lighter on battery".l10n,
                    detail: "The edge light draws half as often on battery. In Low Power Mode only the cover moves.".l10n,
                    isOn: $settings.general.lighterOnBattery
                )
            }

            Section("Menu Bar".l10n) {
                ToggleRow(title: "Show the song title in the menu bar".l10n, isOn: $settings.general.showSongTitleInMenuBar)
            }

            Section("Troubleshooting".l10n) {
                ToggleRow(
                    title: "Detailed logging".l10n,
                    detail: "Writes extra detail to the log file.".l10n,
                    isOn: $settings.general.verboseLogging
                )
                LabeledContent("Log files".l10n) {
                    Button("Show in Finder".l10n) {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.directory])
                    }
                }
                LabeledContent("Settings".l10n) {
                    Button("Reset All Settings…".l10n, role: .destructive) {
                        confirmsReset = true
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "Demo Mode" header with the playing demo song, above the General form.
struct DemoBanner: View {
    let model: NowPlayingModel
    let lyrics: LyricsController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Demo Mode".l10n)
                .font(.headline)
            DemoNowPlayingCard(model: model, lyrics: lyrics)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Invented songs, generated covers and a steady 120 BPM beat. No music or permissions needed.".l10n)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// The demo song with its generated cover, progress and current lyric line.
///
/// Every SwiftUI update re-lays out the whole Settings window (a few ms on
/// AppKit), so the moving parts refresh only twice a second while the song
/// plays and not at all while it is paused.
struct DemoNowPlayingCard: View {
    let model: NowPlayingModel
    let lyrics: LyricsController

    var body: some View {
        if let snapshot = model.snapshot {
            HStack(spacing: 14) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(snapshot.track.title).font(.headline)
                        Text(L10n.format("%@ BPM", ValueFormat.number(DemoBeat.bpm, digits: 0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle(snapshot.track))
                        .foregroundStyle(.secondary)
                    if snapshot.isPlaying {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            position(of: snapshot, at: context.date)
                        }
                    } else {
                        position(of: snapshot, at: Date())
                    }
                }
                Spacer(minLength: 8)
                transport(isPlaying: snapshot.isPlaying)
            }
            .padding(.vertical, 4)
        } else {
            EmptyRow(text: "Starting the demo…".l10n)
        }
    }

    private func position(of snapshot: NowPlayingSnapshot, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: snapshot.progress(at: date))
                .progressViewStyle(.linear)
            Text(lyrics.lyricLine(at: date)?.text ?? "\u{266A}")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var cover: some View {
        Group {
            if let image = model.artworkImage {
                Image(nsImage: image).resizable()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private func subtitle(_ track: Track) -> String {
        track.album.isEmpty ? track.artist : "\(track.artist) \u{2014} \(track.album)"
    }

    private func transport(isPlaying: Bool) -> some View {
        HStack(spacing: 4) {
            Button { model.perform(.previous) } label: { Image(systemName: "backward.fill") }
                .help("Previous".l10n)
            Button { model.perform(.togglePlayPause) } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                .help(isPlaying ? "Pause".l10n : "Play".l10n)
            Button { model.perform(.next) } label: { Image(systemName: "forward.fill") }
                .help("Next".l10n)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}
