import AhenkKit
import AppKit
import Observation
import os

/// The store country for catalog lookups, readable off the main thread.
final class StorefrontBox: Sendable {
    private let lock: OSAllocatedUnfairLock<String>

    init(_ code: String?) {
        lock = OSAllocatedUnfairLock(initialState: Self.resolve(code))
    }

    var code: String { lock.withLock { $0 } }

    func update(_ code: String?) {
        lock.withLock { $0 = Self.resolve(code) }
    }

    /// The setting, or the Mac's region.
    private static func resolve(_ code: String?) -> String {
        code ?? Locale.current.region?.identifier ?? "US"
    }
}

/// The browsers known right now, shared with the MediaRemote provider.
final class ResolverBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: SourceResolver.standard)

    var resolver: SourceResolver { lock.withLock { $0 } }

    func update(_ resolver: SourceResolver) {
        lock.withLock { $0 = resolver }
    }
}

/// Builds and runs the now-playing pipeline: the providers, the hub that
/// merges them, the artwork pipeline and Continue Playing, and publishes
/// what Settings and the menus show (the hub's state, the access status of
/// Apple Music and Spotify, the system reader's health).
///
/// `--demo` and `--smoke` run the demo provider alone: no adapter, no
/// AppleScript, no network.
@MainActor
@Observable
final class NowPlayingServices {
    private(set) var state = HubState()
    private(set) var statuses: [MusicSource: ScriptedSourceStatus] = [:]
    private(set) var adapterHealth: AdapterHealth = .stopped

    @ObservationIgnored let hub: NowPlayingHub
    @ObservationIgnored let artwork: any ArtworkProvider
    /// Lyrics: the user's pick, the cache, then the providers (LRCLIB,
    /// Musixmatch, NetEase), or the demo's invented lines.
    @ObservationIgnored let lyricsFinder: LyricsFinder
    /// The chain without the providers turned off in Settings › Lyrics.
    @ObservationIgnored let makeLyricsChain: @Sendable (Set<String>) -> LyricsChain
    @ObservationIgnored let features: (any AudioFeatureSource)?
    @ObservationIgnored let recentlyPlayed: RecentlyPlayedStore
    @ObservationIgnored let apps = AppDirectory()
    @ObservationIgnored let isDemo: Bool
    /// Albums, songs and search for the desktop player (Apple's public
    /// catalog, or the demo library).
    @ObservationIgnored let catalog: any MusicCatalog
    /// Spotify track IDs for catalog songs (live only).
    @ObservationIgnored let spotifyFinder: (any SpotifyTrackFinding)?
    /// Runs the desktop player's AppleScript (live only).
    @ObservationIgnored let scripts: (any ScriptRunning)?
    @ObservationIgnored let presence: (any AppPresenceMonitoring)?
    /// Cover downloads for catalog items (never used in the demo).
    @ObservationIgnored let fetcher: any HTTPFetching
    /// Playing picks on music sites: Step 7's browser extension.
    @ObservationIgnored let browserPlayback: (any BrowserPlaybackRouting)?
    @ObservationIgnored private(set) var installedBrowsers: Set<String> = KnownApps.browsers

    @ObservationIgnored private let mediaRemote: MediaRemoteProvider?
    @ObservationIgnored private let appleMusic: AppleMusicProvider?
    @ObservationIgnored private let spotify: SpotifyProvider?
    @ObservationIgnored private let resolver: ResolverBox
    @ObservationIgnored let storefront: StorefrontBox
    @ObservationIgnored private let diskCache: ArtworkDiskCache?
    @ObservationIgnored private let catalogCache: CatalogCache?
    @ObservationIgnored private var bridge: MusicNotificationBridge?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private let log = AhenkLogger(category: "now-playing")

    /// System Settings › Privacy & Security › Automation.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    private init(
        hub: NowPlayingHub, artwork: any ArtworkProvider, lyricsFinder: LyricsFinder,
        makeLyricsChain: @escaping @Sendable (Set<String>) -> LyricsChain, features: (any AudioFeatureSource)?,
        recentlyPlayed: RecentlyPlayedStore, isDemo: Bool, mediaRemote: MediaRemoteProvider?, appleMusic: AppleMusicProvider?,
        spotify: SpotifyProvider?, resolver: ResolverBox, storefront: StorefrontBox, diskCache: ArtworkDiskCache?,
        catalog: any MusicCatalog, catalogCache: CatalogCache?, spotifyFinder: (any SpotifyTrackFinding)?,
        scripts: (any ScriptRunning)?, presence: (any AppPresenceMonitoring)?, fetcher: any HTTPFetching
    ) {
        self.hub = hub
        self.artwork = artwork
        self.lyricsFinder = lyricsFinder
        self.makeLyricsChain = makeLyricsChain
        self.features = features
        self.recentlyPlayed = recentlyPlayed
        self.isDemo = isDemo
        self.mediaRemote = mediaRemote
        self.appleMusic = appleMusic
        self.spotify = spotify
        self.resolver = resolver
        self.storefront = storefront
        self.diskCache = diskCache
        self.catalog = catalog
        self.catalogCache = catalogCache
        self.spotifyFinder = spotifyFinder
        self.scripts = scripts
        self.presence = presence
        self.fetcher = fetcher
        // Step 7 passes the browser extension's bridge here.
        self.browserPlayback = nil
        if let appleMusic, let spotify {
            bridge = MusicNotificationBridge(appleMusic: appleMusic, spotify: spotify)
        }
        adapterHealth = isDemo ? .stopped : (mediaRemote == nil ? .missing : .stopped)
    }

    /// Every real source. `features` is the audio engine's store.
    static func live(settings: AppSettings, features: any AudioFeatureSource) -> NowPlayingServices {
        let resolver = ResolverBox()
        let mediaRemote = AdapterLocator.invocation().map { invocation in
            MediaRemoteProvider(adapter: MediaRemoteAdapter(invocation: invocation), resolver: { resolver.resolver })
        }
        let runner = AppleScriptRunner()
        let presence = RunningApps()
        let appleMusic = AppleMusicProvider(runner: runner, presence: presence)
        let spotify = SpotifyProvider(runner: runner, presence: presence)
        let browser = BrowserProvider(bridge: nil)
        let local = LocalPlaybackProvider()

        var inputs: [HubInput] = [
            .provider(appleMusic, priority: HubInput.dedicatedPriority),
            .provider(spotify, priority: HubInput.dedicatedPriority),
            browser.hubInput,
            .provider(local, priority: HubInput.dedicatedPriority),
        ]
        if let mediaRemote { inputs.append(.provider(mediaRemote, priority: HubInput.systemPriority)) }

        let disk = ArtworkDiskCache()
        let fetcher = URLSessionFetcher()
        let storefront = StorefrontBox(settings.general.storefront)
        let catalog = ITunesSearch(fetcher: fetcher, storefront: { storefront.code })
        let pipeline = ArtworkPipeline(disk: disk, fetcher: fetcher, catalog: catalog)
        let catalogCache = CatalogCache(directory: CatalogCache.standardDirectory)
        // Lyrics get their own session: their providers can be slow, and a
        // lookup must never hold up covers or the catalog.
        let lyricsFetcher = URLSessionFetcher(timeout: 10)
        let makeChain: @Sendable (Set<String>) -> LyricsChain = { disabled in
            LyricsChain.standard(http: lyricsFetcher, disabled: disabled)
        }
        let lyricsFinder = LyricsFinder(
            chain: makeChain(settings.lyrics.disabledProviders), cache: LyricsCache(),
            songs: LyricsSongStore(fileURL: LyricsSongStore.standardURL)
        )

        return NowPlayingServices(
            hub: NowPlayingHub(inputs: inputs, configuration: configuration(settings)),
            artwork: pipeline, lyricsFinder: lyricsFinder, makeLyricsChain: makeChain, features: features,
            recentlyPlayed: RecentlyPlayedStore(fileURL: RecentlyPlayedStore.standardURL),
            isDemo: false, mediaRemote: mediaRemote, appleMusic: appleMusic, spotify: spotify,
            resolver: resolver, storefront: storefront, diskCache: disk,
            catalog: ITunesCatalog(fetcher: fetcher, storefront: { storefront.code }, cache: catalogCache),
            catalogCache: catalogCache,
            spotifyFinder: ListenBrainzSpotifyFinder(fetcher: fetcher, cache: catalogCache),
            scripts: runner, presence: presence, fetcher: fetcher
        )
    }

    /// The invented demo songs (`--demo`, `--smoke`). `second` adds another
    /// demo player so the "several sources play" question can be seen.
    /// `features` is the audio engine's store, fed by the demo beat.
    static func demo(_ demo: DemoProvider, second: DemoProvider?, settings: AppSettings, features: any AudioFeatureSource) -> NowPlayingServices {
        var inputs: [HubInput] = [.provider(demo, priority: HubInput.dedicatedPriority)]
        if let second { inputs.append(.provider(second, id: "demo-b", priority: HubInput.dedicatedPriority)) }
        let makeChain: @Sendable (Set<String>) -> LyricsChain = { _ in LyricsChain(providers: [demo]) }
        return NowPlayingServices(
            hub: NowPlayingHub(inputs: inputs, configuration: configuration(settings)),
            artwork: RoutingArtworkProvider(routes: [.demo: demo], fallback: nil),
            lyricsFinder: LyricsFinder(chain: makeChain([]), cache: nil, songs: LyricsSongStore(fileURL: nil)),
            makeLyricsChain: makeChain, features: features,
            recentlyPlayed: demoRecentlyPlayed(demo.library),
            isDemo: true, mediaRemote: nil, appleMusic: nil, spotify: nil,
            resolver: ResolverBox(), storefront: StorefrontBox(nil), diskCache: nil,
            catalog: DemoMusicCatalog(library: demo.library, latency: 0.25), catalogCache: nil,
            spotifyFinder: nil, scripts: nil, presence: nil, fetcher: OfflineFetcher()
        )
    }

    /// Continue Playing in the demo starts with a few songs "played" over
    /// the last hours (in memory only).
    private static func demoRecentlyPlayed(_ library: DemoLibrary) -> RecentlyPlayedStore {
        let store = RecentlyPlayedStore(fileURL: nil)
        let earlier = [
            "demo:sodium-lights", "demo:mavi-saat-sarki", "demo:satellite-hearts-song", "demo:kettle-song",
            "demo:afterglow-exit-song", "demo:glasswork-song", "demo:field-notes-song", "demo:rihtimda-dans",
            "demo:orbitals", "demo:moonwake", "demo:bloom-frequency", "demo:cedar-smoke",
        ]
        let now = Date()
        for (index, id) in earlier.enumerated().reversed() {
            guard let song = library.demoSong(id: id) else { continue }
            store.record(song.track, bundleIdentifier: nil, at: now.addingTimeInterval(-Double(index + 1) * 1_500))
        }
        return store
    }

    static func configuration(_ settings: AppSettings) -> HubConfiguration {
        HubConfiguration(sources: settings.sources, player: settings.player)
    }

    // MARK: Lifecycle

    func start(settings: AppSettings) {
        guard !isStarted else { return }
        isStarted = true
        observers.append(ChangeObserver({ Self.configuration(settings) }) { [weak self] configuration in
            self?.hub.setConfiguration(configuration)
        })
        let storefront = self.storefront
        storefront.update(settings.general.storefront)
        observers.append(ChangeObserver({ settings.general.storefront }) { code in
            storefront.update(code)
        })
        let hub = self.hub
        let store = recentlyPlayed
        tasks.append(Task { [weak self] in
            for await state in hub.states() {
                self?.state = state
            }
        })
        tasks.append(Task.detached(priority: .utility) {
            for await snapshot in hub.snapshots() {
                if let snapshot { store.notePlaying(snapshot) }
            }
        })
        if let appleMusic {
            tasks.append(Task { [weak self] in
                for await status in appleMusic.statusUpdates() { self?.statuses[.appleMusic] = status }
            })
        }
        if let spotify {
            tasks.append(Task { [weak self] in
                for await status in spotify.statusUpdates() { self?.statuses[.spotify] = status }
            })
        }
        if let mediaRemote {
            tasks.append(Task { [weak self] in
                for await health in mediaRemote.healthUpdates() { self?.adapterHealth = health }
            })
        }

        hub.start()
        mediaRemote?.start()
        appleMusic?.start()
        spotify?.start()
        bridge?.start()

        if !isDemo {
            let resolver = self.resolver
            let mediaRemote = self.mediaRemote
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) {
                    let found = BrowserRegistry.installedBrowsers()
                    resolver.update(SourceResolver(additionalBrowsers: found))
                    mediaRemote?.refreshMapping()
                    return found
                }.value
                self?.installedBrowsers = KnownApps.browsers.union(found)
            }
            diskCache?.prune()
            catalogCache?.prune()
            // Permissions may have changed in System Settings meanwhile.
            activation = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        }
        log.info(isDemo ? "Now playing: demo" : "Now playing: \(mediaRemote == nil ? "no system reader" : "system reader"), Apple Music, Spotify")
    }

    /// Stops every provider and terminates the adapter process (on quit).
    func stop() {
        guard isStarted else { return }
        isStarted = false
        tasks.forEach { $0.cancel() }
        tasks = []
        observers = []
        if let activation { NotificationCenter.default.removeObserver(activation) }
        bridge?.stop()
        appleMusic?.stop()
        spotify?.stop()
        mediaRemote?.stop()
        hub.stop()
        recentlyPlayed.flush()
    }

    // MARK: Actions

    /// Asks macOS for Automation access to the source's app (the user
    /// pressed the button; this may show macOS's prompt).
    func requestAccess(to source: MusicSource) {
        guard let provider = scriptedProvider(for: source) else { return }
        log.notice("Asking for Automation access to \(source.rawValue)")
        Task.detached(priority: .userInitiated) {
            _ = await provider.refreshPermission(askIfNeeded: true)
        }
    }

    /// Checks the Automation permission again, without a prompt.
    func refreshPermissions() {
        var providers: [any PermissionRefreshing] = []
        if let appleMusic { providers.append(appleMusic) }
        if let spotify { providers.append(spotify) }
        Task.detached(priority: .utility) {
            for provider in providers { _ = await provider.refreshPermission(askIfNeeded: false) }
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(Self.automationSettingsURL)
    }

    /// The user's answer to "which one should Ahenk follow?".
    func choose(_ player: PlayerID) {
        let hub = self.hub
        Task.detached(priority: .userInitiated) { await hub.choose(player) }
    }

    func perform(_ command: PlaybackCommand) {
        let hub = self.hub
        Task.detached(priority: .userInitiated) { await hub.perform(command) }
    }

    /// Pauses every playing player of another source (the desktop player's
    /// source picker, with "pause the previous source" on).
    func pausePlayers(otherThan source: MusicSource) {
        let hub = self.hub
        let others = state.players.filter { $0.isPlaying && $0.id.source != source }.map(\.id)
        guard !others.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for player in others { await hub.perform(.pause, on: player) }
        }
    }

    private func scriptedProvider(for source: MusicSource) -> (any PermissionRefreshing)? {
        switch source {
        case .appleMusic: appleMusic
        case .spotify: spotify
        default: nil
        }
    }

    // MARK: Names

    /// "Spotify", "YouTube Music · Search", "VLC".
    func displayName(for player: PlayerID) -> String {
        let appName = player.bundleIdentifier.map { apps.name(for: $0) }
        switch player.source {
        case .otherApp:
            return appName ?? "Other Apps".l10n
        case .local, .appleMusic, .spotify:
            return player.source.title
        case .demo:
            return player.bundleIdentifier == nil ? "Demo".l10n : L10n.format("Demo %@", "2")
        case .spotifyWeb, .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .youtube:
            if let id = player.bundleIdentifier, let appName, resolver.resolver.isBrowser(id) {
                return "\(player.source.title) \u{00B7} \(appName)"
            }
            return player.source.title
        }
    }
}

/// Lets the services refresh both scripted providers alike.
protocol PermissionRefreshing: Sendable {
    func refreshPermission(askIfNeeded: Bool) async -> AutomationPermission
}

extension ScriptedPlayerProvider: PermissionRefreshing {}

/// Answers every request with "offline" (the demo and the smoke run never
/// touch the network).
struct OfflineFetcher: HTTPFetching {
    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        throw URLError(.notConnectedToInternet)
    }
}
