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
                    Text("Apps report what plays through macOS. With the Ahenk browser extension, each music site in the browser reports exactly what plays; without it, Ahenk guesses the site from the song's details.".l10n)
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
                LabeledContent("Status".l10n) {
                    Text(bridgeStatus)
                        .foregroundStyle(.secondary)
                }
                if settings.sources.browserBridgeEnabled {
                    if services.browsers.isEmpty {
                        EmptyRow(text: "No browser is connected. Install the extension, then open a music site.".l10n)
                    } else {
                        ForEach(services.browsers) { browser in
                            BrowserRow(browser: browser, services: services)
                        }
                    }
                }
                LabeledContent {
                    Button("Install Browser Extension…".l10n) { BrowserExtensionInstaller.present() }
                } label: {
                    Text("Chrome, Edge, Brave, Arc, Firefox and other browsers".l10n)
                }
                LabeledContent {
                    TextField("First Port".l10n, value: firstPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                } label: {
                    Text("First Port".l10n)
                    Text("Ahenk listens on the first free port of the four from this one. If you change it, enter the same number in the extension's popup (Connection › First port).".l10n)
                }
            } header: {
                Text("Browser Extension".l10n)
            } footer: {
                Text("The extension reports YouTube Music, YouTube, Spotify, SoundCloud, Amazon Music, Deezer and TIDAL, and plays your picks, playlists and queue there.".l10n)
            }
        }
        .onAppear { services.refreshPermissions() }
    }

    private var bridgeStatus: String {
        switch services.bridgeStatus {
        case .stopped: return "Off".l10n
        case .starting: return "Starting…".l10n
        // Port numbers are never grouped ("42617", not "42.617").
        case .listening(let port): return L10n.format("Ready on port %@", String(port))
        case .failed:
            let ports = BridgeProtocol.ports(base: settings.sources.browserBridgePort)
            return L10n.format("No free port between %@ and %@", String(ports.first ?? 0), String(ports.last ?? 0))
        }
    }

    /// The bridge's first port, kept in its range.
    private var firstPort: Binding<Int> {
        Binding {
            settings.sources.browserBridgePort
        } set: { port in
            let range = SourceSettings.portRange
            settings.sources.browserBridgePort = min(range.upperBound, max(range.lowerBound, port))
        }
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

/// A browser connected through the extension: its name, the extension's
/// version and its music tabs.
private struct BrowserRow: View {
    let browser: BridgeBrowserSummary
    let services: NowPlayingServices

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppIcon(image: browser.bundleIdentifier.flatMap { services.apps.icon(for: $0) }, placeholder: "globe")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(browser.tabs) { tab in
                HStack(spacing: 6) {
                    Text(tab.site.title)
                        .font(.caption.weight(.semibold))
                    Text([tab.title, tab.artist].filter { !$0.isEmpty }.joined(separator: " \u{2014} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(tab.isPlaying ? "Playing".l10n : "Paused".l10n)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 32)
            }
        }
    }

    private var name: String {
        if let bundle = browser.bundleIdentifier { return services.apps.name(for: bundle) }
        return browser.browserName.isEmpty ? "Browser".l10n : browser.browserName
    }

    private var detail: String {
        let tabs = browser.tabs.count == 1 ? "1 music tab".l10n : L10n.format("%d music tabs", browser.tabs.count)
        return [L10n.format("Extension %@", browser.extensionVersion), tabs].joined(separator: " \u{00B7} ")
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
    /// Drawn when the app is not known.
    var placeholder = "app.dashed"

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: placeholder).resizable().foregroundStyle(.secondary)
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
