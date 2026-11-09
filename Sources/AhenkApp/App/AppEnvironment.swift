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
    let power = PowerMonitor()
    /// Present in `--demo` and `--smoke`.
    let demo: DemoProvider?
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
    /// Keeps the lyrics on time by listening (Settings › Lyrics).
    private(set) lazy var lyricsSync = LyricsAutoSync(lyrics: lyrics, nowPlaying: nowPlaying, audio: audio, settings: settings)
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
        return controller
    }()

    private init(options: LaunchOptions, settings: AppSettings, demo: DemoProvider?) {
        self.options = options
        self.settings = settings
        self.demo = demo
        self.nowPlaying = NowPlayingModel()
        deskController = options.mode == .normal
            ? ClearDeskController(workspace: SystemDeskWorkspace(), store: ClearDeskStore(fileURL: ClearDeskStore.standardURL))
            : ClearDeskController(workspace: InventedDeskWorkspace.demo(), store: ClearDeskStore(fileURL: nil))
        let audio = AudioTapEngine(demo: demo)
        self.audio = audio
        if let demo {
            // The second demo player starts two songs later.
            let second = options.demoConflict
                ? DemoProvider(
                    songs: Array(DemoCatalog.songs[2...] + DemoCatalog.songs[..<2]),
                    id: "demo-b", bundleIdentifier: "com.sinanmertsener.Ahenk.demo-b"
                )
                : nil
            services = .demo(demo, second: second, settings: settings, features: audio.store)
        } else {
            services = .live(settings: settings, features: audio.store)
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

    /// Files dropped on a desktop widget: pictures become stickers there.
    @discardableResult
    func dropped(_ urls: [URL], onto widget: DesktopWidget, at point: CGPoint?) -> Bool {
        let pictures = urls.filter(FileKinds.isPicture)
        for url in pictures {
            Task { await stickers.add(photoAt: url, at: point, onto: widget) }
        }
        return !pictures.isEmpty
    }
}
