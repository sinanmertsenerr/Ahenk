import AhenkKit
import AppKit

/// The app's shared services, created once at launch.
@MainActor
final class AppEnvironment {
    /// Set by `bootstrap`; `nil` only before launch finished its first step.
    private(set) static var current: AppEnvironment?

    let options: LaunchOptions
    let settings: AppSettings
    let nowPlaying: NowPlayingModel
    /// The hub and every source (or the demo alone in `--demo`/`--smoke`).
    let services: NowPlayingServices
    /// Listening and the audio features (`audio.store` is `services.features`).
    let audio: AudioTapEngine
    /// Battery, Low Power Mode and heat (lighter drawing).
    let power: PowerMonitor
    /// "Open Ahenk at login" (the system's login item; never changed by
    /// demo and smoke runs).
    let loginItem: LoginItem
    /// Present in `--demo` and `--smoke`.
    let demo: DemoProvider?
    /// Ahenk plays song files itself (the Local source).
    let localPlayer: LocalPlayer
    /// The folders of song files the user gave Ahenk.
    let localLibrary: LocalLibraryStore
    /// Clear Desk. Live: the apps of this Mac. Demo and smoke runs: invented
    /// apps, so trying it never hides anything.
    let deskController: ClearDeskController
    var clearDesk: DeskClearing { deskController }

    private(set) lazy var settingsWindow = SettingsWindowController(environment: self)
    /// The edge light on every screen (started with the services).
    private(set) lazy var light = EdgeLightController(
        settings: settings, nowPlaying: nowPlaying, features: audio.store, power: power
    )
    /// The user's stickers (kept in memory in demo and smoke runs).
    private(set) lazy var stickers: StickerController = {
        let store = StickerStore(directory: options.mode == .normal ? StickerStore.standardDirectory : nil)
        let controller = StickerController(settings: settings, store: store)
        controller.onOpenSettings = { [weak self] in self?.showSettings(.stickers) }
        return controller
    }()
    /// The Dock icon as the playing song's cover with a beating ring.
    private(set) lazy var dockArt = DockArtController(settings: settings, nowPlaying: nowPlaying, features: audio.store, power: power)
    /// The lyrics of the song that plays (started with the services).
    private(set) lazy var lyrics: LyricsController = {
        let controller = LyricsController(
            settings: settings, nowPlaying: nowPlaying, finder: services.lyricsFinder, makeChain: services.makeLyricsChain
        )
        controller.onOpenSettings = { [weak self] in self?.showSettings(.lyrics) }
        controller.siteLyrics = services.siteLyrics
        return controller
    }()
    /// The sound effects, wherever the followed player's sound can be reached.
    private(set) lazy var effects = SoundEffectsController(
        settings: settings, nowPlaying: nowPlaying, audio: audio, localPlayer: localPlayer, bridge: services.bridgeServer
    )
    /// Times plain lyrics against the song on this Mac (Beta).
    private(set) lazy var aligner = LyricsAlignmentController(
        lyrics: lyrics, nowPlaying: nowPlaying, audio: audio, settings: settings, isDemo: demo != nil
    )
    /// Keeps the lyrics on time by listening (Settings › Lyrics).
    private(set) lazy var lyricsSync: LyricsAutoSync = {
        let sync = LyricsAutoSync(lyrics: lyrics, nowPlaying: nowPlaying, audio: audio, settings: settings)
        // One listener at a time: alignment has the audio while it works.
        sync.isSuspended = { [weak self] in self?.aligner.isBusy ?? false }
        return sync
    }()
    /// The live wallpaper on every display (started with the services).
    private(set) lazy var wallpaper: WallpaperController = {
        let lookups: WallpaperLookups
        if demo == nil {
            lookups = .live(services: services)
        } else if options.wallpaperSong != nil {
            lookups = .online(storefront: services.storefront.code)
        } else {
            lookups = .offline
        }
        return WallpaperController(
            settings: settings, nowPlaying: nowPlaying, power: power, demo: demo, lookups: lookups,
            songOverride: demo == nil ? nil : options.wallpaperSong,
            forcedKind: options.wallpaperSource.flatMap(WallpaperCandidate.Kind.init(rawValue:))
        )
    }()
    /// The desktop widgets: clock, Continue Playing, the player and its
    /// queue (started with the services).
    private(set) lazy var desktopPlayer: DesktopPlayerController = {
        let controller = DesktopPlayerController(
            settings: settings, nowPlaying: nowPlaying, services: services, lyrics: lyrics, power: power, demo: demo
        )
        controller.model.onOpenSettings = { [weak self] in self?.showSettings(.player) }
        controller.model.clearDesk = { [weak self] in self?.clearDesk ?? UnavailableDeskClearing() }
        controller.model.wallpaper = wallpaper
        controller.model.onDropFiles = { [weak self] urls, widget, point in
            self?.dropped(urls, onto: widget, at: point) ?? false
        }
        controller.model.onAddSticker = { [weak self] in self?.stickers.pickPhotos() }
        controller.model.local = localPlayer
        controller.model.library = localLibrary
        controller.effects = effects
        controller.audio = audio
        controller.aligner = aligner
        // Beside the lyrics when they show; in Settings otherwise.
        controller.model.onOpenSoundEffects = { [weak self] in
            guard let self else { return }
            if self.settings.lyrics.enabled, self.lyrics.hasSong {
                self.lyrics.panel = .effects
            } else {
                self.showSettings(.sound)
            }
        }
        return controller
    }()

    private init(options: LaunchOptions, settings: AppSettings, demo: DemoProvider?) {
        self.options = options
        self.settings = settings
        self.demo = demo
        self.nowPlaying = NowPlayingModel()
        power = PowerMonitor(simulated: options.mode == .demo ? options.simulatedPower : nil)
        loginItem = LoginItem(canChange: options.mode == .normal)
        deskController = options.mode == .normal
            ? ClearDeskController(workspace: SystemDeskWorkspace(), store: ClearDeskStore(fileURL: ClearDeskStore.standardURL))
            : ClearDeskController(workspace: InventedDeskWorkspace.demo(), store: ClearDeskStore(fileURL: nil))
        // Only a normal run may play another app's sound with effects, and
        // so only a normal run can mute an app; demo and smoke runs cannot.
        EffectsOutput.isAllowed = options.mode == .normal
        if #available(macOS 14.2, *) {
            ProcessTapSession.mutingAllowed = options.mode == .normal
        }
        let ownAudio = OwnAudioTap()
        // Silent in smoke runs and for the demo's generated tones.
        localPlayer = LocalPlayer(tap: ownAudio, publishesNowPlaying: options.mode == .normal, muted: options.mode == .smoke || options.demoLocal)
        localLibrary = LocalLibraryStore(fileURL: options.mode == .normal ? LocalLibraryStore.standardURL : nil)
        let audio = AudioTapEngine(demo: demo, ownAudio: ownAudio)
        self.audio = audio
        if let demo {
            // The second demo player starts two songs later.
            let second = options.demoConflict
                ? DemoProvider(
                    songs: Array(DemoCatalog.songs[2...] + DemoCatalog.songs[..<2]),
                    id: "demo-b", bundleIdentifier: "com.sinanmertsener.Ahenk.demo-b"
                )
                : nil
            services = .demo(demo, second: second, settings: settings, features: audio.store, local: localPlayer.engine)
        } else {
            services = .live(settings: settings, features: audio.store, local: localPlayer.engine)
        }
    }

    /// Smoke runs, demo scenes and `--language` work on an in-memory copy of
    /// the user's settings so they can switch languages, sizes and toggles
    /// without touching the real ones.
    @discardableResult
    static func bootstrap(options: LaunchOptions, defaults: UserDefaults = .standard) -> AppEnvironment {
        let settings = options.usesDetachedSettings
            ? AppSettings.detachedCopy(of: defaults)
            : AppSettings(defaults: defaults)
        if let code = options.language, let language = AppLanguage(rawValue: code) {
            settings.general.language = language
        }
        if options.wallpaperSource == "off" {
            settings.wallpaper.enabled = false
        }
        if options.optimized {
            settings.general.optimizedMode = true
        }
        if options.fullRate {
            settings.general.lighterOnBattery = false
        }
        switch options.dockArt {
        case "on":
            settings.dock.albumArtIcon = true
            settings.dock.beatRing = true
        case "still":
            settings.dock.albumArtIcon = true
            settings.dock.beatRing = false
        case "off":
            settings.dock.albumArtIcon = false
        default:
            break
        }
        if let name = options.lyricsStyle {
            if let style = LyricStyle(rawValue: name) {
                settings.lyrics.style = style
                settings.lyrics.enabled = true
            } else if name == "off" {
                settings.lyrics.enabled = false
            }
        }
        let environment = AppEnvironment(
            options: options,
            settings: settings,
            demo: options.usesDemoContent ? DemoProvider() : nil
        )
        current = environment
        return environment
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        settingsWindow.show(pane: pane)
    }

    /// Files dropped on a desktop widget: pictures become stickers there;
    /// folders and song files play (on the list and the player).
    @discardableResult
    func dropped(_ urls: [URL], onto widget: DesktopWidget, at point: CGPoint?) -> Bool {
        let pictures = urls.filter(FileKinds.isPicture)
        for url in pictures {
            Task { await stickers.add(photoAt: url, at: point, onto: widget) }
        }
        let music = urls.filter { FileKinds.isFolder($0) || FileKinds.isSong($0) }
        if !music.isEmpty, widget == .continuePlaying || widget == .player {
            desktopPlayer.model.playDropped(music)
        }
        return !pictures.isEmpty || !music.isEmpty
    }
}
