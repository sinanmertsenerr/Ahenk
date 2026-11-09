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
    /// Step 9 replaces the placeholder with the real Clear Desk.
    var clearDesk: DeskClearing = UnavailableDeskClearing()

    private(set) lazy var settingsWindow = SettingsWindowController(environment: self)
    /// The edge light on every screen (started with the services).
    private(set) lazy var light = EdgeLightController(
        settings: settings, nowPlaying: nowPlaying, features: audio.store, power: power
    )
    /// The desktop widgets: clock, Continue Playing, the player and its
    /// queue (started with the services).
    private(set) lazy var desktopPlayer: DesktopPlayerController = {
        let controller = DesktopPlayerController(settings: settings, nowPlaying: nowPlaying, services: services, demo: demo)
        controller.model.onOpenSettings = { [weak self] in self?.showSettings(.player) }
        controller.model.clearDesk = { [weak self] in self?.clearDesk ?? UnavailableDeskClearing() }
        return controller
    }()

    private init(options: LaunchOptions, settings: AppSettings, demo: DemoProvider?) {
        self.options = options
        self.settings = settings
        self.demo = demo
        self.nowPlaying = NowPlayingModel()
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

    /// Smoke runs work on an in-memory copy of the user's settings so they
    /// can switch languages and toggles without touching the real ones.
    @discardableResult
    static func bootstrap(options: LaunchOptions, defaults: UserDefaults = .standard) -> AppEnvironment {
        let settings = options.mode == .smoke
            ? AppSettings.detachedCopy(of: defaults)
            : AppSettings(defaults: defaults)
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
}
