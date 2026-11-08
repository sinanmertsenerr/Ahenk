import Foundation
import os

/// How the system Now Playing reader is doing, for Settings › Sources.
public enum AdapterHealth: Sendable, Equatable {
    case stopped
    case starting
    case running
    /// The adapter exited and is being restarted.
    case restarting(attempt: Int)
    /// It keeps failing (missing files, a macOS change); retried slowly.
    case unavailable
    /// The adapter is not part of this build (`swift run` without it).
    case missing
}

/// The universal source: whatever app or browser publishes the system's Now
/// Playing, read through the MediaRemote adapter. It sees one player at a
/// time (the session owner), so it cannot notice two players at once; the
/// dedicated providers and the browser bridge can.
///
/// Commands go to the session owner, which is the player this provider
/// reports.
public final class MediaRemoteProvider: NowPlayingProvider, Sendable {
    public static let providerID = "mediaremote"
    public let id = MediaRemoteProvider.providerID

    private let adapter: MediaRemoteAdapter
    private let resolver: @Sendable () -> SourceResolver
    private let clock: @Sendable () -> Date
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let log = AhenkLogger(category: "mediaremote")

    private struct State: Sendable {
        var current: NowPlayingSnapshot?
        var lastPayload: AdapterPayload?
        var artworkAspect: (data: Data, ratio: Double?)?
        var health: AdapterHealth = .stopped
        var continuations: [UUID: AsyncStream<NowPlayingSnapshot?>.Continuation] = [:]
        var healthContinuations: [UUID: AsyncStream<AdapterHealth>.Continuation] = [:]
        var loop: Task<Void, Never>?
    }

    public init(
        adapter: MediaRemoteAdapter,
        resolver: @escaping @Sendable () -> SourceResolver = { .standard },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.resolver = resolver
        self.clock = clock
    }

    deinit {
        state.withLock { $0.loop?.cancel() }
    }

    public var health: AdapterHealth { state.withLock { $0.health } }

    /// Starts the adapter child (idempotent). Restarts it with backoff when
    /// it exits.
    public func start() {
        state.withLock { state in
            guard state.loop == nil else { return }
            state.loop = Task.detached(priority: .utility) { [weak self] in
                await self?.runLoop()
            }
        }
    }

    /// Stops reading and terminates the child process.
    public func stop() {
        let loop = state.withLock { state -> Task<Void, Never>? in
            defer { state.loop = nil }
            return state.loop
        }
        loop?.cancel()
        adapter.terminateAll()
        setHealth(.stopped)
        apply(nil)
    }

    private func runLoop() async {
        var attempt = 0
        var failuresWithoutData = 0
        while !Task.isCancelled {
            setHealth(attempt == 0 ? .starting : .restarting(attempt: attempt))
            var received = false
            for await payload in adapter.stream() {
                if !received {
                    received = true
                    failuresWithoutData = 0
                    attempt = 0
                    setHealth(.running)
                }
                apply(payload)
            }
            guard !Task.isCancelled else { return }
            attempt += 1
            if !received { failuresWithoutData += 1 }
            // A dead reader must not leave a stale song on screen.
            if !received || attempt > 1 { apply(nil) }
            let delay: Double
            if failuresWithoutData >= 5 {
                setHealth(.unavailable)
                delay = 60
            } else {
                delay = min(30, 0.5 * pow(2, Double(attempt - 1)))
            }
            Self.log.notice("Adapter stream ended; restarting in \(String(format: "%.1f", delay)) s")
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Maps the last payload again (after new browsers were found).
    public func refreshMapping() {
        guard let payload = state.withLock({ $0.lastPayload }) else { return }
        apply(payload)
    }

    private func apply(_ payload: AdapterPayload?) {
        let now = clock()
        let resolver = self.resolver()
        let (changed, continuations) = state.withLock { state -> (NowPlayingSnapshot??, [AsyncStream<NowPlayingSnapshot?>.Continuation]) in
            state.lastPayload = payload
            var ratio: Double?
            if let data = payload?.artworkData {
                if let cached = state.artworkAspect, cached.data == data {
                    ratio = cached.ratio
                } else {
                    ratio = ArtworkImageDecoder.aspectRatio(of: data)
                    state.artworkAspect = (data, ratio)
                }
            }
            let snapshot = payload?.snapshot(resolver: resolver, artworkAspectRatio: ratio, now: now)
            let isDifferent: Bool
            switch (state.current, snapshot) {
            case (nil, nil): isDifferent = false
            case let (old?, new?): isDifferent = new.differsNoticeably(from: old, at: now)
            default: isDifferent = true
            }
            guard isDifferent else { return (nil, []) }
            state.current = snapshot
            return (.some(snapshot), Array(state.continuations.values))
        }
        guard let changed else { return }
        for continuation in continuations { continuation.yield(changed) }
    }

    private func setHealth(_ health: AdapterHealth) {
        let continuations = state.withLock { state -> [AsyncStream<AdapterHealth>.Continuation] in
            guard state.health != health else { return [] }
            state.health = health
            return Array(state.healthContinuations.values)
        }
        for continuation in continuations { continuation.yield(health) }
    }

    // MARK: NowPlayingProvider

    public func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<NowPlayingSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let current = state.withLock { state -> NowPlayingSnapshot? in
            state.continuations[key] = continuation
            return state.current
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    /// Health changes, starting with the current value.
    public func healthUpdates() -> AsyncStream<AdapterHealth> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<AdapterHealth>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let current = state.withLock { state -> AdapterHealth in
            state.healthContinuations[key] = continuation
            return state.health
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.healthContinuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> Bool {
        guard let request = MediaRemoteRequest(command),
              let current = state.withLock({ $0.current }),
              current.capabilities.supports(command)
        else { return false }
        return await adapter.run(request)
    }
}
