import Foundation
import os

/// One input of the hub: a provider's reports and a way to send it commands.
public struct HubInput: Sendable {
    /// The music apps' own providers and the browser bridge.
    public static let dedicatedPriority = 20
    /// The system's Now Playing (the MediaRemote adapter).
    public static let systemPriority = 10

    public let id: String
    public let priority: Int
    /// Its reports for an app hide lower-priority reports for the same app
    /// that describe the same song (the browser bridge over the system's
    /// guess for that browser; see `HubCore`).
    public let shadowsSameApp: Bool
    /// Everything the provider sees, as a list (several browser tabs).
    public let reports: @Sendable () -> AsyncStream<[NowPlayingSnapshot]>
    public let perform: @Sendable (PlaybackCommand, PlayerID) async -> Bool

    public init(
        id: String,
        priority: Int,
        shadowsSameApp: Bool = false,
        reports: @escaping @Sendable () -> AsyncStream<[NowPlayingSnapshot]>,
        perform: @escaping @Sendable (PlaybackCommand, PlayerID) async -> Bool
    ) {
        self.id = id
        self.priority = priority
        self.shadowsSameApp = shadowsSameApp
        self.reports = reports
        self.perform = perform
    }

    /// A provider that plays one thing at a time.
    public static func provider(_ provider: any NowPlayingProvider, id: String? = nil, priority: Int) -> HubInput {
        HubInput(
            id: id ?? provider.id,
            priority: priority,
            reports: {
                let upstream = provider.snapshots()
                let (stream, continuation) = AsyncStream<[NowPlayingSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(8))
                let task = Task {
                    for await snapshot in upstream {
                        continuation.yield(snapshot.map { [$0] } ?? [])
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
                return stream
            },
            perform: { command, _ in await provider.perform(command) }
        )
    }
}

/// Merges every provider into the one song Ahenk follows.
///
/// Subscribes to each input, feeds `HubCore`, and publishes the followed
/// player's snapshot (``snapshots()``, so the hub is itself a
/// `NowPlayingProvider`), the whole state (``states()``) and events
/// (``events()``). Commands go to the provider that can carry them out for
/// the player they target. With "start every song at 0:15" on, it seeks
/// new songs that qualify (`IntroSkipPolicy`).
public final class NowPlayingHub: NowPlayingProvider, Sendable {
    public let id = "hub"
    /// Songs found during the first moments after `start()` are the state
    /// Ahenk launched into, not new songs.
    public static let startupGrace: TimeInterval = 2

    private let inputs: [HubInput]
    private let clock: @Sendable () -> Date
    private let usesTimer: Bool
    private let state: OSAllocatedUnfairLock<DriverState>
    private static let log = AhenkLogger(category: "hub")

    private struct DriverState: Sendable {
        var core: HubCore
        var started = false
        var startedAt: Date?
        var tasks: [Task<Void, Never>] = []
        var timer: Task<Void, Never>?
        var timerDeadline: Date?
        var published = HubState()
        var publishedSnapshot: NowPlayingSnapshot?
        var snapshotContinuations: [UUID: AsyncStream<NowPlayingSnapshot?>.Continuation] = [:]
        var stateContinuations: [UUID: AsyncStream<HubState>.Continuation] = [:]
        var eventContinuations: [UUID: AsyncStream<HubEvent>.Continuation] = [:]
        var lastIntroSkip: Track?
    }

    /// What one update has to send once the lock is released.
    private struct Delivery {
        var snapshot: (value: NowPlayingSnapshot?, to: [AsyncStream<NowPlayingSnapshot?>.Continuation])?
        var state: (value: HubState, to: [AsyncStream<HubState>.Continuation])?
        var events: (values: [HubEvent], to: [AsyncStream<HubEvent>.Continuation])?
        var introSkip: PlayerID?

        func send() {
            if let snapshot { snapshot.to.forEach { $0.yield(snapshot.value) } }
            if let state { state.to.forEach { $0.yield(state.value) } }
            if let events {
                for continuation in events.to {
                    events.values.forEach { continuation.yield($0) }
                }
            }
        }
    }

    /// `usesTimer: false` leaves time-based rules to explicit `tick()` calls
    /// (tests with a manual clock).
    public init(
        inputs: [HubInput],
        configuration: HubConfiguration = HubConfiguration(),
        usesTimer: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inputs = inputs
        self.clock = clock
        self.usesTimer = usesTimer
        var core = HubCore(configuration: configuration)
        for input in inputs {
            core.setPriority(input.priority, for: input.id)
            if input.shadowsSameApp { core.setShadowing(true, for: input.id) }
        }
        state = OSAllocatedUnfairLock(initialState: DriverState(core: core))
    }

    deinit {
        state.withLock { state in
            state.tasks.forEach { $0.cancel() }
            state.timer?.cancel()
        }
    }

    // MARK: Lifecycle

    public func start() {
        let now = clock()
        state.withLock { state in
            guard !state.started else { return }
            state.started = true
            state.startedAt = now
            for input in inputs {
                let reports = input.reports()
                let inputID = input.id
                state.tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
                    for await snapshots in reports {
                        guard let self else { return }
                        let at = self.clock()
                        self.update { $0.ingest(snapshots, from: inputID, now: at) }
                    }
                })
            }
        }
    }

    public func stop() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            defer {
                state.tasks = []
                state.timer = nil
                state.timerDeadline = nil
                state.started = false
            }
            return state.tasks + [state.timer].compactMap { $0 }
        }
        tasks.forEach { $0.cancel() }
        let now = clock()
        update { core in
            for input in inputs { core.removeProvider(input.id, now: now) }
        }
    }

    public func setConfiguration(_ configuration: HubConfiguration) {
        let now = clock()
        update { $0.setConfiguration(configuration, now: now) }
    }

    public var configuration: HubConfiguration { state.withLock { $0.core.configuration } }
    public var currentState: HubState { state.withLock { $0.core.state } }

    /// Re-evaluates the time-based rules now.
    public func tick() {
        let now = clock()
        update { $0.tick(now: now) }
    }

    // MARK: Streams

    /// The followed player's snapshot: the current one at once, then every
    /// noticeable change.
    public func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<NowPlayingSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let current = state.withLock { state -> NowPlayingSnapshot? in
            state.snapshotContinuations[key] = continuation
            return state.core.state.activeSnapshot
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.snapshotContinuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    /// The hub's state: now, then whenever its outline changes (who plays,
    /// whom Ahenk follows, a conflict); not on position updates.
    public func states() -> AsyncStream<HubState> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<HubState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let current = state.withLock { state -> HubState in
            state.stateContinuations[key] = continuation
            return state.core.state
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.stateContinuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    public func events() -> AsyncStream<HubEvent> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<HubEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        state.withLock { $0.eventContinuations[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.eventContinuations.removeValue(forKey: key) }
        }
        return stream
    }

    // MARK: Commands

    /// Runs `command` on the followed player.
    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> Bool {
        guard let active = state.withLock({ $0.core.state.activeID }) else { return false }
        return await perform(command, on: active)
    }

    /// Runs `command` on `player` through the provider that can do it,
    /// showing the expected result at once.
    @discardableResult
    public func perform(_ command: PlaybackCommand, on player: PlayerID) async -> Bool {
        let now = clock()
        let (providerID, expectation) = state.withLock { state -> (String?, PlaybackExpectation?) in
            let provider = state.core.provider(for: command, on: player)
            let expectation = state.core.state.player(player).flatMap {
                PlaybackExpectation.after(command, on: $0.snapshot, at: now)
            }
            return (provider, expectation)
        }
        guard let providerID, let input = inputs.first(where: { $0.id == providerID }) else {
            Self.log.info("No provider can run \(String(describing: command)) on \(player)")
            return false
        }
        if let expectation {
            update { $0.expect(expectation, for: player, now: now) }
        }
        let succeeded = await input.perform(command, player)
        if !succeeded {
            Self.log.notice("\(providerID) could not run \(String(describing: command)) on \(player)")
            if expectation != nil {
                let later = clock()
                update { $0.dropExpectation(for: player, now: later) }
            }
        }
        return succeeded
    }

    /// The user picked `player` when several were playing. With "pause the
    /// previous source when switching" on, the others are paused.
    public func choose(_ player: PlayerID) async {
        let now = clock()
        update { $0.choose(player, now: now) }
        Self.log.notice("Following \(player) (chosen)")
        if configuration.pauseOthersOnSwitch {
            await pausePlayers(except: player)
        }
    }

    /// Pauses every playing player but `player` (switching sources).
    public func pausePlayers(except player: PlayerID) async {
        let others = state.withLock { state in
            state.core.state.players.filter { $0.isPlaying && $0.id != player }.map(\.id)
        }
        for other in others {
            await perform(.pause, on: other)
        }
    }

    // MARK: Publishing

    private func update(_ mutate: @Sendable (inout HubCore) -> Void) {
        let now = clock()
        let delivery = state.withLock { state -> Delivery in
            mutate(&state.core)
            return publish(&state, now: now)
        }
        delivery.send()
        if let player = delivery.introSkip {
            Self.log.notice("Starting the new song at 0:15 on \(player)")
            Task { await self.perform(.seek(to: IntroSkipPolicy.target), on: player) }
        }
        rescheduleTimer()
    }

    private func publish(_ state: inout DriverState, now: Date) -> Delivery {
        var delivery = Delivery()
        let new = state.core.state
        let old = state.published
        let oldSnapshot = state.publishedSnapshot
        let newSnapshot = new.activeSnapshot

        var events: [HubEvent] = []
        if old.activeID != new.activeID {
            events.append(.activePlayerChanged(previous: old.activeID, current: new.activeID))
        }
        if let newSnapshot, let player = new.activeID {
            if oldSnapshot.map({ !$0.isSameTrack(as: newSnapshot) }) ?? true {
                events.append(.trackChanged(player: player, previous: oldSnapshot, current: newSnapshot))
                if state.core.configuration.startAtFifteenSeconds,
                   let started = state.startedAt, now.timeIntervalSince(started) >= Self.startupGrace,
                   IntroSkipPolicy.shouldSkip(to: newSnapshot, previous: oldSnapshot, lastSkipped: state.lastIntroSkip, now: now) {
                    state.lastIntroSkip = newSnapshot.track
                    delivery.introSkip = player
                }
            } else if let oldSnapshot, oldSnapshot.isPlaying != newSnapshot.isPlaying, old.activeID == new.activeID {
                events.append(.playbackChanged(player: player, isPlaying: newSnapshot.isPlaying))
            }
        }
        if old.conflict != new.conflict {
            events.append(.conflictChanged(new.conflict))
            if let conflict = new.conflict {
                Self.log.notice("Several sources are playing: \(conflict.players.map(\.description).joined(separator: ", "))")
            }
        }
        if !events.isEmpty, !state.eventContinuations.isEmpty {
            delivery.events = (events, Array(state.eventContinuations.values))
        }

        let snapshotChanged: Bool
        switch (oldSnapshot, newSnapshot) {
        case (nil, nil): snapshotChanged = false
        // The providers already drop reads that change nothing; a position
        // they do correct (by a tenth of a second or more) must reach the
        // lyrics.
        case let (a?, b?): snapshotChanged = b.differsNoticeably(from: a, at: now, tolerance: 0.1) || old.activeID != new.activeID
        default: snapshotChanged = true
        }
        if snapshotChanged {
            state.publishedSnapshot = newSnapshot
            delivery.snapshot = (newSnapshot, Array(state.snapshotContinuations.values))
        }
        if !new.hasSameOutline(as: old) || snapshotChanged {
            delivery.state = (new, Array(state.stateContinuations.values))
        }
        state.published = new
        return delivery
    }

    private func rescheduleTimer() {
        guard usesTimer else { return }
        let now = clock()
        let cancelled = state.withLock { state -> Task<Void, Never>? in
            let deadline = state.core.nextDeadline
            guard deadline != state.timerDeadline else { return nil }
            let previous = state.timer
            state.timer = nil
            state.timerDeadline = deadline
            guard let deadline else { return previous }
            let delay = max(0, deadline.timeIntervalSince(now)) + 0.02
            state.timer = Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.state.withLock { state in
                    state.timer = nil
                    state.timerDeadline = nil
                }
                self.tick()
            }
            return previous
        }
        cancelled?.cancel()
    }
}
