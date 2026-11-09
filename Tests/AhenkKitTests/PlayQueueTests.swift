import Foundation
import Testing
@testable import AhenkKit

private func song(_ name: String, artist: String = "Juniper Coast", duration: TimeInterval = 180) -> CatalogSong {
    CatalogSong(id: "test:\(name)", title: name, artistName: artist, albumTitle: "Paper Lighthouse", duration: duration)
}

private func titles(_ entries: [QueueEntry]) -> [String] {
    entries.map(\.song.title)
}

@Suite("Play queue")
struct PlayQueueTests {
    let album = ["One", "Two", "Three", "Four"].map { song($0) }

    @Test("Starting an album at a song keeps the songs before it as history")
    func start() {
        var queue = PlayQueue()
        #expect(queue.current == nil && queue.isEmpty)
        queue.start(album, at: 1, context: .album(id: "a", title: "Paper Lighthouse"))
        #expect(queue.current?.song.title == "Two")
        #expect(titles(queue.history) == ["One"])
        #expect(titles(queue.upNext) == ["Three", "Four"])
        #expect(queue.context == .album(id: "a", title: "Paper Lighthouse"))
        queue.start(album, at: 99, context: nil)
        #expect(queue.current?.song.title == "Four", "an index past the end starts the last song")
    }

    @Test("Play Next goes right after the current song, newest first; Add to Queue at the end")
    func playNextAndAppend() {
        var queue = PlayQueue()
        queue.start(album, at: 0, context: nil)
        queue.playNext([song("A")])
        queue.playNext([song("B")])
        queue.append([song("Z")])
        #expect(titles(queue.upNext) == ["B", "A", "Two", "Three", "Four", "Z"])
        #expect(queue.upNext.filter(\.isUserAdded).count == 3)
        var empty = PlayQueue()
        empty.playNext([song("Solo")])
        #expect(titles(empty.upNext) == ["Solo"] && empty.current == nil)
    }

    @Test("Starting something new keeps what the user queued")
    func startKeepsUserQueue() {
        var queue = PlayQueue()
        queue.start(album, at: 0, context: nil)
        queue.playNext([song("Mine")])
        queue.start([song("X"), song("Y")], at: 0, context: .search)
        #expect(queue.current?.song.title == "X")
        #expect(titles(queue.upNext) == ["Mine", "Y"])
    }

    @Test("Removing and moving up-next entries; the current one stays")
    func removeAndMove() throws {
        var queue = PlayQueue()
        queue.start(album, at: 1, context: nil)
        let current = try #require(queue.current)
        let removedCurrent = queue.remove(current.id)
        #expect(!removedCurrent)
        let first = try #require(queue.history.first)
        let removedFirst = queue.remove(first.id)
        #expect(removedFirst)
        #expect(queue.current?.song.title == "Two", "the current index follows the removal")
        let four = try #require(queue.upNext.last)
        let moved = queue.move(four.id, toUpNextPosition: 0)
        #expect(moved)
        #expect(titles(queue.upNext) == ["Four", "Three"])
        let removedUnknown = queue.remove(UUID())
        #expect(!removedUnknown)
        queue.clearUpNext()
        #expect(queue.upNext.isEmpty && queue.current?.song.title == "Two")
    }

    @Test("Advance and retreat follow repeat off, all and one")
    func advanceAndRepeat() {
        var queue = PlayQueue()
        queue.start(album, at: 2, context: nil)
        var moved = queue.advance()
        #expect(moved?.song.title == "Four")
        #expect(queue.following == nil)
        moved = queue.advance()
        #expect(moved == nil, "repeat off stops at the end")
        #expect(queue.current?.song.title == "Four")
        queue.repeatMode = .all
        #expect(queue.following?.song.title == "One")
        moved = queue.advance()
        #expect(moved?.song.title == "One")
        moved = queue.retreat()
        #expect(moved?.song.title == "Four", "repeat all wraps backwards too")
        queue.repeatMode = .one
        moved = queue.advance()
        #expect(moved?.song.title == "Four")
        queue.repeatMode = .off
        moved = queue.retreat()
        #expect(moved?.song.title == "Three")
        let id = queue.entries[0].id
        moved = queue.jump(to: id)
        #expect(moved?.song.title == "One")
        moved = queue.retreat()
        #expect(moved == nil)
    }

    @Test("Following the source when it moves on by itself")
    func follow() {
        var queue = PlayQueue()
        queue.start(album, at: 0, context: nil)
        let three = Track(id: "spotify:track:x", source: .spotify, title: "Three", artist: "Juniper Coast", duration: 181)
        let followed = queue.follow(three)
        #expect(followed)
        #expect(queue.current?.song.title == "Three")
        let stranger = Track(id: "y", source: .spotify, title: "Somebody Else", artist: "Mira Sol")
        let followedStranger = queue.follow(stranger)
        #expect(!followedStranger)
        #expect(queue.current?.song.title == "Three")
    }

    @Test("Shuffle reorders only what is up next and can be undone")
    func shuffle() {
        var queue = PlayQueue()
        let many = (1...12).map { song("S\($0)") }
        queue.start(many, at: 3, context: nil)
        let before = titles(queue.upNext)
        queue.setShuffled(true, seed: 42)
        #expect(queue.isShuffled)
        #expect(queue.current?.song.title == "S4")
        #expect(titles(queue.history) == ["S1", "S2", "S3"])
        #expect(Set(titles(queue.upNext)) == Set(before))
        #expect(titles(queue.upNext) != before)
        queue.append([song("Late")])
        queue.setShuffled(false)
        #expect(titles(queue.upNext) == before + ["Late"])
        var again = PlayQueue()
        again.start(many, at: 3, context: nil)
        again.setShuffled(true, seed: 42)
        var other = PlayQueue()
        other.start(many, at: 3, context: nil)
        other.setShuffled(true, seed: 42)
        #expect(titles(again.upNext) == titles(other.upNext), "the same seed gives the same order")
    }
}

@Suite("Song matching")
struct SongMatchingTests {
    @Test("The same song across services")
    func matches() {
        let pick = CatalogSong(id: "itunes:song:1", title: "Harbor Bells (feat. Mira Sol)", artistName: "Juniper Coast & Mira Sol", duration: 187)
        #expect(SongMatching.matches(pick, Track(id: "a", source: .spotify, title: "Harbor Bells", artist: "Juniper Coast", duration: 186)))
        #expect(SongMatching.matches(pick, Track(id: "b", source: .youtubeMusic, title: "HARBOR BELLS", artist: "juniper coast & mira sol")))
        #expect(!SongMatching.matches(pick, Track(id: "c", source: .spotify, title: "Harbor Bells", artist: "Somebody Else")))
        #expect(!SongMatching.matches(pick, Track(id: "d", source: .spotify, title: "Harbor Bells", artist: "Juniper Coast", duration: 260)))
        #expect(!SongMatching.matches(pick, Track(id: "e", source: .spotify, title: "Harbor", artist: "Juniper Coast")))
        let played = CatalogSong(playing: Track(id: "music:ABC", source: .appleMusic, title: "Kıyı", artist: "Liman"))
        #expect(SongMatching.matches(played, Track(id: "music:ABC", source: .appleMusic, title: "Renamed", artist: "Liman")))
        #expect(SongMatching.matches(played, Track(id: "other", source: .spotify, title: "KIYI", artist: "liman")), "Turkish letters fold")
    }
}

@Suite("Queue conductor")
struct QueueConductorTests {
    let start = Date(timeIntervalSinceReferenceDate: 10_000)

    private func playing(_ title: String, at elapsed: TimeInterval, duration: TimeInterval = 180, rate: Double = 1, sampled: Date) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: Track(id: title, source: .spotify, title: title, artist: "Juniper Coast", duration: duration),
            elapsedTime: elapsed, playbackRate: rate, timestamp: sampled, contentKind: .music
        )
    }

    private func setUp() -> (PlayQueue, PlaybackAttempt) {
        var queue = PlayQueue()
        queue.start(["One", "Two", "Three"].map { song($0) }, at: 0, context: nil)
        let attempt = PlaybackAttempt(entryID: queue.current!.id, song: queue.current!.song, source: .spotify, requestedAt: start)
        return (queue, attempt)
    }

    @Test("A requested song is confirmed when it plays, or fails after the timeout")
    func confirmation() {
        let (queue, attempt) = setUp()
        let old = playing("Something Old", at: 30, sampled: start)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: old, lastOwn: nil, now: start.addingTimeInterval(1)) == .none)
        let mine = playing("One", at: 0.2, sampled: start.addingTimeInterval(1))
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: mine, lastOwn: nil, now: start.addingTimeInterval(1)) == .confirmed)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: old, lastOwn: nil, now: start.addingTimeInterval(13)) == .startFailed)
        #expect(QueueConductorPolicy.wakeTime(attempt: attempt, snapshot: old, now: start) == start.addingTimeInterval(QueueConductorPolicy.startTimeout + 0.05))
    }

    @Test("The next song starts just before the current one ends")
    func advanceNearTheEnd() {
        let (queue, unconfirmed) = setUp()
        var attempt = unconfirmed
        attempt.confirmedAt = start
        let early = playing("One", at: 100, sampled: start)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: early, lastOwn: early, now: start) == .none)
        let wake = QueueConductorPolicy.wakeTime(attempt: attempt, snapshot: early, now: start)
        #expect(wake == start.addingTimeInterval(80 - QueueConductorPolicy.endLead))
        let late = start.addingTimeInterval(79.8)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: early, lastOwn: early, now: late) == .advance)
        let pausedAtEnd = playing("One", at: 179.5, rate: 0, sampled: start)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: pausedAtEnd, lastOwn: early, now: start) == .advance)
        let pausedEarly = playing("One", at: 60, rate: 0, sampled: start)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: pausedEarly, lastOwn: early, now: start) == .none)
        #expect(QueueConductorPolicy.wakeTime(attempt: attempt, snapshot: pausedEarly, now: start) == nil)
    }

    @Test("Following, taking back after autoplay, and stepping aside")
    func otherSongs() {
        let (queue, unconfirmed) = setUp()
        var attempt = unconfirmed
        attempt.confirmedAt = start
        let lastOwn = playing("One", at: 177, sampled: start)
        let two = playing("Two", at: 0, sampled: start.addingTimeInterval(2))
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: two, lastOwn: lastOwn, now: start.addingTimeInterval(2))
            == .followed(queue.upNext[0].id))
        let autoplay = playing("A Song Spotify Picked", at: 0, sampled: start.addingTimeInterval(3))
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: autoplay, lastOwn: lastOwn, now: start.addingTimeInterval(3)) == .advance)
        let midway = playing("One", at: 60, sampled: start)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: autoplay, lastOwn: midway, now: start.addingTimeInterval(3)) == .takenOver)
        #expect(QueueConductorPolicy.decide(attempt: nil, queue: queue, snapshot: autoplay, lastOwn: nil, now: start) == .none)
    }
}
