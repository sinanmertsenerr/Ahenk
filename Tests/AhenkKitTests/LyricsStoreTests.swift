import Foundation
import os
import Testing
@testable import AhenkKit

// Every line here is invented for the tests.

@Suite("Lyrics finder")
struct LyricsFinderTests {
    @Test("The pick comes first, then the cache, then the providers (whose answer is cached)")
    func order() async throws {
        let scratch = ScratchDirectory()
        let provider = ScriptedLyricsProvider("A") { _ in ChainFixtures.response(.synced(ChainFixtures.synced), from: "A") }
        let finder = LyricsFinder(chain: LyricsChain(providers: [provider]), cache: LyricsCache(directory: scratch.url), songs: LyricsSongStore(fileURL: nil))
        let query = LyricsFixtures.query
        #expect(await finder.find(query).origin == .providers)
        #expect(await finder.find(query).origin == .cache)
        #expect(provider.queries.count >= 1 && provider.queries.count <= 2, "asked once (with its cleaned variant at most)")

        let late = LyricsVersion(provider: "A", reference: "late", title: "Paper Lanterns", artist: "The Tin Orchard", kind: .synced, lyrics: .synced(ChainFixtures.synced.shifted(by: 0.7)))
        let chosen = try await finder.choose(late, for: query)
        guard case .synced(let picked) = chosen.result else { Issue.record("expected synced"); return }
        #expect(picked.lines[0].start == 5.7)
        let again = await finder.find(query)
        #expect(again.origin == .choice && again.choice?.reference == "late" && again.response == chosen)
        #expect(finder.songs.entry(for: query.cacheKey)?.choice?.lyrics == nil, "the pick is kept without its words")
        await finder.clearChoice(for: query)
        #expect(await finder.find(query).origin == .cache)
    }

    @Test("A miss is remembered for a while; an unreachable provider is not")
    func misses() async {
        let clock = ManualClock()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let empty = ScriptedLyricsProvider("A") { _ in
            calls.withLock { $0 += 1 }
            return .none
        }
        let finder = LyricsFinder(chain: LyricsChain(providers: [empty]), cache: nil, songs: LyricsSongStore(fileURL: nil), clock: clock.function)
        let query = LyricsQuery(title: "Nothing Here", artist: "No One")
        #expect(await finder.find(query).origin == .providers)
        #expect(await finder.find(query).origin == .recentMiss)
        clock.advance(LyricsFinder.missMemory + 1)
        #expect(await finder.find(query).origin == .providers)

        let broken = ScriptedLyricsProvider("B") { _ in throw URLError(.timedOut) }
        let offline = LyricsFinder(chain: LyricsChain(providers: [broken]), cache: nil, songs: LyricsSongStore(fileURL: nil), clock: clock.function)
        #expect(await offline.find(query).allFailed)
        #expect(await offline.find(query).origin == .providers, "tried again: the network may be back")
    }

    @Test("The demo offers three versions and finds its songs by title and artist")
    func demo() async throws {
        let demo = DemoProvider(startPlaying: false)
        let song = DemoCatalog.songs[0]
        let versions = try await demo.versions(for: LyricsQuery(track: song.track))
        #expect(versions.map(\.kind) == [.synced, .synced, .plain])
        guard case .synced(let late) = versions[1].lyrics else { Issue.record("expected synced"); return }
        #expect(late.lines[0].start == song.lyrics.lines[0].start + 0.7)
        let found = try await demo.search(LyricsQuery(title: "harbor", artist: "nova"))
        #expect(found.contains { $0.title == song.track.title })
        #expect(try await demo.search(LyricsQuery(title: "zzz", artist: "")).isEmpty)
    }
}

@Suite("Lyrics stores")
struct LyricsStoreTests {
    @Test("Offsets and picks per song persist, measured offsets only for their timeline")
    func songStore() throws {
        let scratch = ScratchDirectory()
        let url = scratch.url.appendingPathComponent("LyricsSongs.json")
        let store = LyricsSongStore(fileURL: url)
        store.setManualOffset(0.6, for: "song-a")
        store.setManualOffset(99, for: "song-b")
        store.setAutoOffset(-0.4, fingerprint: "fp-1", for: "song-a")
        let pick = LyricsVersion(provider: "LRCLIB", reference: "7", title: "Paper Lanterns", artist: "The Tin Orchard", kind: .synced, lyrics: .plain("words"))
        store.setChoice(pick, for: "song-a")
        store.flush()

        let reloaded = LyricsSongStore(fileURL: url)
        let entry = try #require(reloaded.entry(for: "song-a"))
        #expect(entry.manualOffset == 0.6 && entry.choice?.reference == "7" && entry.choice?.lyrics == nil)
        #expect(reloaded.entry(for: "song-b")?.manualOffset == LyricsSongStore.offsetRange.upperBound)
        #expect(reloaded.autoOffset(for: "song-a", fingerprint: "fp-1") == -0.4)
        #expect(reloaded.autoOffset(for: "song-a", fingerprint: "fp-2") == nil)

        reloaded.setManualOffset(0, for: "song-b")
        #expect(reloaded.entry(for: "song-b") == nil, "nothing left to remember")
    }

    @Test("The store keeps the songs changed last")
    func capacity() {
        let store = LyricsSongStore(fileURL: nil, capacity: 3)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0..<5 {
            store.setManualOffset(0.2, for: "song-\(index)", at: start.addingTimeInterval(Double(index)))
        }
        #expect(store.count == 3)
        #expect(store.entry(for: "song-0") == nil && store.entry(for: "song-4") != nil)
    }

    @Test("An unreadable file starts empty")
    func unreadable() throws {
        let scratch = ScratchDirectory()
        let url = scratch.url.appendingPathComponent("LyricsSongs.json")
        try Data("not json".utf8).write(to: url)
        #expect(LyricsSongStore(fileURL: url).count == 0)
    }

    @Test("The cache keeps lyrics, not misses, and survives a restart")
    func cache() async {
        let scratch = ScratchDirectory()
        let cache = LyricsCache(directory: scratch.url, memoryLimit: 1, diskLimit: 2)
        let response = LyricsResponse(result: .synced(ChainFixtures.synced), source: "LRCLIB")
        await cache.store(response, for: "a")
        await cache.store(.none, for: "b")
        #expect(await cache.load("a") == response)
        #expect(await cache.load("b") == nil)
        let fresh = LyricsCache(directory: scratch.url)
        #expect(await fresh.load("a") == response)
        await cache.store(response, for: "c")
        await cache.store(response, for: "d")
        #expect(await cache.diskCount() <= 2)
        await cache.remove("d")
        #expect(await LyricsCache(directory: scratch.url).load("d") == nil)
    }
}
