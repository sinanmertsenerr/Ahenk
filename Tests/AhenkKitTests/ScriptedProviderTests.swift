import Foundation
import os
import Testing
@testable import AhenkKit

/// Records every script and permission request; answers from a closure.
final class FakeScriptRunner: ScriptRunning, Sendable {
    private struct State {
        var scripts: [String] = []
        var asks: [Bool] = []
        var permission: AutomationPermission
        var grantsWhenAsked: Bool
    }

    private let state: OSAllocatedUnfairLock<State>
    private let respond: @Sendable (String) -> Result<ScriptValue, ScriptError>

    init(permission: AutomationPermission, grantsWhenAsked: Bool = true, respond: @escaping @Sendable (String) -> Result<ScriptValue, ScriptError>) {
        state = OSAllocatedUnfairLock(initialState: State(permission: permission, grantsWhenAsked: grantsWhenAsked))
        self.respond = respond
    }

    var scripts: [String] { state.withLock { $0.scripts } }
    var asks: [Bool] { state.withLock { $0.asks } }

    func setPermission(_ permission: AutomationPermission) {
        state.withLock { $0.permission = permission }
    }

    func run(_ source: String) async -> Result<ScriptValue, ScriptError> {
        state.withLock { $0.scripts.append(source) }
        return respond(source)
    }

    func automationPermission(for bundleIdentifier: String, askIfNeeded: Bool) async -> AutomationPermission {
        state.withLock { state in
            state.asks.append(askIfNeeded)
            if askIfNeeded, state.permission == .notDetermined {
                state.permission = state.grantsWhenAsked ? .granted : .denied
            }
            return state.permission
        }
    }
}

/// Which apps "run"; changes are announced like NSWorkspace does.
final class FakePresence: AppPresenceMonitoring, Sendable {
    private struct State {
        var running: Set<String>
        var continuations: [UUID: AsyncStream<AppPresenceChange>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(running: Set<String> = []) {
        state = OSAllocatedUnfairLock(initialState: State(running: running))
    }

    func setRunning(_ bundleIdentifier: String, _ running: Bool) {
        let continuations = state.withLock { state -> [AsyncStream<AppPresenceChange>.Continuation] in
            if running { state.running.insert(bundleIdentifier) } else { state.running.remove(bundleIdentifier) }
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(AppPresenceChange(bundleIdentifier: bundleIdentifier, isRunning: running)) }
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        state.withLock { $0.running.contains(bundleIdentifier) }
    }

    func processIdentifier(of bundleIdentifier: String) -> Int32? {
        isRunning(bundleIdentifier) ? 4000 : nil
    }

    func changes() -> AsyncStream<AppPresenceChange> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<AppPresenceChange>.makeStream()
        state.withLock { $0.continuations[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        return stream
    }
}

/// Keeps the latest value of a provider's stream.
final class LatestSnapshot: Sendable {
    private let state = OSAllocatedUnfairLock<NowPlayingSnapshot??>(initialState: .none)
    private let task: Task<Void, Never>

    init(_ provider: any NowPlayingProvider) {
        let stream = provider.snapshots()
        let box = state
        task = Task {
            for await snapshot in stream { box.withLock { $0 = .some(snapshot) } }
        }
    }

    deinit { task.cancel() }

    /// `nil` until the first value; then the latest snapshot (or `.some(nil)`).
    var value: NowPlayingSnapshot?? { state.withLock { $0 } }
    var snapshot: NowPlayingSnapshot? { value ?? nil }
}

// Invented reads: titles, artists and the artwork bytes are made up.
private let musicRead = ScriptValue.list([
    .text("playing"), .number(12.5), .text("Glass Harbor"), .text("Nova Atlas"), .text("Low Tide Lights"),
    .number(92), .text("6F2D1E3C4B5A6978"), .boolean(false), .text("all"), .boolean(true), .number(1),
])
private let artworkBytes = TestImages.png(TestImages.solid(SRGBColor("#0E5E6F"), width: 8, height: 8))

private func musicResponder(_ script: String) -> Result<ScriptValue, ScriptError> {
    if script.contains("raw data of artwork") { return .success(.data(artworkBytes)) }
    if script.contains("player state") { return .success(musicRead) }
    return .success(.missing)
}

@Suite("Scripted music app providers", .serialized)
@MainActor
struct ScriptedProviderTests {
    let music = KnownApps.appleMusic

    @Test("Never scripts or asks about an app that is not running")
    func neverLaunches() async {
        let runner = FakeScriptRunner(permission: .granted, respond: musicResponder)
        let presence = FakePresence()
        let provider = AppleMusicProvider(runner: runner, presence: presence)
        provider.start()
        provider.ingest(AppleMusicPlayerInfo(state: .playing, title: "Glass Harbor", artist: "Nova Atlas"))
        #expect(!(await provider.perform(.pause)))
        _ = await provider.refreshPermission(askIfNeeded: true)
        await provider.pollOnce()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runner.scripts.isEmpty, "a tell block would launch the app")
        #expect(runner.asks.isEmpty)
        provider.stop()
    }

    @Test("Without permission the notifications still name the song, without commands or prompts")
    func notificationOnly() async throws {
        let runner = FakeScriptRunner(permission: .notDetermined, respond: musicResponder)
        let presence = FakePresence(running: [music])
        let provider = AppleMusicProvider(runner: runner, presence: presence)
        let latest = LatestSnapshot(provider)
        provider.start()
        #expect(await eventually { provider.status.permission == .notDetermined })
        provider.ingest(AppleMusicPlayerInfo(state: .playing, title: "Glass Harbor", artist: "Nova Atlas", album: "Low Tide Lights", duration: 92, persistentID: "6F2D1E3C4B5A6978"))
        #expect(await eventually { latest.snapshot != nil })
        let snapshot = try #require(latest.snapshot)
        #expect(snapshot.track.title == "Glass Harbor")
        #expect(snapshot.track.id == "music:6F2D1E3C4B5A6978")
        #expect(snapshot.isPlaying)
        #expect(snapshot.capabilities.isEmpty, "commands go through the system's Now Playing instead")
        #expect(snapshot.bundleIdentifier == music)
        #expect(snapshot.processIdentifier == 4000)
        #expect(!(await provider.perform(.pause)))
        #expect(runner.scripts.isEmpty)
        #expect(runner.asks.allSatisfy { !$0 }, "checked without a prompt")
        #expect(!provider.status.hasFullAccess)
        provider.stop()
    }

    @Test("With permission it reads the player and fetches each cover once")
    func readsWithPermission() async throws {
        let runner = FakeScriptRunner(permission: .granted, respond: musicResponder)
        let presence = FakePresence(running: [music])
        let provider = AppleMusicProvider(runner: runner, presence: presence)
        let latest = LatestSnapshot(provider)
        provider.start()
        #expect(await eventually { latest.snapshot != nil })
        let snapshot = try #require(latest.snapshot)
        #expect(snapshot.track.id == "music:6F2D1E3C4B5A6978")
        #expect(snapshot.track.album == "Low Tide Lights")
        #expect(snapshot.track.duration == 92)
        #expect(abs(snapshot.elapsedTime - 12.5) < 1e-9)
        #expect(snapshot.isShuffled == false)
        #expect(snapshot.repeatMode == .all)
        #expect(snapshot.isLiked == true)
        #expect(snapshot.capabilities == .all)
        #expect(snapshot.artworkData == artworkBytes)
        #expect(provider.status.hasFullAccess)
        await provider.pollOnce()
        let artworkFetches = runner.scripts.filter { $0.contains("raw data of artwork") }.count
        #expect(artworkFetches == 1, "the same song does not fetch its cover again")
        #expect(runner.scripts.allSatisfy { $0.contains("tell application id \"com.apple.Music\"") })
        provider.stop()
    }

    @Test("Automation denied (-1743) stops reading and is reported")
    func denied() async {
        let runner = FakeScriptRunner(permission: .granted) { script in
            script.contains("player state") ? .failure(ScriptError(code: -1743, message: "Not authorized")) : .success(.missing)
        }
        let presence = FakePresence(running: [music])
        let provider = AppleMusicProvider(runner: runner, presence: presence)
        let statuses = provider.statusUpdates()
        provider.start()
        #expect(await eventually { provider.status.permission == .denied })
        let count = runner.scripts.count
        await provider.pollOnce()
        #expect(runner.scripts.count == count, "no more scripts once denied")
        let seen = await collect(statuses, count: 10, timeout: .seconds(1))
        #expect(seen.contains { $0.permission == .denied })
        provider.stop()
    }

    @Test("Quitting the app clears its song")
    func quitting() async {
        let runner = FakeScriptRunner(permission: .granted, respond: musicResponder)
        let presence = FakePresence(running: [music])
        let provider = AppleMusicProvider(runner: runner, presence: presence)
        let latest = LatestSnapshot(provider)
        provider.start()
        #expect(await eventually { latest.snapshot != nil })
        presence.setRunning(music, false)
        #expect(await eventually { latest.value == .some(nil) })
        #expect(!provider.status.isRunning)
        provider.stop()
    }

    @Test("Commands are scripts, only with permission")
    func commands() async {
        let runner = FakeScriptRunner(permission: .notDetermined, respond: musicResponder)
        let presence = FakePresence(running: [music])
        let provider = AppleMusicProvider(runner: runner, presence: presence)
        provider.start()
        #expect(await eventually { provider.status.permission == .notDetermined })
        #expect(!(await provider.perform(.pause)))
        #expect(runner.scripts.isEmpty)
        // The user presses "Allow…": now macOS may ask.
        #expect(await provider.refreshPermission(askIfNeeded: true) == .granted)
        #expect(runner.asks.last == true)
        #expect(await provider.perform(.pause))
        #expect(await provider.perform(.setRepeat(.one)))
        #expect(await provider.perform(.seek(to: 30.5)))
        let commands = runner.scripts.filter { !$0.contains("player state") && !$0.contains("raw data") }
        #expect(commands.contains { $0.contains("to pause") })
        #expect(commands.contains { $0.contains("set song repeat to one") })
        #expect(commands.contains { $0.contains("set player position to 30.500") })
        provider.stop()
    }

    @Test("Apple Music reads, notifications and scripts")
    func appleMusicParsing() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        guard case .track(let snapshot, let hasArtwork) = AppleMusicPlayer.parse(musicRead, sampledAt: now) else {
            Issue.record("not a track")
            return
        }
        #expect(hasArtwork)
        #expect(snapshot.timestamp == now)
        #expect(snapshot.contentKind == .music)
        #expect(AppleMusicPlayer.parse(.list([.text("stopped")]), sampledAt: now) == .stopped)
        #expect(AppleMusicPlayer.parse(.list([.text("notrunning")]), sampledAt: now) == .stopped)
        #expect(SpotifyPlayer.parse(.list([.text("notrunning")]), sampledAt: now) == .stopped)
        // Every script checks that the app runs before it talks to it.
        let scripts = [AppleMusicPlayer.readScript, AppleMusicPlayer.artworkScript!, SpotifyPlayer.readScript]
            + PlaybackCommandSamples.all.compactMap { AppleMusicPlayer.script(for: $0) }
            + PlaybackCommandSamples.all.compactMap { SpotifyPlayer.script(for: $0) }
        for script in scripts {
            let guardLine = script.split(separator: "\n").first.map(String.init) ?? ""
            #expect(guardLine.hasPrefix("if application id \"") && guardLine.hasSuffix("\" is running then"), "\(script)")
        }
        #expect(AppleMusicPlayer.parse(.text("nonsense"), sampledAt: now) == .unreadable)
        var noPosition = musicRead.list!
        noPosition[1] = .missing
        if case .track(let paused, _) = AppleMusicPlayer.parse(.list(noPosition), sampledAt: now) {
            #expect(!paused.isPositionKnown)
        }

        let info = try #require(AppleMusicPlayerInfo(userInfo: [
            "Player State": "Paused", "Name": "Glass Harbor", "Artist": "Nova Atlas", "Album": "Low Tide Lights",
            "Total Time": NSNumber(value: 92_000), "PersistentID": NSNumber(value: Int64(-2)),
        ]))
        #expect(info.state == .paused)
        #expect(info.duration == 92)
        #expect(info.persistentID == "FFFFFFFFFFFFFFFE", "signed numbers become AppleScript's hex")
        #expect(AppleMusicPlayerInfo(userInfo: ["Name": "x"]) == nil)
        #expect(AppleMusicPlayerInfo.hexPersistentID(NSNumber(value: 255)) == "00000000000000FF")

        // A notification for the song already showing keeps its position.
        let current = NowPlayingSnapshot(
            track: Track(id: "music:FFFFFFFFFFFFFFFE", source: .appleMusic, title: "Glass Harbor", artist: "Nova Atlas", album: "Low Tide Lights", duration: 92),
            elapsedTime: 40, playbackRate: 1, timestamp: now
        )
        guard case .snapshot(let paused) = AppleMusicPlayer.outcome(of: info, current: current, now: now.addingTimeInterval(5)) else {
            Issue.record("no snapshot")
            return
        }
        #expect(!paused.isPlaying)
        #expect(paused.elapsedTime == 45)
        #expect(AppleMusicPlayer.outcome(of: AppleMusicPlayerInfo(state: .stopped), current: current, now: now) == .stopped)

        #expect(AppleMusicPlayer.script(for: .previous)?.contains("back track") == true)
        #expect(AppleMusicPlayer.script(for: .setLiked(true))?.contains("set favorited of current track to true") == true)
        #expect(AppleMusicPlayer.script(for: .setShuffle(false))?.contains("set shuffle enabled to false") == true)
        #expect(AppleMusicPlayer.script(for: .seek(to: .infinity)) == nil)
    }

    @Test("Spotify reads, notifications and scripts")
    func spotifyParsing() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let read = ScriptValue.list([
            .text("playing"), .number(9.25), .text("Paper Satellites"), .text("The Quiet Ferns"), .text("Signal & Bloom"),
            .number(84_000), .text("spotify:track:0123456789abcdefABCDEF"), .text("https://i.scdn.co/image/ab67616d0000b273invented"),
            .boolean(true), .boolean(false),
        ])
        guard case .track(let snapshot, _) = SpotifyPlayer.parse(read, sampledAt: now) else {
            Issue.record("not a track")
            return
        }
        #expect(snapshot.track.duration == 84, "milliseconds become seconds")
        #expect(snapshot.track.id == "spotify:track:0123456789abcdefABCDEF")
        #expect(snapshot.track.artworkURL?.host == "i.scdn.co")
        #expect(snapshot.isShuffled == true)
        #expect(snapshot.repeatMode == .off)
        #expect(snapshot.contentKind == .music)
        #expect(SpotifyPlayer.contentKind(forTrackID: "spotify:ad:123") == .advertisement)
        #expect(SpotifyPlayer.contentKind(forTrackID: "spotify:episode:123") == .podcast)

        let event = try #require(SpotifyPlaybackEvent(userInfo: [
            "Player State": "Playing", "Track ID": "spotify:track:0123456789abcdefABCDEF", "Playback Position": NSNumber(value: 30.5),
            "Name": "Paper Satellites", "Artist": "The Quiet Ferns", "Album": "Signal & Bloom", "Duration": NSNumber(value: 84_000),
        ]))
        guard case .snapshot(let notified) = SpotifyPlayer.outcome(of: event, current: snapshot, now: now) else {
            Issue.record("no snapshot")
            return
        }
        #expect(notified.elapsedTime == 30.5, "the notification carries the position")
        #expect(notified.isPositionKnown)
        #expect(notified.track.artworkURL == snapshot.track.artworkURL, "the cover URL carries over")
        #expect(notified.isShuffled == true, "and so does shuffle")

        #expect(SpotifyPlayer.script(for: .setRepeat(.one)) == nil)
        #expect(SpotifyPlayer.script(for: .setLiked(true)) == nil)
        #expect(SpotifyPlayer.script(for: .setRepeat(.all))?.contains("set repeating to true") == true)
        #expect(SpotifyPlayer.script(for: .previous)?.contains("previous track") == true)
        #expect(!SpotifyPlayer.capabilities.contains(.like))
    }
}

enum PlaybackCommandSamples {
    static let all: [PlaybackCommand] = [
        .play, .pause, .togglePlayPause, .next, .previous, .seek(to: 12), .setShuffle(true),
        .setRepeat(.off), .setRepeat(.one), .setRepeat(.all), .setLiked(true), .setLiked(false),
    ]
}
