import Foundation
import Testing
@testable import AhenkKit

// Invented songs only.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let chrome = "com.google.Chrome"

private func tab(
    _ key: String, _ title: String, site: MusicSource = .youtubeMusic, artist: String = "Orchid Telemetry", browser: String = chrome,
    playing: Bool = true, kind: ContentKind = .music, at time: Date = t0
) -> NowPlayingSnapshot {
    var report = BrowserTabReport(
        tabID: key, browserBundleIdentifier: browser, site: site, title: title, artist: artist, album: "Tidal Glass", duration: 214,
        elapsedTime: 10, isPlaying: playing, sampledAt: time, contentKind: kind, capabilities: .transport
    )
    report.processIdentifier = 501
    return report.snapshot
}

/// What the system's Now Playing reports for a browser: no tab, a guessed site.
private func guess(_ title: String, artist: String = "Orchid Telemetry", browser: String = chrome, playing: Bool = true, at time: Date = t0) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        track: Track(id: "meta:\(title)", source: .otherApp, title: title, artist: artist), bundleIdentifier: browser,
        elapsedTime: 10, playbackRate: playing ? 1 : 0, timestamp: time, capabilities: .transport, contentKind: .music
    )
}

@Suite("Browser tabs in the hub")
struct BrowserHubTests {
    private func core(_ configuration: HubConfiguration = HubConfiguration()) -> HubCore {
        var core = HubCore(configuration: configuration, priorities: ["mediaremote": 10, "browser": 20, "spotify": 20])
        core.setShadowing(true, for: "browser")
        return core
    }

    @Test("The system's guess of a tab's song is hidden: one song, one player")
    func dedupe() {
        var hub = core()
        hub.ingest([guess("Velvet Harbor Lights - YouTube Music")], from: "mediaremote", now: t0)
        #expect(hub.state.players.count == 1, "alone, the guess is a player")
        hub.ingest([tab("p/1", "Velvet Harbor Lights")], from: "browser", now: t0 + 0.2)
        #expect(hub.state.players.map(\.id) == [PlayerID(source: .youtubeMusic, bundleIdentifier: chrome, instance: "p/1")])
        #expect(hub.state.conflict == nil && hub.nextDeadline == nil)
        // An artist written the channel's way still matches.
        hub.ingest([guess("Velvet Harbor Lights (Official Audio)", artist: "Orchid Telemetry - Topic")], from: "mediaremote", now: t0 + 1)
        #expect(hub.state.players.count == 1)
    }

    @Test("Another browser's player is never hidden")
    func otherBrowser() {
        var hub = core()
        hub.ingest([tab("p/1", "Velvet Harbor Lights")], from: "browser", now: t0)
        hub.ingest([guess("Velvet Harbor Lights", browser: KnownApps.search)], from: "mediaremote", now: t0)
        #expect(hub.state.players.count == 2)
    }

    @Test("A different song in the same browser shows up after a grace (a site the extension does not know)")
    func unmatchedGuess() {
        var hub = core(HubConfiguration(conflictDelay: 3))
        hub.ingest([tab("p/1", "Velvet Harbor Lights", playing: false)], from: "browser", now: t0)
        hub.ingest([guess("Lecture on tides", artist: "Open Course")], from: "mediaremote", now: t0 + 1)
        #expect(hub.state.players.count == 1, "hidden while the two sides may still be catching up")
        #expect(hub.nextDeadline == t0 + 1 + HubCore.shadowGrace)
        hub.tick(now: t0 + 1 + HubCore.shadowGrace)
        #expect(hub.state.players.count == 2)
        #expect(hub.state.activeID?.source == .otherApp, "it plays; the paused tab does not")
        hub.tick(now: t0 + 30)
        #expect(hub.state.players.count == 2, "stays visible")
        #expect(hub.nextDeadline == nil, "nothing left to wait for (no busy timer)")
    }

    @Test("A song change seen first by the system does not flash another player")
    func songChangeOrder() {
        var hub = core()
        hub.ingest([tab("p/1", "Velvet Harbor Lights")], from: "browser", now: t0)
        hub.ingest([guess("Quiet Engines", artist: "Nadia Ferro")], from: "mediaremote", now: t0 + 100)
        #expect(hub.state.players.count == 1)
        hub.ingest([tab("p/1", "Quiet Engines", artist: "Nadia Ferro", at: t0 + 100.3)], from: "browser", now: t0 + 100.3)
        #expect(hub.state.players.count == 1)
        #expect(hub.state.activeSnapshot?.track.title == "Quiet Engines")
        #expect(hub.nextDeadline == nil)
    }

    @Test("Two tabs playing at once raise the question; the answer is followed")
    func conflict() throws {
        var hub = core(HubConfiguration(conflictDelay: 3))
        let a = tab("p/1", "Velvet Harbor Lights")
        let b = tab("p/2", "Saffron Static", site: .soundCloud, artist: "Kestrel & Vale")
        hub.ingest([a], from: "browser", now: t0)
        hub.ingest([a, b], from: "browser", now: t0 + 1)
        #expect(hub.state.activeID?.instance == "p/2", "the newer start")
        hub.tick(now: t0 + 4)
        let conflict = try #require(hub.state.conflict)
        #expect(conflict.players.map(\.instance) == ["p/2", "p/1"])
        hub.choose(PlayerID(snapshot: a), now: t0 + 5)
        #expect(hub.state.conflict == nil && hub.state.activeID?.instance == "p/1")
    }

    @Test("Commands go to the tab they name")
    func routing() {
        var hub = core()
        hub.ingest([guess("Velvet Harbor Lights")], from: "mediaremote", now: t0)
        hub.ingest([tab("p/1", "Velvet Harbor Lights"), tab("p/2", "Saffron Static", playing: false)], from: "browser", now: t0)
        let second = PlayerID(source: .youtubeMusic, bundleIdentifier: chrome, instance: "p/2")
        #expect(hub.provider(for: .pause, on: second) == "browser")
        #expect(hub.provider(for: .setLiked(true), on: second) == nil, "the tab does not offer it")
    }

    @Test("Music sites move the light, plain videos and adverts do not")
    func lightGate() {
        #expect(AudioCapturePolicy.reactsTo(tab("p/1", "Velvet Harbor Lights")))
        #expect(AudioCapturePolicy.reactsTo(tab("p/2", "Harbor walk", site: .youtube, kind: .music)), "music on YouTube")
        #expect(!AudioCapturePolicy.reactsTo(tab("p/3", "Harbor walk", site: .youtube, kind: .video)))
        #expect(!AudioCapturePolicy.reactsTo(tab("p/4", "Brand jingle", kind: .advertisement)))
        #expect(!AudioCapturePolicy.reactsTo(tab("p/5", "Episode 12", site: .spotifyWeb, kind: .podcast)))
    }

    @Test("The tap follows the tab's browser: same browser keeps it, another one moves it")
    func tapTarget() {
        let a = AudioTapTarget(snapshot: tab("p/1", "Velvet Harbor Lights"))
        #expect(a.bundleIdentifier == chrome && a.processIdentifier == 501 && a.isResolvable)
        var policy = AudioCapturePolicy()
        policy.update(permission: .authorized, now: 0)
        policy.update(snapshot: tab("p/1", "Velvet Harbor Lights"), now: 0)
        #expect(policy.request == .app(a) && policy.isGateOpen)
        // Another tab of the same site in the same browser: same processes.
        policy.update(snapshot: tab("p/2", "Quiet Engines"), now: 1)
        #expect(policy.request == .app(a))
        // A plain video closes the gate.
        policy.update(snapshot: tab("p/3", "Harbor walk", site: .youtube, kind: .video), now: 2)
        #expect(!policy.isGateOpen)
        // A tab in another browser retargets.
        var firefoxTab = tab("q/1", "Saffron Static", site: .soundCloud, browser: "org.mozilla.firefox")
        firefoxTab.processIdentifier = 777
        policy.update(snapshot: firefoxTab, now: 3)
        #expect(policy.request?.target?.bundleIdentifier == "org.mozilla.firefox" && policy.isGateOpen)
    }

    @Test("Chromium helpers that play a tab's sound belong to the browser")
    func helperProcesses() {
        let target = AudioTapTarget(snapshot: tab("p/1", "Velvet Harbor Lights"))
        let processes = [
            AudioProcess(objectID: 1, pid: 501, bundleIdentifier: chrome),
            AudioProcess(objectID: 2, pid: 640, bundleIdentifier: "com.google.Chrome.helper", ancestors: [501, 1]),
            AudioProcess(objectID: 3, pid: 900, bundleIdentifier: "org.mozilla.firefox", ancestors: [1]),
        ]
        let matched = AudioProcessMatcher.processes(for: target, appPIDs: [501], in: processes, ownPID: 42)
        #expect(matched.map(\.pid) == [501, 640])
    }
}

@Suite("Browser tabs through the hub driver")
struct BrowserHubDriverTests {
    /// A bridge fed by the test.
    final class FakeBridge: BrowserBridge, @unchecked Sendable {
        let stream: AsyncStream<[BrowserTabReport]>
        let continuation: AsyncStream<[BrowserTabReport]>.Continuation
        private(set) var sent: [(PlaybackCommand, String)] = []
        private let lock = NSLock()

        init() {
            (stream, continuation) = AsyncStream<[BrowserTabReport]>.makeStream()
        }

        func tabs() -> AsyncStream<[BrowserTabReport]> { stream }

        func send(_ command: PlaybackCommand, toTab tabID: String) async -> Bool {
            lock.withLock { sent.append((command, tabID)) }
            return true
        }

        var commands: [(PlaybackCommand, String)] { lock.withLock { sent } }
    }

    @Test("Choosing one tab pauses the other one through the bridge")
    func chooseAndPause() async throws {
        let bridge = FakeBridge()
        let clock = ManualClock()
        let hub = NowPlayingHub(
            inputs: [BrowserProvider(bridge: bridge).hubInput], configuration: HubConfiguration(pauseOthersOnSwitch: true, conflictDelay: 3),
            usesTimer: false, clock: clock.function
        )
        hub.start()
        defer { hub.stop() }
        func report(_ key: String, _ title: String) -> BrowserTabReport {
            var r = BrowserTabReport(tabID: key, browserBundleIdentifier: chrome, site: .youtubeMusic, title: title, artist: "Orchid Telemetry",
                                     isPlaying: true, sampledAt: clock.now, capabilities: .transport)
            r.browserTabID = Int(key.split(separator: "/").last ?? "0")
            return r
        }
        bridge.continuation.yield([report("p/1", "Velvet Harbor Lights")])
        clock.advance(1)
        bridge.continuation.yield([report("p/1", "Velvet Harbor Lights"), report("p/2", "Saffron Static")])
        for _ in 0..<200 where hub.currentState.players.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        clock.advance(4)
        hub.tick()
        let conflict = try #require(hub.currentState.conflict)
        let first = try #require(conflict.players.first { $0.instance == "p/1" })
        await hub.choose(first)
        #expect(bridge.commands.contains { $0.0 == .pause && $0.1 == "p/2" })
        #expect(hub.currentState.activeID?.instance == "p/1")
    }
}
