import AhenkKit
import AppKit
import os

/// Which apps run, from NSWorkspace. Queries ask NSRunningApplication each
/// time (never a cached list), so the "is it running?" check right before a
/// script is current.
final class RunningApps: AppPresenceMonitoring, @unchecked Sendable {
    // Safety: `continuations` is behind its lock; `observers` is written once
    // in `init` and read in `deinit`.
    private let continuations = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<AppPresenceChange>.Continuation]())
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier
                else { return }
                self?.announce(AppPresenceChange(bundleIdentifier: id, isRunning: running))
            })
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
    }

    func processIdentifier(of bundleIdentifier: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }?.processIdentifier
    }

    func changes() -> AsyncStream<AppPresenceChange> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<AppPresenceChange>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuations.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: key) }
        }
        return stream
    }

    private func announce(_ change: AppPresenceChange) {
        continuations.withLock { Array($0.values) }.forEach { $0.yield(change) }
    }
}

/// Every app on this Mac that opens web links: the browsers.
enum BrowserRegistry {
    static func installedBrowsers() -> Set<String> {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: probe)
        let ids = apps.compactMap { Bundle(url: $0)?.bundleIdentifier }
        // Music apps that also open links stay music apps.
        return Set(ids).subtracting(KnownApps.musicApps.keys)
    }
}

/// Names and icons of apps, for menus and Settings.
@MainActor
final class AppDirectory {
    private var names: [String: String] = [:]
    private var icons: [String: NSImage] = [:]

    func name(for bundleIdentifier: String) -> String {
        if let cached = names[bundleIdentifier] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
            ?? KnownApps.displayNames[bundleIdentifier]
            ?? bundleIdentifier
        names[bundleIdentifier] = name
        return name
    }

    func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    func icon(for bundleIdentifier: String) -> NSImage? {
        if let cached = icons[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleIdentifier] = icon
        return icon
    }
}
