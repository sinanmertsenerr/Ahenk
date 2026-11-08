import Foundation
import os

/// Runs the vendored `mediaremote-adapter`: a perl script that loads the
/// adapter framework into the Apple-signed `/usr/bin/perl`, the one process
/// macOS (15.4 and later) still lets read the system's Now Playing.
///
/// `stream()` keeps one child process alive and decodes its output;
/// commands run the script once each. Every child is tracked so
/// ``terminateAll()`` can stop them when Ahenk quits.
public final class MediaRemoteAdapter: Sendable {
    /// How to start the adapter. Tests point this at `/bin/sh` scripts.
    public struct Invocation: Sendable, Equatable {
        public var executable: URL
        public var baseArguments: [String]

        public init(executable: URL, baseArguments: [String]) {
            self.executable = executable
            self.baseArguments = baseArguments
        }

        /// `/usr/bin/perl <script> <framework> …`.
        public static func perl(script: URL, framework: URL) -> Invocation {
            Invocation(executable: URL(fileURLWithPath: "/usr/bin/perl"), baseArguments: [script.path, framework.path])
        }

        /// The script and framework side by side in `directory` (the app's
        /// `Contents/Resources/adapter`), or `nil` when either is missing.
        public static func bundled(in directory: URL) -> Invocation? {
            locate(script: directory.appendingPathComponent("mediaremote-adapter.pl"),
                   framework: directory.appendingPathComponent("MediaRemoteAdapter.framework"))
        }

        /// The source tree's layout: `bin/` holds the script, `build/` the
        /// framework that `Scripts/build-adapter.sh` produces.
        public static func sourceTree(at vendorDirectory: URL) -> Invocation? {
            locate(script: vendorDirectory.appendingPathComponent("bin/mediaremote-adapter.pl"),
                   framework: vendorDirectory.appendingPathComponent("build/MediaRemoteAdapter.framework"))
        }

        private static func locate(script: URL, framework: URL) -> Invocation? {
            let fm = FileManager.default
            let binary = framework.appendingPathComponent("Versions/A/MediaRemoteAdapter")
            guard fm.isReadableFile(atPath: script.path), fm.fileExists(atPath: binary.path) else { return nil }
            return .perl(script: script, framework: framework)
        }
    }

    public let invocation: Invocation
    private let children = OSAllocatedUnfairLock(initialState: [UUID: ChildProcess]())
    private static let log = AhenkLogger(category: "adapter")

    public init(invocation: Invocation) {
        self.invocation = invocation
    }

    /// Number of adapter processes alive right now.
    public var runningProcessCount: Int {
        children.withLock { $0.count }
    }

    /// Streams the Now Playing state (`stream --micros`). The first payload
    /// is the current state (empty when nothing plays). The stream finishes
    /// when the process exits; cancelling the consumer terminates it.
    public func stream() -> AsyncStream<AdapterPayload> {
        let (stream, continuation) = AsyncStream<AdapterPayload>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let key = UUID()
        let child = ChildProcess(invocation: invocation, arguments: ["stream", "--micros"])
        let decoder = LockedDecoder()
        children.withLock { $0[key] = child }
        continuation.onTermination = { [weak self] _ in
            child.terminate()
            self?.children.withLock { _ = $0.removeValue(forKey: key) }
        }
        do {
            try child.start(
                onLines: { lines in
                    for payload in decoder.decode(lines) {
                        continuation.yield(payload)
                    }
                },
                onExit: { [weak self] status, reason in
                    self?.children.withLock { _ = $0.removeValue(forKey: key) }
                    if reason == .exit, status != 0 {
                        Self.log.error("Adapter stream exited with status \(status)")
                    }
                    continuation.finish()
                }
            )
        } catch {
            Self.log.error("Could not start the adapter: \(error.localizedDescription)")
            children.withLock { _ = $0.removeValue(forKey: key) }
            continuation.finish()
        }
        return stream
    }

    /// The current state once (`get --micros`), or `nil` when the adapter
    /// failed or did not answer within `timeout`.
    public func current(includeArtwork: Bool = true, timeout: TimeInterval = 5) async -> AdapterPayload? {
        var arguments = ["get", "--micros"]
        if !includeArtwork { arguments.append("--no-artwork") }
        guard let result = await runOnce(arguments, timeout: timeout), result.status == 0 else { return nil }
        let text = result.output
        // `get` prints the payload itself, or `null` when nothing plays.
        for line in text.split(separator: 0x0A) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed]) else { continue }
            guard var fields = object as? [String: Any] else { return AdapterPayload() }
            let artwork = AdapterPayload.decodeArtwork(fields["artworkData"] as? String)
            fields.removeValue(forKey: "artworkData")
            return AdapterPayload(fields: fields, artworkData: artwork)
        }
        return AdapterPayload()
    }

    /// Runs one playback command. True when the adapter reported success.
    @discardableResult
    public func run(_ request: MediaRemoteRequest, timeout: TimeInterval = 5) async -> Bool {
        guard let result = await runOnce(request.arguments, timeout: timeout) else { return false }
        if result.status != 0 {
            Self.log.error("Adapter command \(request.arguments.joined(separator: " ")) exited with status \(result.status)")
        }
        return result.status == 0
    }

    /// Terminates every adapter process (when Ahenk quits).
    public func terminateAll() {
        let all = children.withLock { children -> [ChildProcess] in
            defer { children.removeAll() }
            return Array(children.values)
        }
        for child in all { child.terminate() }
    }

    // MARK: One-shot runs

    private struct OneShotResult: Sendable {
        var status: Int32
        var output: Data
    }

    private func runOnce(_ arguments: [String], timeout: TimeInterval) async -> OneShotResult? {
        let key = UUID()
        let child = ChildProcess(invocation: invocation, arguments: arguments)
        children.withLock { $0[key] = child }
        defer { children.withLock { _ = $0.removeValue(forKey: key) } }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: child.runToCompletion(timeout: timeout).map {
                    OneShotResult(status: $0.status, output: $0.output)
                })
            }
        }
    }
}

/// The decoder with a lock, so the pipe callback can own it.
private final class LockedDecoder: @unchecked Sendable {
    // Safety: `decoder` and `splitter` are only touched under `lock`.
    private let lock = NSLock()
    private let decoder = NowPlayingStreamDecoder()

    func decode(_ lines: [Data]) -> [AdapterPayload] {
        lock.lock()
        defer { lock.unlock() }
        return lines.compactMap { decoder.decode(line: $0) }
    }
}

/// One adapter process.
final class ChildProcess: @unchecked Sendable {
    // Safety: `process` is configured before `run()` and afterwards only
    // read (`isRunning`) or terminated, which Process allows from any
    // thread; `splitter`, `exit` and the flags are only touched under `lock`.
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var splitter = LineSplitter()
    private var reachedEnd = false
    private var exit: (status: Int32, reason: Process.TerminationReason)?
    private var onExit: (@Sendable (Int32, Process.TerminationReason) -> Void)?

    init(invocation: MediaRemoteAdapter.Invocation, arguments: [String]) {
        process.executableURL = invocation.executable
        process.arguments = invocation.baseArguments + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }

    /// Streams stdout line by line. `onExit` runs once the process has
    /// exited and its output has been read to the end, so a short-lived
    /// process never loses its last lines.
    func start(
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32, Process.TerminationReason) -> Void
    ) throws {
        lock.withLock { self.onExit = onExit }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self.finish(reachedEnd: true)
                return
            }
            let lines = self.lock.withLock { self.splitter.append(chunk) }
            if !lines.isEmpty { onLines(lines) }
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(exit: (process.terminationStatus, process.terminationReason))
        }
        try process.run()
    }

    private func finish(reachedEnd: Bool = false, exit: (status: Int32, reason: Process.TerminationReason)? = nil) {
        let ready = lock.withLock { () -> (@Sendable (Int32, Process.TerminationReason) -> Void, Int32, Process.TerminationReason)? in
            if reachedEnd { self.reachedEnd = true }
            if let exit { self.exit = exit }
            guard self.reachedEnd, let done = self.exit, let callback = onExit else { return nil }
            onExit = nil
            return (callback, done.status, done.reason)
        }
        if let (callback, status, reason) = ready { callback(status, reason) }
    }

    /// Runs to the end on the calling thread, terminating the process after
    /// `timeout`. `nil` when it could not be started.
    func runToCompletion(timeout: TimeInterval) -> (status: Int32, output: Data)? {
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data)
    }

    /// Stops reading and terminates the process; `onExit` still runs when
    /// it is gone.
    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        finish(reachedEnd: true)
        if process.isRunning {
            process.terminate()
        }
    }
}
