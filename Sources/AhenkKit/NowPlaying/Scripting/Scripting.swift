import Foundation

/// An AppleScript result as plain values, so it can cross threads and be
/// written down in tests. Numbers stay numbers (no locale-dependent text).
public indirect enum ScriptValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    /// Raw bytes (artwork) or any other value the runner does not convert.
    case data(Data)
    case list([ScriptValue])
    /// AppleScript's `missing value`.
    case missing

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        switch self {
        case .number(let value): value
        case .text(let value): Double(value)
        default: nil
        }
    }

    public var boolean: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var data: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    public var list: [ScriptValue]? {
        if case .list(let value) = self { return value }
        return nil
    }
}

/// A failed script, with the Apple Event error number.
public struct ScriptError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// errAEEventNotPermitted: the user turned Automation off for Ahenk.
    public static let automationDenied = -1743
    /// errAEEventWouldRequireUserConsent.
    public static let consentRequired = -1744
    /// procNotFound and connectionInvalid: the app is gone.
    public static let appNotRunningCodes: Set<Int> = [-600, -609]
    /// errAETimeout.
    public static let timeout = -1712

    public var isAutomationDenied: Bool { code == Self.automationDenied || code == Self.consentRequired }
    public var isAppGone: Bool { Self.appNotRunningCodes.contains(code) }
    public var description: String { "\(code): \(message)" }
}

/// Whether Ahenk may send Apple Events to an app (System Settings ›
/// Privacy & Security › Automation).
public enum AutomationPermission: String, Sendable, Equatable {
    case granted
    case denied
    /// macOS has not asked yet; asking shows its prompt.
    case notDetermined
    /// The app is not running, so macOS cannot tell.
    case appNotRunning
    case unknown
}

/// Runs AppleScript against one app.
///
/// `tell application "…"` LAUNCHES the app when it is not running, so
/// callers must check `AppPresenceMonitoring` right before every run.
public protocol ScriptRunning: Sendable {
    func run(_ source: String) async -> Result<ScriptValue, ScriptError>
    /// Asks macOS without a prompt unless `askIfNeeded`.
    func automationPermission(for bundleIdentifier: String, askIfNeeded: Bool) async -> AutomationPermission
}

public struct AppPresenceChange: Sendable, Equatable {
    public var bundleIdentifier: String
    public var isRunning: Bool

    public init(bundleIdentifier: String, isRunning: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
    }
}

/// Which apps run (NSWorkspace in the app, a fake in tests).
public protocol AppPresenceMonitoring: Sendable {
    func isRunning(_ bundleIdentifier: String) -> Bool
    func processIdentifier(of bundleIdentifier: String) -> Int32?
    /// Launches and quits, as they happen.
    func changes() -> AsyncStream<AppPresenceChange>
}

/// Play state as the music apps' notifications spell it.
public enum NotifiedPlayerState: String, Sendable, Equatable {
    case playing = "Playing"
    case paused = "Paused"
    case stopped = "Stopped"

    init?(_ value: Any?) {
        guard let text = value as? String else { return nil }
        self.init(rawValue: text)
    }
}
