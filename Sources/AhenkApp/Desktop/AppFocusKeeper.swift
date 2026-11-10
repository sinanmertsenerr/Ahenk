import AhenkKit
import AppKit

/// Keeps a music app in the background while Ahenk starts a song in it:
/// notes what the user sees (the active app, whether the music app has a
/// window on screen, whose window is on top), watches the front while the
/// start runs and for a moment after it, and puts things back as soon as
/// the music app comes forward (see ``FocusKeeping``). Nothing happens
/// when the music app was in front already.
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
        let watch = Watch(target: target, previous: previous, log: log)
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
        /// The app whose window was on top (not the music app, not Ahenk).
        let cover: NSRunningApplication?
        let before: FocusKeeping.Before
        let log: AhenkLogger
        private var token: NSObjectProtocol?
        private var returns = 0
        private var isReturning = false

        init(target: NSRunningApplication, previous: NSRunningApplication, log: AhenkLogger) {
            self.target = target
            self.previous = previous
            self.log = log
            let me = ProcessInfo.processInfo.processIdentifier
            // Front to back: owners of the normal windows on this screen
            // (owners and levels only: no contents, no permission).
            let owners = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { info -> pid_t? in
                    guard (info[kCGWindowLayer as String] as? Int) == 0,
                          (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                          let pid = info[kCGWindowOwnerPID as String] as? pid_t
                    else { return nil }
                    return pid
                }
            let cover = owners.first { $0 != target.processIdentifier && $0 != me }.flatMap(NSRunningApplication.init(processIdentifier:))
            self.cover = cover
            before = FocusKeeping.Before(
                musicAppWasVisible: !target.isHidden && owners.contains(target.processIdentifier),
                hasCover: cover != nil,
                coverCanReopen: cover?.activationPolicy == .regular && cover?.bundleIdentifier != "com.apple.finder" && cover?.bundleURL != nil,
                coverIsPrevious: cover == previous
            )
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
                await putBack()
                isReturning = false
            }
        }

        private func putBack() async {
            let started = Date()
            var done: [String] = []
            for step in FocusKeeping.steps(before) {
                switch step {
                case .hide:
                    target.hide()
                    _ = await waits { self.target.isHidden || NSWorkspace.shared.frontmostApplication != self.target }
                case .hideIfStillInFront:
                    guard NSWorkspace.shared.frontmostApplication == target else { continue }
                    target.hide()
                    _ = await waits { NSWorkspace.shared.frontmostApplication != self.target }
                case .activateCover:
                    guard let cover, !cover.isTerminated else { continue }
                    cover.activate()
                    _ = await waits { NSWorkspace.shared.frontmostApplication == cover }
                case .reopenCover:
                    guard let cover, !cover.isTerminated, NSWorkspace.shared.frontmostApplication != cover, let url = cover.bundleURL else { continue }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.addsToRecentItems = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    _ = await waits { NSWorkspace.shared.frontmostApplication == cover }
                case .activatePrevious:
                    guard !previous.isTerminated, NSWorkspace.shared.frontmostApplication != previous else { continue }
                    if previous == NSRunningApplication.current {
                        NSApp.activate()
                    } else {
                        previous.activate()
                    }
                    _ = await waits { NSWorkspace.shared.frontmostApplication == self.previous }
                }
                done.append(step.rawValue)
            }
            let front = NSWorkspace.shared.frontmostApplication
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let state = "front: \(front?.localizedName ?? "?"), music app \(target.isHidden ? "hidden" : "not hidden")"
            if front == target {
                log.notice("The music app came to the front to start the song and stayed there (\(done.joined(separator: ", ")); \(state))")
            } else {
                log.info("The music app came to the front to start the song; put back in \(milliseconds) ms (\(done.joined(separator: ", ")); \(state))")
            }
        }

        /// Waits until `condition` holds, a step's patience at most.
        private func waits(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(FocusKeeping.stepPatience)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return condition()
        }
    }
}
