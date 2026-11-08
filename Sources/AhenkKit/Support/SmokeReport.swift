import Foundation

/// The result of an `--smoke` run, written to `~/Library/Logs/Ahenk/smoke.json`.
public struct SmokeReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok
        case error
        /// Not applicable in this environment (e.g. an unbundled dev build).
        case skipped
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var status: Status
        public var detail: String
        public var milliseconds: Double

        public init(name: String, status: Status, detail: String, milliseconds: Double) {
            self.name = name
            self.status = status
            self.detail = detail
            self.milliseconds = milliseconds
        }
    }

    /// Thrown from a check to report `skipped` instead of `ok`.
    public struct Skip: Error, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    public var app: String
    public var version: String
    public var build: String
    public var commit: String
    public var bundlePath: String
    public var system: String
    public var processID: Int32
    public var startedAt: Date
    public var finishedAt: Date?
    /// True when no subsystem reported an error.
    public var ok: Bool
    public var subsystems: [Entry]

    public init(
        app: String = "Ahenk",
        version: String,
        build: String,
        commit: String,
        bundlePath: String,
        system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        startedAt: Date = Date()
    ) {
        self.app = app
        self.version = version
        self.build = build
        self.commit = commit
        self.bundlePath = bundlePath
        self.system = system
        self.processID = processID
        self.startedAt = startedAt
        self.finishedAt = nil
        self.ok = true
        self.subsystems = []
    }

    /// Runs one check, timing it. A returned string is the `ok` detail;
    /// `Skip` marks it skipped; any other error marks it failed. Main-actor
    /// isolated because the checks exercise UI and app state.
    @MainActor
    public mutating func check(_ name: String, _ body: () async throws -> String) async {
        let start = ContinuousClock.now
        let status: Status
        let detail: String
        do {
            detail = try await body()
            status = .ok
        } catch let skip as Skip {
            status = .skipped
            detail = skip.reason
        } catch {
            status = .error
            detail = String(describing: error)
        }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        record(Entry(name: name, status: status, detail: detail, milliseconds: (milliseconds * 10).rounded() / 10))
    }

    public mutating func record(_ entry: Entry) {
        subsystems.append(entry)
        if entry.status == .error { ok = false }
    }

    public mutating func finish(at date: Date = Date()) {
        finishedAt = date
        ok = !subsystems.contains { $0.status == .error }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    /// `~/Library/Logs/Ahenk/smoke.json`.
    public static var standardURL: URL {
        Log.directory.appendingPathComponent("smoke.json")
    }
}

/// A failed smoke check with a readable message.
public struct SmokeFailure: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}
