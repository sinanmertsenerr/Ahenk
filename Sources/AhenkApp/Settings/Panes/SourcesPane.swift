import AhenkKit
import SwiftUI

struct SourcesPane: View {
    let services: NowPlayingServices
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
                LabeledContent("Following now".l10n) {
                    Text(followedName)
                        .foregroundStyle(.secondary)
                }
                ToggleRow(title: "Ask which one to follow when two sources play at once".l10n, isOn: $settings.sources.askWhenSeveralPlay)
                ToggleRow(title: "Pause the previous source when switching".l10n, isOn: $settings.sources.pauseOthersOnSwitch)
            } footer: {
                if settings.sources.selection == .automatic {
                    Text("Automatic follows the source that started playing most recently.".l10n)
                }
            }

            if !services.isDemo {
                Section {
                    ForEach([MusicSource.appleMusic, .spotify]) { source in
                        MusicAppRow(source: source, services: services)
                    }
                } header: {
                    Text("Music Apps".l10n)
                } footer: {
                    Text("With Automation, Ahenk reads the song, its cover, shuffle, repeat and favorites straight from the app and sends the commands you choose. Without it, Ahenk still shows what plays.".l10n)
                }

                Section {
                    LabeledContent("System Now Playing".l10n) {
                        Text(services.adapterHealth.title)
                            .foregroundStyle(.secondary)
                    }
                    let others = services.state.players.filter { $0.id.source != .appleMusic && $0.id.source != .spotify }
                    if others.isEmpty {
                        EmptyRow(text: "Nothing else is playing.".l10n)
                    } else {
                        ForEach(others) { player in
                            PlayerRow(player: player, services: services)
                        }
                    }
                } header: {
                    Text("Browsers and Other Apps".l10n)
                } footer: {
                    Text("Browsers and other apps report what plays through macOS. A browser does not say which site is playing, so Ahenk guesses it from the song's details.".l10n)
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
        .onAppear { services.refreshPermissions() }
    }

    private var followedName: String {
        guard let active = services.state.activeID else { return "Nothing is playing".l10n }
        return services.displayName(for: active)
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

/// Apple Music or Spotify: installed, running, playing, and how much Ahenk
/// may do with it; a button to allow access or open System Settings.
private struct MusicAppRow: View {
    let source: MusicSource
    let services: NowPlayingServices

    private var bundleIdentifier: String {
        source == .appleMusic ? KnownApps.appleMusic : KnownApps.spotify
    }

    var body: some View {
        let status = services.statuses[source]
        let installed = services.apps.isInstalled(bundleIdentifier)
        LabeledContent {
            if let status, status.isRunning {
                switch status.permission {
                case .notDetermined:
                    Button("Allow Access…".l10n) { services.requestAccess(to: source) }
                case .denied:
                    Button("Open System Settings…".l10n) { services.openAutomationSettings() }
                case .granted, .appNotRunning, .unknown:
                    EmptyView()
                }
            }
        } label: {
            HStack(spacing: 10) {
                AppIcon(image: services.apps.icon(for: bundleIdentifier))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(detail(status: status, installed: installed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(status: ScriptedSourceStatus?, installed: Bool) -> String {
        guard installed else { return "Not installed".l10n }
        guard let status, status.isRunning else { return "Not running".l10n }
        var parts: [String] = []
        if let player = services.state.players.first(where: { $0.id.source == source }) {
            parts.append(player.isPlaying ? "Playing".l10n : "Paused".l10n)
        }
        switch status.permission {
        case .granted: parts.append("Full access".l10n)
        case .notDetermined: parts.append("Limited: song and play state only".l10n)
        case .denied: parts.append("Automation is off for Ahenk".l10n)
        case .appNotRunning, .unknown: parts.append("Checking…".l10n)
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A browser or other app that reports a song through the system.
private struct PlayerRow: View {
    let player: HubPlayer
    let services: NowPlayingServices

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(image: player.id.bundleIdentifier.flatMap { services.apps.icon(for: $0) })
            VStack(alignment: .leading, spacing: 2) {
                Text(services.displayName(for: player.id))
                Text(songLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(player.isPlaying ? "Playing".l10n : "Paused".l10n)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var songLine: String {
        let track = player.snapshot.track
        return [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
    }
}

private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

extension AdapterHealth {
    @MainActor
    var title: String {
        switch self {
        case .running: "Working".l10n
        case .starting: "Starting…".l10n
        case .restarting: "Restarting…".l10n
        case .unavailable: "Not available".l10n
        case .missing: "Not part of this build".l10n
        case .stopped: "Stopped".l10n
        }
    }
}
