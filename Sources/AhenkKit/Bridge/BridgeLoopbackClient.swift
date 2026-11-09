import Foundation
import os

/// A stand-in for the browser extension: connects to the bridge on
/// 127.0.0.1 with a chosen `Origin`, sends what the extension sends and reads
/// what Ahenk answers. Used by the smoke check and the tests; never by the
/// running app.
public final class BridgeLoopbackClient: @unchecked Sendable {
    // Safety: URLSession and its task are thread-safe; nothing else mutates.
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    public init(port: UInt16, origin: String?) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.timeoutInterval = 5
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.resume()
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// The origin the real extension has in Chromium browsers.
    public static var extensionOrigin: String { "chrome-extension://\(BridgeOriginPolicy.extensionID)" }

    public func send(_ message: BridgeInbound) async throws {
        let data = try message.encoded()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// The next message from Ahenk (pings answered with pongs on the way).
    public func receive(timeout: TimeInterval = 5) async throws -> BridgeOutbound {
        while true {
            let message = try await receiveRaw(timeout: timeout)
            if message == .ping {
                try await send(.pong)
                continue
            }
            return message
        }
    }

    private func receiveRaw(timeout: TimeInterval) async throws -> BridgeOutbound {
        try await Self.race(timeout) {
            switch try await self.task.receive() {
            case .string(let text): return try BridgeOutbound.decode(Data(text.utf8))
            case .data(let data): return try BridgeOutbound.decode(data)
            @unknown default: throw URLError(.cannotParseResponse)
            }
        }
    }

    /// `work`'s answer, or a timeout after `seconds` without waiting for
    /// `work` to give up: a pending `URLSessionWebSocketTask.receive()` does
    /// not end when its task is cancelled, so a task group would wait for it.
    /// The loser runs on unobserved; after a timed-out receive it would take
    /// the next message, so a client that timed out is only closed.
    private static func race<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let timer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            @Sendable func finish(_ result: Result<T, any Error>) {
                guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                timer.withLock { $0?.cancel() }
                continuation.resume(with: result)
            }
            let worker = Task {
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
            let sleeper = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                worker.cancel()
                finish(.failure(URLError(.timedOut)))
            }
            timer.withLock { $0 = sleeper }
            // The work may have finished before the timer was stored.
            if finished.withLock({ $0 }) { sleeper.cancel() }
        }
    }

    /// Says hello as a browser profile and waits for the welcome. A refused
    /// handshake never answers (see `BridgeProtocol.helloTimeout`): it fails
    /// after `timeout`.
    public func greet(
        profile: String, browser: String = "Loopback", version: Int = BridgeProtocol.version, timeout: TimeInterval = 5
    ) async throws -> BridgeOutbound {
        try await Self.race(timeout) {
            try await self.send(.hello(BridgeHello(
                protocolVersion: version, minimumProtocolVersion: version, extensionVersion: "test", browser: BridgeBrowser(name: browser), profile: profile
            )))
            return try await self.receive(timeout: timeout)
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
