import AhenkKit
import SwiftUI

struct SourcesPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        PaneForm(
            pane: .sources,
            summary: "Ahenk follows what plays in Apple Music, Spotify, your browser and any app that shows what is playing.".l10n
        ) {
            Section {
                Picker("Follow".l10n, selection: $settings.sources.selection) {
                    Text(SourceSelection.automatic.title).tag(SourceSelection.automatic)
                    Divider()
                    ForEach(MusicSource.pinnable) { source in
                        Text(source.title).tag(SourceSelection.pinned(source))
                    }
                }
                ToggleRow(title: "Ask which one to follow when two sources play at once".l10n, isOn: $settings.sources.askWhenSeveralPlay)
                ToggleRow(title: "Pause the previous source when switching".l10n, isOn: $settings.sources.pauseOthersOnSwitch)
            } footer: {
                if settings.sources.selection == .automatic {
                    Text("Automatic follows the source that started playing most recently.".l10n)
                }
            }

            Section("Listen To".l10n) {
                ForEach(MusicSource.pinnable + [.otherApp]) { source in
                    Toggle(source.title, isOn: listens(to: source))
                }
            }

            Section {
                ToggleRow(
                    title: "Allow the browser extension to connect".l10n,
                    detail: "Music sites in the browser report what is playing through the Ahenk extension. Only connections from this Mac are accepted.".l10n,
                    isOn: $settings.sources.browserBridgeEnabled
                )
            } header: {
                Text("Browser Extension".l10n)
            }
        }
    }

    private func listens(to source: MusicSource) -> Binding<Bool> {
        Binding {
            !settings.sources.ignoredSources.contains(source)
        } set: { listens in
            if listens {
                settings.sources.ignoredSources.remove(source)
            } else {
                settings.sources.ignoredSources.insert(source)
            }
        }
    }
}
