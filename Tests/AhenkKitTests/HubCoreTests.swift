import Foundation
import Testing
@testable import AhenkKit

// Invented songs only.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func snapshot(
    _ source: MusicSource, _ title: String, bundle: String? = nil, id: String? = nil, playing: Bool = true,
    elapsed: TimeInterval = 0, at time: Date = t0, duration: TimeInterval = 200,
    capabilities: PlaybackCapabilities = .transport, positionKnown: Bool = true, album: String = "Album"
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        track: Track(id: id ?? "\(source.rawValue):\(title)", source: source, title: title, artist: "Artist", album: album, duration: duration),
        bundleIdentifier: bundle,
        elapsedTime: elapsed,
        playbackRate: playing ? 1 : 0,
        timestamp: time,
        isPositionKnown: positionKnown,
        capabilities: capabilities,
        contentKind: .music
    )
}

private let spotifyID = PlayerID(source: .spotify, bundleIdentifier: KnownApps.spotify)
private let musicID = PlayerID(source: .appleMusic, bundleIdentifier: KnownApps.appleMusic)
private let webID = PlayerID(source: .otherApp, bundleIdentifier: KnownApps.search)

@Suite("Hub rules")
struct HubCoreTests {
    private func core(_ configuration: HubConfiguration = HubConfiguration()) -> HubCore {
        HubCore(configuration: configuration, priorities: ["mediaremote": 10, "spotify": 20, "apple-music": 20, "browser": 20])
    }

    @Test("Automatic follows the player that started most recently")
    func mostRecentStart() {
        var hub = core()
        hub.ingest([snapshot(.spotify, "Song A", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        #expect(hub.state.activeID == spotifyID)
        hub.ingest([snapshot(.otherApp, "Video B", bundle: KnownApps.search)], from: "mediaremote", now: t0 + 10)
        #expect(hub.state.activeID == webID, "the newer start wins")
        #expect(hub.state.players.map(\.id) == [webID, spotifyID])
        // Spotify moving to its next song is not a new start.
        hub.ingest([snapshot(.spotify, "Song C", bundle: KnownApps.spotify)], from: "spotify", now: t0 + 20)
        #expect(hub.state.activeID == webID)
    }

    @Test("With nothing playing the last followed player stays")
    func pausedStays() {
        var hub = core()
        hub.ingest([snapshot(.spotify, "Song A", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        hub.ingest([snapshot(.spotify, "Song A", bundle: KnownApps.spotify, playing: false)], from: "spotify", now: t0 + 5)
        #expect(hub.state.activeID == spotifyID)
        #expect(hub.state.activeSnapshot?.isPlaying == false)
        hub.ingest([snapshot(.appleMusic, "Song M", bundle: KnownApps.appleMusic, playing: false)], from: "apple-music", now: t0 + 6)
        #expect(hub.state.activeID == spotifyID, "a paused newcomer does not take over")
        hub.ingest([snapshot(.appleMusic, "Song M", bundle: KnownApps.appleMusic)], from: "apple-music", now: t0 + 7)
        #expect(hub.state.activeID == musicID, "pressing play does")
    }

    @Test("Reports of one player merge, the dedicated provider first")
    func merging() throws {
        var hub = core()
        var system = snapshot(.appleMusic, "Glass Harbor", bundle: KnownApps.appleMusic, id: "mr:1", elapsed: 30, album: "")
        system.isShuffled = true
        system.artworkData = Data([1])
        system.processIdentifier = 77
        hub.ingest([system], from: "mediaremote", now: t0)
        // Music's notification: richer identity, no position, no commands.
        let notified = snapshot(.appleMusic, "Glass Harbor", bundle: KnownApps.appleMusic, id: "music:ABC", elapsed: 0, capabilities: [], positionKnown: false)
        hub.ingest([notified], from: "apple-music", now: t0 + 1)
        #expect(hub.state.players.count == 1, "the same player, not two")
        let merged = try #require(hub.state.activeSnapshot)
        #expect(merged.track.id == "music:ABC")
        #expect(merged.track.album == "Album")
        #expect(merged.isPositionKnown && merged.elapsedTime == 30, "the position comes from the system report")
        #expect(merged.isShuffled == true)
        #expect(merged.artworkData == Data([1]))
        #expect(merged.processIdentifier == 77)
        #expect(merged.capabilities == .transport, "commands of both")
        #expect(hub.state.active?.providerIDs == ["apple-music", "mediaremote"])
        // Routing: the notification-only provider cannot pause; the adapter can.
        #expect(hub.provider(for: .pause, on: musicID) == "mediaremote")
        #expect(hub.provider(for: .setShuffle(true), on: musicID) == nil)
        // A different song from the system report is not merged in.
        hub.ingest([snapshot(.appleMusic, "Older Song", bundle: KnownApps.appleMusic, elapsed: 99)], from: "mediaremote", now: t0 + 2)
        #expect(hub.state.activeSnapshot?.isPositionKnown == false)
    }

    @Test("Pinned follows only its source")
    func pinned() {
        var hub = core(HubConfiguration(selection: .pinned(.spotify)))
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0)
        #expect(hub.state.activeID == nil, "nothing from the pinned source")
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, playing: false)], from: "spotify", now: t0 + 1)
        #expect(hub.state.activeID == spotifyID, "even paused")
        #expect(hub.state.conflict == nil)
        hub.setConfiguration(HubConfiguration(), now: t0 + 2)
        #expect(hub.state.activeID == webID, "automatic again: the one that plays")
    }

    @Test("Ignored sources are dropped entirely")
    func ignored() {
        var hub = core(HubConfiguration(ignoredSources: [.otherApp]))
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0)
        #expect(hub.state.players.isEmpty && hub.state.activeID == nil)
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        #expect(hub.state.activeID == spotifyID)
    }

    @Test("Two players together for a moment raise a conflict")
    func conflictAfterDelay() throws {
        var hub = core(HubConfiguration(conflictDelay: 3))
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0 + 1)
        #expect(hub.state.conflict == nil, "not yet: one may stop by itself")
        #expect(hub.nextDeadline == t0 + 4)
        hub.tick(now: t0 + 3.9)
        #expect(hub.state.conflict == nil)
        hub.tick(now: t0 + 4)
        let conflict = try #require(hub.state.conflict)
        #expect(conflict.players == [webID, spotifyID])
        #expect(hub.state.activeID == webID, "meanwhile the newest is followed")
        // One stops: no conflict any more.
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search, playing: false)], from: "mediaremote", now: t0 + 6)
        #expect(hub.state.conflict == nil)
    }

    @Test("A short overlap while switching asks nothing")
    func shortOverlap() {
        var hub = core()
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0 + 1)
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, playing: false)], from: "spotify", now: t0 + 2)
        hub.tick(now: t0 + 10)
        #expect(hub.state.conflict == nil)
        #expect(hub.nextDeadline == nil)
    }

    @Test("Asking can be turned off, and pinning never asks")
    func noAsking() {
        var quiet = core(HubConfiguration(askWhenSeveralPlay: false))
        quiet.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        quiet.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0)
        quiet.tick(now: t0 + 60)
        #expect(quiet.state.conflict == nil)
        var pinned = core(HubConfiguration(selection: .pinned(.spotify)))
        pinned.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        pinned.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0)
        pinned.tick(now: t0 + 60)
        #expect(pinned.state.conflict == nil)
        #expect(pinned.state.activeID == spotifyID)
    }

    @Test("Choosing answers the conflict and is followed until something new starts")
    func choosing() {
        var hub = core()
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0 + 1)
        hub.tick(now: t0 + 5)
        #expect(hub.state.conflict != nil)
        hub.choose(spotifyID, now: t0 + 6)
        #expect(hub.state.conflict == nil)
        #expect(hub.state.activeID == spotifyID, "the older one, because the user said so")
        hub.tick(now: t0 + 30)
        #expect(hub.state.conflict == nil, "the same pair is not asked about again")
        #expect(hub.state.activeID == spotifyID)
        // Music starts: a new situation.
        hub.ingest([snapshot(.appleMusic, "Other", bundle: KnownApps.appleMusic)], from: "apple-music", now: t0 + 40)
        #expect(hub.state.activeID == musicID)
        hub.tick(now: t0 + 44)
        #expect(hub.state.conflict?.players.count == 3)
    }

    @Test("A quick pause between songs keeps the start time")
    func resumeGrace() {
        var hub = core()
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify)], from: "spotify", now: t0)
        hub.ingest([snapshot(.otherApp, "Video", bundle: KnownApps.search)], from: "mediaremote", now: t0 + 10)
        // Spotify blinks paused for a second while changing songs.
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, playing: false)], from: "spotify", now: t0 + 20)
        hub.ingest([snapshot(.spotify, "Next", bundle: KnownApps.spotify)], from: "spotify", now: t0 + 21)
        #expect(hub.state.activeID == webID, "Spotify did not start anew")
        // A real pause and play later is a new start.
        hub.ingest([snapshot(.spotify, "Next", bundle: KnownApps.spotify, playing: false)], from: "spotify", now: t0 + 30)
        hub.ingest([snapshot(.spotify, "Next", bundle: KnownApps.spotify)], from: "spotify", now: t0 + 40)
        #expect(hub.state.activeID == spotifyID)
    }

    @Test("The followed player lingers briefly when its source goes quiet")
    func vanishGrace() {
        var hub = core()
        hub.ingest([snapshot(.otherApp, "Song", bundle: KnownApps.search)], from: "mediaremote", now: t0)
        hub.ingest([], from: "mediaremote", now: t0 + 1)
        #expect(hub.state.activeID == webID, "a gap between two songs")
        #expect(hub.nextDeadline == t0 + 1 + HubCore.vanishGrace)
        hub.ingest([snapshot(.otherApp, "Next Song", bundle: KnownApps.search)], from: "mediaremote", now: t0 + 1.5)
        #expect(hub.state.activeSnapshot?.track.title == "Next Song")
        hub.ingest([], from: "mediaremote", now: t0 + 3)
        hub.tick(now: t0 + 3 + HubCore.vanishGrace)
        #expect(hub.state.activeID == nil, "then it is really gone")
        #expect(hub.state.players.isEmpty)
    }

    @Test("Expectations show a command's result until the player confirms it")
    func expectations() throws {
        var hub = core()
        let playing = snapshot(.spotify, "Song", bundle: KnownApps.spotify, elapsed: 10)
        hub.ingest([playing], from: "spotify", now: t0)
        let pause = try #require(PlaybackExpectation.after(.pause, on: playing, at: t0 + 2))
        hub.expect(pause, for: spotifyID, now: t0 + 2)
        #expect(hub.state.activeSnapshot?.isPlaying == false)
        #expect(hub.state.activeSnapshot?.elapsed(at: t0 + 3) == 12)
        // A stale report from before the pause does not undo it.
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, elapsed: 10.5, at: t0 + 0.5)], from: "spotify", now: t0 + 2.2)
        #expect(hub.state.activeSnapshot?.isPlaying == false)
        // The confirmation replaces it.
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, playing: false, elapsed: 12.1, at: t0 + 2.3)], from: "spotify", now: t0 + 2.3)
        #expect(hub.state.activeSnapshot?.elapsedTime == 12.1)
        #expect(hub.nextDeadline == nil)

        let seek = try #require(PlaybackExpectation.after(.seek(to: 500), on: playing, at: t0 + 5))
        #expect(seek.position == 200, "clamped to the song")
        hub.expect(seek, for: spotifyID, now: t0 + 5)
        hub.tick(now: t0 + 8)
        #expect(hub.state.activeSnapshot?.elapsedTime == 12.1, "an unconfirmed expectation expires")
        #expect(PlaybackExpectation.after(.next, on: playing, at: t0) == nil)
    }

    @Test("Commands route to the best provider that supports them")
    func routing() {
        var hub = core()
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, capabilities: [.transport, .shuffle, .repeatAll])], from: "spotify", now: t0)
        hub.ingest([snapshot(.spotify, "Song", bundle: KnownApps.spotify, capabilities: [.transport, .repeatOne, .repeatAll])], from: "mediaremote", now: t0)
        #expect(hub.provider(for: .pause, on: spotifyID) == "spotify")
        #expect(hub.provider(for: .setShuffle(true), on: spotifyID) == "spotify")
        #expect(hub.provider(for: .setRepeat(.one), on: spotifyID) == "mediaremote", "only MediaRemote can repeat one")
        #expect(hub.provider(for: .setLiked(true), on: spotifyID) == nil)
        #expect(hub.provider(for: .pause, on: musicID) == nil)
        #expect(hub.providers(reporting: spotifyID) == ["spotify", "mediaremote"])
    }
}
