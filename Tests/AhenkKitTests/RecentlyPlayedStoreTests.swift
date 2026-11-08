import Foundation
import Testing
@testable import AhenkKit

@Suite("Continue Playing store")
struct RecentlyPlayedStoreTests {
    private func track(_ title: String, source: MusicSource = .spotify, id: String? = nil, album: String = "") -> Track {
        Track(id: id ?? "\(source.rawValue):\(title)", source: source, title: title, artist: "Invented Artist", album: album)
    }

    private func playing(_ track: Track) -> NowPlayingSnapshot {
        NowPlayingSnapshot(track: track, elapsedTime: 0, playbackRate: 1, timestamp: Date(), contentKind: .music)
    }

    @Test("Newest first, a replayed song moves to the top")
    func ordering() {
        let store = RecentlyPlayedStore(fileURL: nil)
        store.record(track("One"), bundleIdentifier: KnownApps.spotify, at: Date(timeIntervalSince1970: 1))
        store.record(track("Two"), bundleIdentifier: KnownApps.spotify, at: Date(timeIntervalSince1970: 2))
        store.record(track("One"), bundleIdentifier: KnownApps.spotify, at: Date(timeIntervalSince1970: 3))
        #expect(store.items.map(\.track.title) == ["One", "Two"])
        #expect(store.items.first?.playedAt == Date(timeIntervalSince1970: 3))
    }

    @Test("The same song from two providers counts once")
    func dedupeByMetadata() {
        let store = RecentlyPlayedStore(fileURL: nil)
        store.record(track("Glass Harbor", source: .appleMusic, id: "mr:1"), bundleIdentifier: nil, at: Date())
        store.record(track("Glass Harbor", source: .appleMusic, id: "music:ABC", album: "Low Tide Lights"), bundleIdentifier: nil, at: Date())
        #expect(store.items.count == 1)
        #expect(store.items.first?.track.album == "Low Tide Lights", "details that arrive later fill in")
        store.record(track("Glass Harbor", source: .spotify), bundleIdentifier: nil, at: Date())
        #expect(store.items.count == 2, "another source is another entry")
    }

    @Test("Keeps the newest fifty")
    func capacity() {
        let store = RecentlyPlayedStore(fileURL: nil)
        for index in 0..<60 {
            store.record(track("Song \(index)"), bundleIdentifier: nil, at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(store.items.count == RecentlyPlayedStore.capacity)
        #expect(store.items.first?.track.title == "Song 59")
        #expect(store.items.last?.track.title == "Song 10")
    }

    @Test("Only playing music with a title; never adverts, videos or podcasts")
    func filtering() {
        let store = RecentlyPlayedStore(fileURL: nil)
        for kind in [ContentKind.advertisement, .video, .podcast] {
            var other = playing(track("Not a song (\(kind.rawValue))"))
            other.contentKind = kind
            store.notePlaying(other)
        }
        var paused = playing(track("Paused"))
        paused.playbackRate = 0
        store.notePlaying(paused)
        store.notePlaying(playing(track("   ")))
        #expect(store.items.isEmpty)
        store.notePlaying(playing(track("Real")))
        store.notePlaying(playing(track("Real")))
        #expect(store.items.count == 1)
        var unlabelled = playing(track("Unlabelled"))
        unlabelled.contentKind = .unknown
        store.notePlaying(unlabelled)
        #expect(store.items.count == 2, "players that do not say what they play still count")
    }

    @Test("Persists to disk and reads back leniently")
    func persistence() throws {
        let scratch = ScratchDirectory()
        let url = scratch.url.appendingPathComponent("RecentlyPlayed.json")
        let store = RecentlyPlayedStore(fileURL: url)
        store.record(track("One", album: "Album"), bundleIdentifier: KnownApps.spotify, at: Date(timeIntervalSince1970: 100))
        store.record(track("Two"), bundleIdentifier: nil, at: Date(timeIntervalSince1970: 200))
        store.flush()
        let reloaded = RecentlyPlayedStore(fileURL: url)
        #expect(reloaded.items == store.items)
        #expect(reloaded.items.first?.artworkKey == "cover:spotify:spotify:Two")

        // One broken entry does not lose the others.
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"title\" : \"Two\"", with: "\"title\" : 42")
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(RecentlyPlayedStore(fileURL: url).items.map(\.track.title) == ["One"])

        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(RecentlyPlayedStore(fileURL: url).items.isEmpty)
    }

    @Test("Removing and clearing")
    func removal() async {
        let store = RecentlyPlayedStore(fileURL: nil)
        let changes = store.changes()
        store.record(track("One"), bundleIdentifier: nil, at: Date())
        store.record(track("Two"), bundleIdentifier: nil, at: Date())
        store.remove(id: store.items[1].id)
        #expect(store.items.map(\.track.title) == ["Two"])
        store.removeAll()
        #expect(store.items.isEmpty)
        let seen = await collect(changes, count: 5, timeout: .seconds(1))
        #expect(seen.map(\.count) == [0, 1, 2, 1, 0])
    }
}
