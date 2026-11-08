import Foundation
import Testing
@testable import AhenkKit

@Suite("Track matching")
struct TrackMatchingTests {
    @Test("Normalization folds case, accents, width, punctuation and the dotless i")
    func normalization() {
        #expect(TrackMatching.normalized("  Glass   Harbor! ") == "glass harbor")
        #expect(TrackMatching.normalized("IŞIK") == TrackMatching.normalized("ışık"))
        #expect(TrackMatching.normalized("IŞIK") == "isik")
        #expect(TrackMatching.normalized("Café–Noir") == "cafe noir")
        #expect(TrackMatching.normalized("Salt & Pepper") == "salt and pepper")
        #expect(TrackMatching.normalized("ＦＵＬＬ") == "full")
    }

    @Test("Core titles drop service decorations")
    func coreTitles() {
        #expect(TrackMatching.coreTitle("Paper Moons (feat. Ida Vale)") == "paper moons")
        #expect(TrackMatching.coreTitle("Paper Moons [Remastered 2011]") == "paper moons")
        #expect(TrackMatching.coreTitle("Paper Moons - 2015 Remaster") == "paper moons")
        #expect(TrackMatching.coreTitle("Paper Moons - Radio Edit") == "paper moons")
        #expect(TrackMatching.coreTitle("Paper Moons ft. Ida Vale") == "paper moons")
        #expect(TrackMatching.coreTitle("Up - Down") == "up down", "a dash that is part of the title stays")
        #expect(TrackMatching.coreTitle("(Intro)") == "intro", "never empty")
    }

    @Test("Same song by id, or by metadata when the ids differ")
    func sameSong() {
        let a = Track(id: "music:ABC", source: .appleMusic, title: "Glass Harbor", artist: "Nova Atlas", album: "Low Tide Lights", duration: 92)
        var b = Track(id: "mr:12345", source: .appleMusic, title: "glass harbor", artist: "NOVA ATLAS", album: "", duration: 0)
        #expect(a.isSameSong(as: b), "metadata matches; the album and duration are not known yet")
        b.duration = 93.5
        #expect(a.isSameSong(as: b), "within 3 seconds")
        b.duration = 120
        #expect(!a.isSameSong(as: b), "a different length is a different recording")
        b.duration = 0
        b.album = "Another Album"
        #expect(!a.isSameSong(as: b))
        b.album = ""
        b.source = .spotify
        #expect(!a.isSameSong(as: b), "never across sources")
        let retitled = Track(id: "music:ABC", source: .appleMusic, title: "Renamed", artist: "Somebody")
        #expect(a.isSameSong(as: retitled), "the same id is the same song")
        let halfLoaded = Track(id: "x", source: .appleMusic, title: "Glass Harbor", artist: "")
        #expect(a.isSameSong(as: halfLoaded), "an update without the artist yet")
        let empty = Track(id: "y", source: .appleMusic, title: "", artist: "Nova Atlas")
        #expect(!a.isSameSong(as: empty))
    }

    @Test("Snapshots compare songs the same way")
    func snapshotsUseSongMatching() {
        let now = Date()
        let a = NowPlayingSnapshot(track: Track(id: "1", source: .spotify, title: "Copper", artist: "Lumen"), elapsedTime: 0, playbackRate: 1, timestamp: now)
        let b = NowPlayingSnapshot(track: Track(id: "2", source: .spotify, title: "Copper", artist: "Lumen"), elapsedTime: 40, playbackRate: 0, timestamp: now)
        #expect(a.isSameTrack(as: b))
    }

    @Test("Noticeable changes: song, state, seek; not steady playback")
    func noticeableChanges() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let track = Track(id: "1", source: .spotify, title: "Copper", artist: "Lumen", duration: 200)
        let a = NowPlayingSnapshot(track: track, elapsedTime: 10, playbackRate: 1, timestamp: start, capabilities: .transport)
        var b = a
        b.elapsedTime = 13
        b.timestamp = start.addingTimeInterval(3)
        #expect(!b.differsNoticeably(from: a, at: start.addingTimeInterval(3)), "the same timeline sampled later")
        b.elapsedTime = 60
        #expect(b.differsNoticeably(from: a, at: start.addingTimeInterval(3)), "a seek")
        var paused = a
        paused.playbackRate = 0
        #expect(paused.differsNoticeably(from: a, at: start))
        var liked = a
        liked.isLiked = true
        #expect(liked.differsNoticeably(from: a, at: start))
        var art = a
        art.artworkData = Data([1, 2, 3])
        #expect(art.differsNoticeably(from: a, at: start))
    }

    @Test("Capabilities map to commands")
    func capabilities() {
        let transport = PlaybackCapabilities.transport
        #expect(transport.supports(.play) && transport.supports(.togglePlayPause) && transport.supports(.next) && transport.supports(.seek(to: 3)))
        #expect(!transport.supports(.setShuffle(true)))
        let spotify: PlaybackCapabilities = [.transport, .shuffle, .repeatAll]
        #expect(spotify.supports(.setRepeat(.all)) && spotify.supports(.setRepeat(.off)))
        #expect(!spotify.supports(.setRepeat(.one)))
        #expect(!spotify.supports(.setLiked(true)))
        let likeOnly: PlaybackCapabilities = [.like]
        #expect(likeOnly.supports(.setLiked(true)) && !likeOnly.supports(.setLiked(false)))
        #expect(PlaybackCapabilities.all.supports(.setLiked(false)))
    }

    @Test("Setting the play state keeps the position reached")
    func setPlaying() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var snapshot = NowPlayingSnapshot(track: Track(id: "1", source: .demo, title: "A", artist: "B", duration: 100), elapsedTime: 10, playbackRate: 1, timestamp: start)
        snapshot.setPlaying(false, at: start.addingTimeInterval(5))
        #expect(snapshot.elapsedTime == 15)
        #expect(!snapshot.isPlaying)
        snapshot.setPlaying(true, at: start.addingTimeInterval(50))
        #expect(snapshot.elapsed(at: start.addingTimeInterval(52)) == 17)
    }
}
