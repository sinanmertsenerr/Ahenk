import Foundation
import os

/// What a scripted read found.
public enum ScriptedReading: Sendable, Equatable {
    /// Nothing loaded (stopped).
    case stopped
    case track(NowPlayingSnapshot, hasArtwork: Bool)
    /// The answer did not have the expected shape.
    case unreadable
}

/// What a music app's own notification means for the current snapshot.
public enum NotificationOutcome: Sendable, Equatable {
    case stopped
    case snapshot(NowPlayingSnapshot)
    case ignore
}

/// The parts that differ between the Apple Music and Spotify providers:
/// scripts, parsing and the app's notification.
public protocol ScriptedPlayer: Sendable {
    associatedtype Notification: Sendable
    static var providerID: String { get }
    static var bundleIdentifier: String { get }
    static var source: MusicSource { get }
    /// What Ahenk can do through Automation.
    static var capabilities: PlaybackCapabilities { get }
    /// Reads the whole player state in one round trip.
    static var readScript: String { get }
    static func parse(_ value: ScriptValue, sampledAt: Date) -> ScriptedReading
    /// Returns the current cover as raw bytes; `nil` when covers come as URLs.
    static var artworkScript: String? { get }
    static func script(for command: PlaybackCommand) -> String?
    /// The snapshot after `notification`, based on `current`.
    static func outcome(of notification: Notification, current: NowPlayingSnapshot?, now: Date) -> NotificationOutcome
}

/// Access to one scripted app, for Settings › Sources and the menu.
public struct ScriptedSourceStatus: Sendable, Equatable {
    public var source: MusicSource
    public var bundleIdentifier: String
    public var isRunning: Bool
    public var permission: AutomationPermission

    public init(source: MusicSource, bundleIdentifier: String, isRunning: Bool, permission: AutomationPermission) {
        self.source = source
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
        self.permission = permission
    }

    /// Reading details and sending commands work.
    public var hasFullAccess: Bool { isRunning && permission == .granted }
}

/// A music app read through AppleScript and its distributed notifications.
///
/// - Never launches the app: no script runs unless `AppPresenceMonitoring`
///   says the app is running, checked again right before every run.
/// - Never prompts by itself: the Automation permission is checked without
///   a prompt; only `refreshPermission(askIfNeeded: true)` (a button the
///   user presses) may show macOS's question.
/// - Without the permission the app's notifications still name the song and
///   its play state, so the source keeps working with fewer details and no
///   commands (the hub then sends commands through the system's Now Playing
///   when this app owns it).
/// - Scripts run off the main thread (the runner's queue). Reads happen when
///   a notification arrives and every few seconds while playing; nothing
///   runs while the app is paused, stopped or closed.
public final class ScriptedPlayerProvider<Player: ScriptedPlayer>: NowPlayingProvider, Sendable {
    public var id: String { Player.providerID }

    private let runner: any ScriptRunning
    private let presence: any AppPresenceMonitoring
    private let clock: @Sendable () -> Date
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log: AhenkLogger

    /// Reads while playing happen at least this often.
    static var playingPollInterval: TimeInterval { 3 }
    static var idlePollInterval: TimeInterval { 30 }
    /// Without the permission, check again this often (it may have been
    /// granted in System Settings).
    static var permissionRecheckInterval: TimeInterval { 120 }

    private struct State: Sendable {
        var started = false
        var isRunning = false
        var permission: AutomationPermission = .unknown
        var current: NowPlayingSnapshot?
        var lastSample: Date?
        var artwork: (trackID: String, data: Data?)?
        var continuations: [UUID: AsyncStream<NowPlayingSnapshot?>.Continuation] = [:]
        var statusContinuations: [UUID: AsyncStream<ScriptedSourceStatus>.Continuation] = [:]
        var presenceTask: Task<Void, Never>?
        var pollTask: Task<Void, Never>?
        var pollGeneration = 0
        var pendingPoll: Task<Void, Never>?
        var recheckTask: Task<Void, Never>?
        var lastErrorLog: Date?
    }

    public init(
        runner: any ScriptRunning,
        presence: any AppPresenceMonitoring,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.presence = presence
        self.clock = clock
        self.log = AhenkLogger(category: Player.providerID)
    }

    deinit {
        state.withLock { state in
            state.presenceTask?.cancel()
            state.pollTask?.cancel()
            state.pendingPoll?.cancel()
            state.recheckTask?.cancel()
        }
    }

    // MARK: Lifecycle

    public func start() {
        let first = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            let changes = presence.changes()
            state.presenceTask = Task.detached(priority: .utility) { [weak self] in
                for await change in changes where change.bundleIdentifier == Player.bundleIdentifier {
                    self?.presenceChanged(isRunning: change.isRunning)
                }
            }
            return true
        }
        guard first else { return }
        presenceChanged(isRunning: presence.isRunning(Player.bundleIdentifier))
    }

    public func stop() {
        state.withLock { state in
            state.started = false
            state.presenceTask?.cancel()
            state.presenceTask = nil
        }
        stopPolling()
        apply(nil, sampledAt: clock(), force: true)
    }

    public var status: ScriptedSourceStatus {
        state.withLock { Self.status(of: $0) }
    }

    private static func status(of state: State) -> ScriptedSourceStatus {
        ScriptedSourceStatus(
            source: Player.source,
            bundleIdentifier: Player.bundleIdentifier,
            isRunning: state.isRunning,
            permission: state.permission
        )
    }

    /// Status changes, starting with the current one.
    public func statusUpdates() -> AsyncStream<ScriptedSourceStatus> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<ScriptedSourceStatus>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let current = state.withLock { state -> ScriptedSourceStatus in
            state.statusContinuations[key] = continuation
            return Self.status(of: state)
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.statusContinuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    private func presenceChanged(isRunning: Bool) {
        let wasRunning = state.withLock { state -> Bool in
            defer { state.isRunning = isRunning }
            return state.isRunning
        }
        broadcastStatus()
        if isRunning {
            if !wasRunning { log.info("\(Player.bundleIdentifier) is running") }
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.refreshPermission(askIfNeeded: false)
            }
        } else {
            if wasRunning { log.info("\(Player.bundleIdentifier) quit") }
            stopPolling()
            apply(nil, sampledAt: clock(), force: true)
        }
    }

    /// Asks macOS whether Ahenk may automate the app. With `askIfNeeded`
    /// macOS shows its prompt when it has not asked before (only on the
    /// user's request). Starts or stops reading accordingly.
    @discardableResult
    public func refreshPermission(askIfNeeded: Bool) async -> AutomationPermission {
        guard presence.isRunning(Player.bundleIdentifier) else {
            return state.withLock { $0.permission }
        }
        let permission = await runner.automationPermission(for: Player.bundleIdentifier, askIfNeeded: askIfNeeded)
        let changed = state.withLock { state -> Bool in
            // The app quitting mid-check says nothing about the permission.
            guard permission != .appNotRunning, state.permission != permission else { return false }
            state.permission = permission
            return true
        }
        if changed {
            log.notice("Automation for \(Player.bundleIdentifier): \(permission.rawValue)")
            broadcastStatus()
        }
        if state.withLock({ $0.permission }) == .granted {
            startPolling()
        } else {
            stopPolling(keepRecheck: true)
        }
        return permission
    }

    // MARK: Notifications

    /// The app's own notification (`com.apple.Music.playerInfo`,
    /// `com.spotify.client.PlaybackStateChanged`), delivered by the app.
    public func ingest(_ notification: Player.Notification) {
        let now = clock()
        let (current, scripted) = state.withLock { ($0.current, $0.permission == .granted && $0.isRunning) }
        switch Player.outcome(of: notification, current: current, now: now) {
        case .stopped:
            apply(nil, sampledAt: now, force: true)
        case .snapshot(var snapshot):
            snapshot.bundleIdentifier = Player.bundleIdentifier
            snapshot.processIdentifier = presence.processIdentifier(of: Player.bundleIdentifier)
            snapshot.capabilities = scripted ? Player.capabilities : []
            if let current, current.isSameTrack(as: snapshot) {
                snapshot.artworkData = snapshot.artworkData ?? current.artworkData
                snapshot.artworkIdentifier = snapshot.artworkIdentifier ?? current.artworkIdentifier
                if snapshot.track.artworkURL == nil { snapshot.track.artworkURL = current.track.artworkURL }
                snapshot.isShuffled = snapshot.isShuffled ?? current.isShuffled
                snapshot.repeatMode = snapshot.repeatMode ?? current.repeatMode
                snapshot.isLiked = snapshot.isLiked ?? current.isLiked
            }
            apply(snapshot, sampledAt: now, force: false)
        case .ignore:
            break
        }
        if scripted { requestPoll(after: 0.15) }
    }

    // MARK: Reading

    private func canScript() -> Bool {
        state.withLock { $0.isRunning && $0.permission == .granted && $0.started }
            && presence.isRunning(Player.bundleIdentifier)
    }

    private func startPolling() {
        let recheck = state.withLock { state -> Task<Void, Never>? in
            defer { state.recheckTask = nil }
            guard state.pollTask == nil else { return state.recheckTask }
            state.pollGeneration += 1
            let generation = state.pollGeneration
            state.pollTask = Task.detached(priority: .utility) { [weak self] in
                await self?.pollLoop(generation: generation)
            }
            return state.recheckTask
        }
        recheck?.cancel()
    }

    private func stopPolling(keepRecheck: Bool = false) {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            defer {
                state.pollTask = nil
                state.pendingPoll = nil
                state.pollGeneration += 1
                if !keepRecheck { state.recheckTask = nil }
            }
            return [state.pollTask, state.pendingPoll, keepRecheck ? nil : state.recheckTask].compactMap { $0 }
        }
        for task in tasks { task.cancel() }
        if keepRecheck { scheduleRecheck() }
    }

    /// While the app runs without the permission, look again now and then
    /// (it may have been granted in System Settings).
    private func scheduleRecheck() {
        state.withLock { state in
            guard state.isRunning, state.permission != .granted, state.started, state.recheckTask == nil else { return }
            state.recheckTask = Task.detached(priority: .background) { [weak self] in
                try? await Task.sleep(for: .seconds(Self.permissionRecheckInterval))
                guard let self, !Task.isCancelled else { return }
                self.state.withLock { $0.recheckTask = nil }
                _ = await self.refreshPermission(askIfNeeded: false)
            }
        }
    }

    private func pollLoop(generation: Int) async {
        while !Task.isCancelled, canScript() {
            await pollOnce()
            let delay = nextPollDelay()
            try? await Task.sleep(for: .seconds(delay))
        }
        state.withLock { state in
            if state.pollGeneration == generation { state.pollTask = nil }
        }
    }

    private func nextPollDelay() -> TimeInterval {
        let now = clock()
        guard let current = state.withLock({ $0.current }), current.isPlaying else { return Self.idlePollInterval }
        if current.track.duration > 0 {
            // Catch the switch to the next song right when it happens.
            let remaining = current.track.duration - current.elapsed(at: now)
            if remaining > 0, remaining < Self.playingPollInterval { return max(0.25, remaining + 0.3) }
        }
        return Self.playingPollInterval
    }

    private func requestPoll(after delay: TimeInterval) {
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.pollOnce()
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            defer { state.pendingPoll = task }
            return state.pendingPoll
        }
        previous?.cancel()
    }

    /// One read. Public for tests and for "refresh now".
    public func pollOnce() async {
        guard canScript() else { return }
        let startedAt = clock()
        let result = await runner.run(Player.readScript)
        let finishedAt = clock()
        // AppleScript gives no sample time; the round trip's midpoint bounds
        // the error to half of it.
        let sampledAt = startedAt.addingTimeInterval(max(0, finishedAt.timeIntervalSince(startedAt)) / 2)
        switch result {
        case .success(let value):
            switch Player.parse(value, sampledAt: sampledAt) {
            case .stopped:
                apply(nil, sampledAt: sampledAt, force: false)
            case .unreadable:
                logError("unexpected answer from the read script")
            case .track(var snapshot, let hasArtwork):
                snapshot.bundleIdentifier = Player.bundleIdentifier
                snapshot.processIdentifier = presence.processIdentifier(of: Player.bundleIdentifier)
                snapshot.capabilities = Player.capabilities
                await attachArtwork(to: &snapshot, available: hasArtwork)
                // A quick answer places the song precisely (the error is at
                // most half the round trip).
                let roundTrip = max(0, finishedAt.timeIntervalSince(startedAt))
                let tolerance = min(0.4, max(Self.preciseTolerance, roundTrip * 0.75))
                if let old = state.withLock({ $0.current }), old.isPlaying, snapshot.isPlaying, old.track.id == snapshot.track.id {
                    let drift = old.elapsed(at: finishedAt) - snapshot.elapsed(at: finishedAt)
                    if abs(drift) > 0.05 {
                        log.info("Position check: shown \(String(format: "%+.2f", drift)) s from the player (read took \(Int(roundTrip * 1000)) ms)\(abs(drift) > tolerance ? "; corrected" : "")")
                    }
                }
                apply(snapshot, sampledAt: sampledAt, force: false, tolerance: tolerance)
            }
        case .failure(let error):
            handle(error)
        }
    }

    /// Fetches the cover once per song (artwork can be megabytes).
    private func attachArtwork(to snapshot: inout NowPlayingSnapshot, available: Bool) async {
        guard let script = Player.artworkScript else { return }
        let trackID = snapshot.track.id
        if let cached = state.withLock({ $0.artwork }), cached.trackID == trackID {
            snapshot.artworkData = cached.data
            snapshot.artworkIdentifier = cached.data.map { _ in "\(Player.providerID):\(trackID)" }
            return
        }
        var fetched: Data?
        if available, canScript(), case .success(let value) = await runner.run(script) {
            fetched = value.data
        }
        let data = fetched
        state.withLock { $0.artwork = (trackID, data) }
        snapshot.artworkData = data
        snapshot.artworkIdentifier = data.map { _ in "\(Player.providerID):\(trackID)" }
    }

    private func handle(_ error: ScriptError) {
        if error.isAutomationDenied {
            log.notice("Automation for \(Player.bundleIdentifier) is not allowed (\(error.code))")
            let changed = state.withLock { state -> Bool in
                defer { state.permission = .denied }
                return state.permission != .denied
            }
            if changed { broadcastStatus() }
            stopPolling(keepRecheck: true)
            // Keep showing what the notifications report, without commands.
            if var current = state.withLock({ $0.current }) {
                current.capabilities = []
                apply(current, sampledAt: clock(), force: true)
            }
        } else if error.isAppGone {
            presenceChanged(isRunning: presence.isRunning(Player.bundleIdentifier))
        } else {
            logError(error.description)
        }
    }

    private func logError(_ message: String) {
        let now = clock()
        let shouldLog = state.withLock { state -> Bool in
            if let last = state.lastErrorLog, now.timeIntervalSince(last) < 60 { return false }
            state.lastErrorLog = now
            return true
        }
        if shouldLog { log.error("Script failed: \(message)") }
    }

    // MARK: Publishing

    /// A quick read replaces a position that is off by more than this (a
    /// slower read is trusted less: three quarters of its round trip, up to
    /// 0.4 s). Without it a position read slowly (while Ahenk starts, or
    /// the Mac is busy) stayed up to 0.4 s off until the next seek, and the
    /// lyrics ran that much early or late.
    static var preciseTolerance: TimeInterval { 0.1 }

    private func apply(_ snapshot: NowPlayingSnapshot?, sampledAt: Date, force: Bool, tolerance: TimeInterval = 0.4) {
        let now = clock()
        let (value, continuations) = state.withLock { state -> (NowPlayingSnapshot??, [AsyncStream<NowPlayingSnapshot?>.Continuation]) in
            // A read that started before the last applied update is stale.
            if !force, let last = state.lastSample, sampledAt < last { return (nil, []) }
            state.lastSample = sampledAt
            let different: Bool
            switch (state.current, snapshot) {
            case (nil, nil): different = false
            case let (old?, new?):
                different = new.differsNoticeably(from: old, at: now, tolerance: tolerance)
            default: different = true
            }
            guard different else { return (nil, []) }
            state.current = snapshot
            if snapshot == nil { state.artwork = nil }
            return (.some(snapshot), Array(state.continuations.values))
        }
        guard let value else { return }
        for continuation in continuations { continuation.yield(value) }
    }

    private func broadcastStatus() {
        let (status, continuations) = state.withLock { state in
            (Self.status(of: state), Array(state.statusContinuations.values))
        }
        for continuation in continuations { continuation.yield(status) }
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

    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> Bool {
        guard Player.capabilities.supports(command), let script = Player.script(for: command), canScript() else { return false }
        switch await runner.run(script) {
        case .success:
            requestPoll(after: 0.12)
            return true
        case .failure(let error):
            handle(error)
            return false
        }
    }
}
