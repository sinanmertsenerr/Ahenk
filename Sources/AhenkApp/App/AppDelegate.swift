import AhenkKit
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    private var statusMenu: StatusMenuController?
    private var observers: [AnyObject] = []
    private var signalSources: [DispatchSourceSignal] = []
    /// This process lost the single-instance check and must not touch
    /// anything on the way out.
    private var isDuplicate = false
    private let log = AhenkLogger(category: "app")

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(environment: environment)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        let options = environment.options
        if options.mode == .smoke {
            runSmoke()
            return
        }
        // A second copy (dist/ next to /Applications, a double `open -n`)
        // would double every desktop feature. Hand over and quit, before any
        // side effect.
        if !options.allowsMultipleInstances, let other = otherRunningInstance() {
            isDuplicate = true
            log.notice("Ahenk is already running (pid \(other.processIdentifier)); bringing it forward and quitting")
            other.activate()
            NSApp.terminate(nil)
            return
        }
        startServices()
    }

    private func startServices() {
        let settings = environment.settings
        log.info("Settings: \(describe(settings.origin)), language \(settings.general.language.rawValue)")

        let status = StatusMenuController(environment: environment)
        status.install()
        statusMenu = status

        if environment.demo != nil {
            log.notice("Demo mode: invented songs, generated covers, 120 BPM")
        }
        let services = environment.services
        services.start(settings: settings)
        environment.nowPlaying.attach(
            provider: services.hub, artwork: services.artwork, lyrics: services.lyrics, features: services.features
        )
        // Listens to the followed player's app while music plays.
        environment.audio.start(hub: services.hub, settings: settings)
        // Battery, Low Power Mode and heat make drawing lighter.
        environment.power.start()
        // The edge light follows the music, the cover and the settings.
        environment.light.start()
        scheduleDemoCommands()

        observers.append(ChangeObserver({ settings.general.language }) { [weak self] language in
            guard let self else { return }
            NSApp.mainMenu = MainMenu.build(environment: self.environment)
            self.log.info("Language is now \(language.rawValue)")
        })
        observers.append(ChangeObserver({ settings.general.verboseLogging }) { verbose in
            Log.isVerbose = verbose
        })

        if let pane = environment.options.settingsPane {
            environment.showSettings(SettingsPane(argument: pane))
        }
        log.info("Ready")
    }

    private func runSmoke() {
        log.notice("Smoke test started")
        // Never hang: if a check blocks, report that and leave anyway.
        let watchdog = DispatchWorkItem {
            var report = SmokeReport(version: AppInfo.version, build: AppInfo.build, commit: AppInfo.commit, bundlePath: Bundle.main.bundlePath)
            report.record(.init(name: "smoke", status: .error, detail: "timed out after 60 s", milliseconds: 60_000))
            report.finish()
            try? report.write(to: SmokeReport.standardURL)
            Log.flush()
            exit(0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)

        Task { @MainActor in
            let report = await SmokeRunner(environment: environment).run()
            watchdog.cancel()
            do {
                try report.write(to: SmokeReport.standardURL)
            } catch {
                log.error("Could not write \(SmokeReport.standardURL.path): \(error)")
            }
            let failed = report.subsystems.filter { $0.status == .error }.map(\.name)
            log.notice(report.ok
                ? "Smoke test passed (\(report.subsystems.count) subsystems), report at \(SmokeReport.standardURL.path)"
                : "Smoke test FAILED: \(failed.joined(separator: ", ")), report at \(SmokeReport.standardURL.path)")
            Log.flush()
            exit(0)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon with no window open shows Settings.
        if !flag, !isDuplicate, environment.options.mode != .smoke {
            environment.showSettings()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard !isDuplicate, environment.options.mode != .smoke else { return nil }
        let menu = NSMenu()
        QuickMenu.populate(menu, environment: environment, placement: .dock)
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicate else {
            Log.flush()
            return
        }
        // Later steps restore the user's desktop here (wallpaper, hidden apps).
        environment.light.stop()
        environment.power.stop()
        // Removes the process tap and its private aggregate device.
        environment.audio.stop()
        environment.nowPlaying.detach()
        // Ends the MediaRemote adapter child process.
        environment.services.stop()
        log.notice("Quitting")
        Log.flush()
    }

    /// `--demo-pause-after` / `--demo-resume-after`: pause and resume the
    /// demo song by itself (to watch the light fade out, stop drawing and
    /// come back without touching anything).
    private func scheduleDemoCommands() {
        guard let demo = environment.demo else { return }
        let options = environment.options
        for (delay, command) in [(options.demoPauseAfter, PlaybackCommand.pause), (options.demoResumeAfter, .play)] {
            guard let delay else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [log] in
                log.notice("Demo: \(command == .pause ? "pausing" : "resuming") (launch argument)")
                Task { await demo.perform(command) }
            }
        }
    }

    // MARK: Helpers

    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// `pkill -x Ahenk` and Ctrl-C quit through the normal path, so cleanup
    /// in `applicationWillTerminate` always runs.
    private func installTerminationSignals() {
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.log.notice("Received \(name); quitting")
                NSApp.terminate(nil)
                // If anything blocks the normal path, still leave.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Log.flush()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func describe(_ origin: AppSettings.Origin) -> String {
        switch origin {
        case .memory: "in memory"
        case .fresh: "defaults (first launch)"
        case .stored(let version): "loaded (schema \(version))"
        case .recovered(let reason): "reset to defaults, stored value was unreadable (\(reason))"
        }
    }
}
