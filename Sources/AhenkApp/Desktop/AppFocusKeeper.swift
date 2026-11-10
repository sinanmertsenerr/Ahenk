import AhenkKit
import AppKit

/// Keeps a music app in the background while Ahenk starts a song in it:
/// notes which app is in front, watches the front while the start runs and
/// for a moment after it, and gives it back as soon as the music app takes
/// it (see ``FocusKeeping``). A music app that was hidden is hidden again.
/// Nothing happens when the music app was in front already.
@MainActor
final class AppFocusKeeper {
    private let bundleIdentifier: String
    private let log = AhenkLogger(category: "player")

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    func keepingInBackground<T: Sendable>(_ start: () async -> T) async -> T {
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let previous = NSWorkspace.shared.frontmostApplication, previous != target, !previous.isTerminated
        else { return await start() }
        let watch = Watch(target: target, previous: previous, wasHidden: target.isHidden, log: log)
        watch.begin()
        let result = await start()
        // The app may come forward a moment after it took the command.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(FocusKeeping.watchAfterStart))
            watch.end()
        }
        return result
    }

    @MainActor
    private final class Watch {
        let target: NSRunningApplication
        let previous: NSRunningApplication
        let wasHidden: Bool
        let log: AhenkLogger
        private var token: NSObjectProtocol?
        private var returns = 0
        private var isReturning = false

        init(target: NSRunningApplication, previous: NSRunningApplication, wasHidden: Bool, log: AhenkLogger) {
            self.target = target
            self.previous = previous
            self.wasHidden = wasHidden
            self.log = log
        }

        func begin() {
            let pid = target.processIdentifier
            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                guard activated == pid else { return }
                MainActor.assumeIsolated { self?.tookFront() }
            }
        }

        func end() {
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            token = nil
        }

        private func tookFront() {
            guard !isReturning, returns < FocusKeeping.maximumReturns else { return }
            isReturning = true
            returns += 1
            Task { @MainActor in
                await giveBack()
                isReturning = false
            }
        }

        private func giveBack() async {
            let started = Date()
            let name = previous.localizedName ?? previous.bundleIdentifier ?? "the app before"
            let steps = FocusKeeping.steps(
                wasHidden: wasHidden,
                previousIsRegularApp: previous.activationPolicy == .regular,
                previousIsFinder: previous.bundleIdentifier == "com.apple.finder"
            )
            for step in steps {
                guard !previous.isTerminated else { break }
                switch step {
                case .hide:
                    target.hide()
                case .activatePrevious:
                    previous.activate()
                case .reopenPrevious:
                    guard let url = previous.bundleURL else { continue }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.addsToRecentItems = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }
                if await leftFront() {
                    let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                    log.info("The music app came to the front to start the song; the front went back to \(name) (\(step.rawValue), \(milliseconds) ms)")
                    return
                }
            }
            log.notice("The music app came to the front to start the song and stayed there")
        }

        /// Whether the music app leaves the front within a step's patience.
        private func leftFront() async -> Bool {
            let deadline = Date().addingTimeInterval(FocusKeeping.stepPatience)
            while Date() < deadline {
                if NSWorkspace.shared.frontmostApplication != target { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return NSWorkspace.shared.frontmostApplication != target
        }
    }
}
