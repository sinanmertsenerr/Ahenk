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
    /// Present in `--demo` and `--smoke`.
    let demo: DemoProvider?
    /// Step 9 replaces the placeholder with the real Clear Desk.
    var clearDesk: DeskClearing = UnavailableDeskClearing()

    private(set) lazy var settingsWindow = SettingsWindowController(environment: self)

    private init(options: LaunchOptions, settings: AppSettings, demo: DemoProvider?) {
        self.options = options
        self.settings = settings
        self.demo = demo
        self.nowPlaying = NowPlayingModel()
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
