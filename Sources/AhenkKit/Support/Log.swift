import Foundation
import os

public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug
    case info
    case notice
    case error
    case fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Fixed-width label used in the log file.
    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO "
        case .notice: "NOTE "
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
    }
}

/// Process-wide logging configuration. Every `AhenkLogger` writes to the
/// unified log (Console.app, subsystem `com.sinanmertsener.Ahenk`) and, once
/// `configure` has run, to a rolling file in `~/Library/Logs/Ahenk`.
public enum Log {
    public static let subsystem = "com.sinanmertsener.Ahenk"

    private struct State: Sendable {
        var file: LogFile?
        var verbose = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Attaches the file sink. `verbose` also writes debug-level lines to it.
    public static func configure(file: LogFile?, verbose: Bool) {
        state.withLock {
            $0.file = file
            $0.verbose = verbose
        }
    }

    public static var isVerbose: Bool {
        get { state.withLock { $0.verbose } }
        set { state.withLock { $0.verbose = newValue } }
    }

    public static var file: LogFile? { state.withLock { $0.file } }

    /// Blocks until every line so far is on disk (before exiting).
    public static func flush() {
        file?.flush()
    }

    /// `~/Library/Logs/Ahenk`.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ahenk", isDirectory: true)
    }

    fileprivate static func emit(_ level: LogLevel, category: String, logger: Logger, message: String) {
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
        let (file, verbose) = state.withLock { ($0.file, $0.verbose) }
        guard let file, level > .debug || verbose else { return }
        file.write(level: level, category: category, message: message)
    }
}

/// A named log category, e.g. `AhenkLogger(category: "settings")`.
public struct AhenkLogger: Sendable {
    public let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Log.subsystem, category: category)
    }

    /// Skipped entirely (the message is not even built) unless verbose
    /// logging is on, so it is fine in hot paths.
    public func debug(_ message: @autoclosure () -> String) {
        guard Log.isVerbose else { return }
        Log.emit(.debug, category: category, logger: logger, message: message())
    }

    public func info(_ message: @autoclosure () -> String) {
        Log.emit(.info, category: category, logger: logger, message: message())
    }

    public func notice(_ message: @autoclosure () -> String) {
        Log.emit(.notice, category: category, logger: logger, message: message())
    }

    public func error(_ message: @autoclosure () -> String) {
        Log.emit(.error, category: category, logger: logger, message: message())
    }

    public func fault(_ message: @autoclosure () -> String) {
        Log.emit(.fault, category: category, logger: logger, message: message())
    }
}
