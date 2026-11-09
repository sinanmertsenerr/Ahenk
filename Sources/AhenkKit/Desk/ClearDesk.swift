import Foundation

/// A running app as Clear Desk sees it.
public struct DeskApp: Hashable, Sendable, Codable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var name: String
    /// Has a Dock icon and a menu bar (activation policy "regular"). Menu
    /// bar extras and background helpers are left alone: without a Dock icon
    /// the user could not bring them back by hand.
    public var isRegular: Bool
    public var isHidden: Bool
    /// One of its windows fills a whole display: a full-screen Space, or a
    /// borderless full-screen window (a game, a slideshow).
    public var isFullScreen: Bool

    public init(pid: Int32, bundleIdentifier: String?, name: String, isRegular: Bool = true, isHidden: Bool = false, isFullScreen: Bool = false) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isRegular = isRegular
        self.isHidden = isHidden
        self.isFullScreen = isFullScreen
    }
}

/// An app Clear Desk hid (or tried to): enough to find the same process
/// again, never another launch of the same app.
public struct DeskAppRecord: Hashable, Sendable, Codable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var name: String

    public init(pid: Int32, bundleIdentifier: String?, name: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    public init(_ app: DeskApp) {
        self.init(pid: app.pid, bundleIdentifier: app.bundleIdentifier, name: app.name)
    }

    /// The same process: the same PID and (when both know it) the same
    /// bundle, so a reused PID is never mistaken for the app.
    public func matches(_ app: DeskApp) -> Bool {
        guard app.pid == pid else { return false }
        guard let bundleIdentifier, let other = app.bundleIdentifier else { return true }
        return bundleIdentifier == other
    }
}

/// Why Clear Desk leaves an app as it is.
public enum DeskSkipReason: String, Sendable, Codable, Equatable {
    /// Ahenk itself: its widgets and the wallpaper stay.
    case ahenk
    /// A menu bar extra or a background app.
    case notRegular
    /// The user had hidden it already; it stays hidden afterwards too.
    case alreadyHidden
    /// It lives in its own full-screen Space (or fills a display): hiding it
    /// would switch Spaces, and it does not cover the desktop.
    case fullScreen
}

/// What the first click does.
public struct DeskClearingPlan: Equatable, Sendable {
    public struct Skipped: Equatable, Sendable {
        public var app: DeskApp
        public var reason: DeskSkipReason
    }

    /// Hidden in this order: back to front, the frontmost app last.
    public var toHide: [DeskApp]
    public var skipped: [Skipped]
}

/// What the second click does.
public struct DeskRestorePlan: Equatable, Sendable {
    /// Shown in this order: back to front, so the app that was in front
    /// ends up in front again.
    public var toUnhide: [DeskAppRecord]
    /// Made active at the end: the app that was in front when the desk was
    /// cleared (only when Ahenk hid it and shows it again).
    public var activate: DeskAppRecord?
    /// Hidden by Ahenk but gone or no longer hidden (quit, shown by hand).
    public var leftAlone: [DeskAppRecord]
}

/// Clear Desk as a state machine: one click hides every other app that is
/// in view, a second click shows exactly those again.
///
/// - Only regular apps that are visible are hidden; Ahenk, menu bar extras,
///   apps the user had hidden and full-screen apps are left alone.
/// - Hide and show only: nothing is ever quit or relaunched.
/// - An app the user brings back by hand (or that quits, or refuses to
///   hide) is forgotten, so the second click never hides or shows it; an
///   app launched meanwhile was never hidden by Ahenk and stays as it is.
/// - Apps are matched by process, never by name: a relaunched app is a
///   new process and is left alone.
///
/// Codable so a cleared desk survives Ahenk quitting unexpectedly (the
/// next launch shows the apps again).
public struct ClearDeskState: Codable, Equatable, Sendable {
    /// In hiding order (back to front).
    public private(set) var hidden: [DeskAppRecord] = []
    /// Asked to hide but still visible: left as they are.
    public private(set) var refused: [DeskAppRecord] = []
    /// The app in front when the desk was cleared.
    public private(set) var frontmost: DeskAppRecord?
    public private(set) var clearedAt: Date?

    public init() {}

    public var isCleared: Bool { clearedAt != nil }

    /// Plans the first click and enters the cleared state.
    ///
    /// - Parameters:
    ///   - apps: every running app.
    ///   - ownPID: Ahenk's process.
    ///   - windowOrder: PIDs in the front-to-back order of their windows on
    ///     screen (apps without windows on screen count as behind them).
    ///   - frontmostPID: the active app.
    public mutating func clear(
        apps: [DeskApp], ownPID: Int32, windowOrder: [Int32], frontmostPID: Int32?, at date: Date
    ) -> DeskClearingPlan {
        var toHide: [DeskApp] = []
        var skipped: [DeskClearingPlan.Skipped] = []
        for app in apps {
            if let reason = Self.skipReason(app, ownPID: ownPID) {
                skipped.append(.init(app: app, reason: reason))
            } else {
                toHide.append(app)
            }
        }
        // Back to front: apps without on-screen windows first, then the
        // window order reversed; the active app always last.
        let rank = Dictionary(windowOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        toHide.sort { a, b in
            let aFront = a.pid == frontmostPID, bFront = b.pid == frontmostPID
            if aFront != bFront { return bFront }
            let ra = rank[a.pid] ?? Int.max, rb = rank[b.pid] ?? Int.max
            if ra != rb { return ra > rb }
            return a.pid < b.pid
        }
        hidden = toHide.map(DeskAppRecord.init)
        refused = []
        frontmost = frontmostPID.flatMap { pid in toHide.first { $0.pid == pid } }.map(DeskAppRecord.init)
        clearedAt = date
        return DeskClearingPlan(toHide: toHide, skipped: skipped)
    }

    public static func skipReason(_ app: DeskApp, ownPID: Int32) -> DeskSkipReason? {
        if app.pid == ownPID { return .ahenk }
        if !app.isRegular { return .notRegular }
        if app.isHidden { return .alreadyHidden }
        if app.isFullScreen { return .fullScreen }
        return nil
    }

    /// The app stayed visible after it was asked to hide.
    public mutating func noteRefused(pid: Int32) {
        guard let index = hidden.firstIndex(where: { $0.pid == pid }) else { return }
        refused.append(hidden.remove(at: index))
        if frontmost?.pid == pid { frontmost = nil }
    }

    /// The user showed an app Ahenk hid (clicked it in the Dock, switched to
    /// it): it is theirs again, and the second click leaves it alone.
    public mutating func noteShown(pid: Int32) {
        forget(pid)
    }

    /// An app quit (a later process with its PID is another app).
    public mutating func noteTerminated(pid: Int32) {
        forget(pid)
        refused.removeAll { $0.pid == pid }
    }

    private mutating func forget(_ pid: Int32) {
        hidden.removeAll { $0.pid == pid }
        if frontmost?.pid == pid { frontmost = nil }
    }

    /// Plans the second click and leaves the cleared state: the apps Ahenk
    /// hid that still run (the same process) and are still hidden.
    public mutating func restore(apps: [DeskApp]) -> DeskRestorePlan {
        var toUnhide: [DeskAppRecord] = []
        var leftAlone: [DeskAppRecord] = []
        // Back to front, the reverse of front to back: the hiding order
        // already is back to front with the active app last.
        for record in hidden {
            if let app = apps.first(where: record.matches), app.isHidden {
                toUnhide.append(record)
            } else {
                leftAlone.append(record)
            }
        }
        let activate = frontmost.flatMap { front in toUnhide.contains(front) ? front : nil }
        self = ClearDeskState()
        return DeskRestorePlan(toUnhide: toUnhide, activate: activate, leftAlone: leftAlone)
    }
}

/// Where a cleared desk is remembered while it lasts
/// (`~/Library/Application Support/Ahenk/ClearDesk.json`): if Ahenk quits
/// without the second click (a crash, a forced quit), the next launch shows
/// the apps it hid.
public struct ClearDeskStore: Sendable {
    /// A record older than this is from another session (PIDs are
    /// meaningless after a restart) and is dropped.
    public static let maximumAge: TimeInterval = 12 * 3600

    public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk", isDirectory: true)
            .appendingPathComponent("ClearDesk.json")
    }

    public func save(_ state: ClearDeskState) {
        guard let fileURL else { return }
        guard state.isCleared else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            AhenkLogger(category: "desk").error("Could not remember the cleared desk: \(error.localizedDescription)")
        }
    }

    /// A cleared desk left behind by an earlier run (and removes it).
    public func takeLeftover(now: Date = Date()) -> ClearDeskState? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(ClearDeskState.self, from: data), let cleared = state.clearedAt,
              now.timeIntervalSince(cleared) < Self.maximumAge, now >= cleared
        else { return nil }
        return state
    }
}
