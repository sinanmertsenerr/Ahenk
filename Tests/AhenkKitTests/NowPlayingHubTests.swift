import Foundation
import os
import Testing
@testable import AhenkKit

/// A provider the test drives by hand; records the commands it receives.
final class ControlledProvider: NowPlayingProvider, Sendable {
    let id: String
    private struct State {
        var current: NowPlayingSnapshot?
        var continuations: [UUID: AsyncStream<NowPlayingSnapshot?>.Continuation] = [:]
        var commands: [PlaybackCommand] = []
        var succeeds = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(id: String) {
        self.id = id
    }

    var commands: [PlaybackCommand] { state.withLock { $0.commands } }

    func setSucceeds(_ value: Bool) {
        state.withLock { $0.succeeds = value }
    }

    func send(_ snapshot: NowPlayingSnapshot?) {
        let continuations = state.withLock { state -> [AsyncStream<NowPlayingSnapshot?>.Continuation] in
            state.current = snapshot
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(snapshot) }
    }

    func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<NowPlayingSnapshot?>.makeStream()
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

    func perform(_ command: PlaybackCommand) async -> Bool {
        state.withLock { state in
            state.commands.append(command)
            return state.succeeds
        }
    }
}

private func song(_ source: MusicSource, _ title: String, bundle: String, playing: Bool = true, elapsed: TimeInterval = 0, at time: Date) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        track: Track(id: "\(source.rawValue):\(title)", source: source, title: title, artist: "Invented Artist", album: "Invented Album", duration: 180),
        bundleIdentifier: bundle,
        elapsedTime: elapsed,
        playbackRate: playing ? 1 : 0,
        timestamp: time,
        capabilities: .all,
        contentKind: .music
    )
}

@Suite("Now playing hub", .serialized)
@MainActor
struct NowPlayingHubTests {
    @Test("Publishes the followed song and its events")
    func publishing() async throws {
        let clock = ManualClock()
        let spotify = ControlledProvider(id: "spotify")
        let web = ControlledProvider(id: "mediaremote")
        let hub = NowPlayingHub(
            inputs: [.provider(spotify, priority: HubInput.dedicatedPriority), .provider(web, priority: HubInput.systemPriority)],
            usesTimer: false, clock: clock.function
        )
        let events = hub.events()
        let snapshots = hub.snapshots()
        hub.start()
        spotify.send(song(.spotify, "First", bundle: KnownApps.spotify, at: clock.now))
        #expect(await eventually { hub.currentState.activeSnapshot?.track.title == "First" })
        clock.advance(5)
        spotify.send(song(.spotify, "Second", bundle: KnownApps.spotify, at: clock.now))
        #expect(await eventually { hub.currentState.activeSnapshot?.track.title == "Second" })
        clock.advance(5)
        spotify.send(song(.spotify, "Second", bundle: KnownApps.spotify, playing: false, elapsed: 5, at: clock.now))
        #expect(await eventually { hub.currentState.activeSnapshot?.isPlaying == false })

        let published = await collect(snapshots, count: 4)
        #expect(published.compactMap { $0?.track.title } == ["First", "Second", "Second"])
        let seen = await collect(events, count: 4)
        let changes = seen.compactMap { event -> String? in
            if case .trackChanged(_, _, let current) = event { return current.track.title }
            return nil
        }
        #expect(changes == ["First", "Second"])
        #expect(seen.contains(.playbackChanged(player: PlayerID(source: .spotify, bundleIdentifier: KnownApps.spotify), isPlaying: false)))
        #expect(seen.contains { if case .activePlayerChanged(nil, _) = $0 { true } else { false } })
        hub.stop()
    }

    @Test("Steady playback re-sampled by a poll is not republished")
    func noChurn() async {
        let clock = ManualClock()
        let spotify = ControlledProvider(id: "spotify")
        let hub = NowPlayingHub(inputs: [.provider(spotify, priority: 20)], usesTimer: false, clock: clock.function)
        let snapshots = hub.snapshots()
        hub.start()
        spotify.send(song(.spotify, "Steady", bundle: KnownApps.spotify, at: clock.now))
        for step in 1...5 {
            clock.advance(3)
            spotify.send(song(.spotify, "Steady", bundle: KnownApps.spotify, elapsed: Double(step) * 3, at: clock.now))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let published = await collect(snapshots, count: 10, timeout: .milliseconds(300))
        #expect(published.count == 2, "nil at first, then the song once")
        hub.stop()
    }

    @Test("Commands reach the provider of the targeted player and show at once")
    func commands() async throws {
        let clock = ManualClock()
        let spotify = ControlledProvider(id: "spotify")
        let web = ControlledProvider(id: "mediaremote")
        let hub = NowPlayingHub(
            inputs: [.provider(spotify, priority: 20), .provider(web, priority: 10)],
            usesTimer: false, clock: clock.function
        )
        hub.start()
        spotify.send(song(.spotify, "Song", bundle: KnownApps.spotify, elapsed: 20, at: clock.now))
        clock.advance(1)
        web.send(song(.otherApp, "Video", bundle: KnownApps.search, at: clock.now))
        #expect(await eventually { hub.currentState.players.count == 2 })
        #expect(await hub.perform(.pause))
        #expect(web.commands == [.pause], "the followed player is the newest")
        let spotifyID = PlayerID(source: .spotify, bundleIdentifier: KnownApps.spotify)
        #expect(await hub.perform(.seek(to: 90), on: spotifyID))
        #expect(spotify.commands == [.seek(to: 90)])
        #expect(hub.currentState.player(spotifyID)?.snapshot.elapsed(at: clock.now) == 90, "the expected position shows before the player confirms")
        spotify.setSucceeds(false)
        #expect(!(await hub.perform(.seek(to: 10), on: spotifyID)))
        #expect(hub.currentState.player(spotifyID)?.snapshot.elapsed(at: clock.now) == 21, "a failed command drops its expectation")
        #expect(!(await hub.perform(.play, on: PlayerID(source: .tidal))), "nobody reports that player")
        hub.stop()
    }

    @Test("Choosing a player pauses the others when that is on")
    func choosePausesOthers() async {
        let clock = ManualClock()
        let spotify = ControlledProvider(id: "spotify")
        let web = ControlledProvider(id: "mediaremote")
        let hub = NowPlayingHub(
            inputs: [.provider(spotify, priority: 20), .provider(web, priority: 10)],
            configuration: HubConfiguration(pauseOthersOnSwitch: true, conflictDelay: 3),
            usesTimer: false, clock: clock.function
        )
        hub.start()
        spotify.send(song(.spotify, "Song", bundle: KnownApps.spotify, at: clock.now))
        clock.advance(1)
        web.send(song(.otherApp, "Video", bundle: KnownApps.search, at: clock.now))
        #expect(await eventually { hub.currentState.players.count == 2 })
        clock.advance(4)
        hub.tick()
        #expect(hub.currentState.conflict?.players.count == 2)
        let spotifyID = PlayerID(source: .spotify, bundleIdentifier: KnownApps.spotify)
        await hub.choose(spotifyID)
        #expect(hub.currentState.activeID == spotifyID)
        #expect(hub.currentState.conflict == nil)
        #expect(web.commands == [.pause])
        #expect(spotify.commands.isEmpty)
        hub.stop()
    }

    @Test("Start every song at 0:15 seeks new songs, not the one found at launch")
    func introSkip() async throws {
        let clock = ManualClock()
        let demo = DemoProvider(clock: clock.function)
        let hub = NowPlayingHub(
            inputs: [.provider(demo, priority: 20)],
            configuration: HubConfiguration(startAtFifteenSeconds: true),
            usesTimer: false, clock: clock.function
        )
        hub.start()
        #expect(await eventually { hub.currentState.activeSnapshot != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(demo.snapshot().elapsedTime < 1, "the song playing at launch is left alone")
        clock.advance(3)
        await demo.perform(.next)
        #expect(await eventually { demo.snapshot().elapsedTime >= 15 }, "the next song jumps over its intro")
        #expect(demo.snapshot().track == DemoCatalog.songs[1].track)
        // Seeking back by hand is respected: no second jump for the same song.
        await demo.perform(.seek(to: 2))
        try await Task.sleep(for: .milliseconds(150))
        #expect(demo.snapshot().elapsedTime < 3)
        hub.stop()
    }

    @Test("Without the setting nothing is seeked")
    func introSkipOff() async throws {
        let clock = ManualClock()
        let demo = DemoProvider(clock: clock.function)
        let hub = NowPlayingHub(inputs: [.provider(demo, priority: 20)], usesTimer: false, clock: clock.function)
        hub.start()
        clock.advance(3)
        await demo.perform(.next)
        #expect(await eventually { hub.currentState.activeSnapshot?.track == DemoCatalog.songs[1].track })
        try await Task.sleep(for: .milliseconds(150))
        #expect(demo.snapshot().elapsedTime < 1)
        hub.stop()
    }

    @Test("Intro skip rules")
    func introSkipPolicy() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let fresh = song(.spotify, "New", bundle: KnownApps.spotify, elapsed: 0.5, at: now)
        let older = song(.spotify, "Old", bundle: KnownApps.spotify, at: now)
        #expect(IntroSkipPolicy.shouldSkip(to: fresh, previous: older, lastSkipped: nil, now: now))
        #expect(IntroSkipPolicy.shouldSkip(to: fresh, previous: nil, lastSkipped: nil, now: now), "pressing play on a new song")
        #expect(!IntroSkipPolicy.shouldSkip(to: fresh, previous: fresh, lastSkipped: nil, now: now), "the same song again")
        #expect(!IntroSkipPolicy.shouldSkip(to: fresh, previous: older, lastSkipped: fresh.track, now: now))
        #expect(!IntroSkipPolicy.shouldSkip(to: fresh, previous: older, lastSkipped: nil, now: now.addingTimeInterval(10)), "already past the start")
        var short = fresh
        short.track.duration = 45
        #expect(!IntroSkipPolicy.shouldSkip(to: short, previous: older, lastSkipped: nil, now: now))
        var video = fresh
        video.contentKind = .video
        #expect(!IntroSkipPolicy.shouldSkip(to: video, previous: older, lastSkipped: nil, now: now))
        var noSeek = fresh
        noSeek.capabilities = [.playPause]
        #expect(!IntroSkipPolicy.shouldSkip(to: noSeek, previous: older, lastSkipped: nil, now: now))
        var paused = fresh
        paused.playbackRate = 0
        #expect(!IntroSkipPolicy.shouldSkip(to: paused, previous: older, lastSkipped: nil, now: now))
        var unknown = fresh
        unknown.isPositionKnown = false
        #expect(!IntroSkipPolicy.shouldSkip(to: unknown, previous: older, lastSkipped: nil, now: now))
    }

    @Test("Settings reach the hub")
    func configuration() async {
        let clock = ManualClock()
        let spotify = ControlledProvider(id: "spotify")
        let web = ControlledProvider(id: "mediaremote")
        let hub = NowPlayingHub(inputs: [.provider(spotify, priority: 20), .provider(web, priority: 10)], usesTimer: false, clock: clock.function)
        hub.start()
        spotify.send(song(.spotify, "Song", bundle: KnownApps.spotify, at: clock.now))
        clock.advance(1)
        web.send(song(.otherApp, "Video", bundle: KnownApps.search, at: clock.now))
        #expect(await eventually { hub.currentState.players.count == 2 && hub.currentState.activeID?.source == .otherApp })
        var settings = SourceSettings()
        settings.selection = .pinned(.spotify)
        hub.setConfiguration(HubConfiguration(sources: settings, player: PlayerSettings()))
        #expect(hub.currentState.activeID?.source == .spotify)
        settings.selection = .automatic
        settings.ignoredSources = [.otherApp]
        hub.setConfiguration(HubConfiguration(sources: settings, player: PlayerSettings()))
        #expect(hub.currentState.players.map(\.id.source) == [.spotify])
        hub.stop()
    }
}
