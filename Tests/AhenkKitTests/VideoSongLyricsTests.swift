import Foundation
import Testing
@testable import AhenkKit

// Every title, artist and line here is invented for the tests.

@Suite("A music video's lyrics, asked about as its song")
struct VideoSongLyricsTests {
    @Test("The song's title in a video's")
    func title() {
        let cases: [(title: String, artist: String, song: String)] = [
            ("The Tin Orchard - Paper Lanterns | Official Music Video", "The Tin Orchard", "Paper Lanterns"),
            ("Nova Reed - Glass Harbor (Official Music Video)", "Nova Reed", "Glass Harbor"),
            ("Kite & Marlow - Low Tide (Attic Live 2031)", "Marlow ve Kite", "Low Tide"),
            ("SLOW RIVER - Marlow Ft. Jun Pell (prod. by vexa)", "Marlow", "SLOW RIVER"),
            ("Paper Lanterns Official Video", "The Tin Orchard", "Paper Lanterns"),
            ("Paper Lanterns – Lyric Video", "The Tin Orchard", "Paper Lanterns"),
            ("Paper Lanterns", "The Tin Orchard", "Paper Lanterns"),
            // Neither side is the artist: the dash belongs to the title.
            ("North - South", "The Tin Orchard", "North - South"),
            ("(Official Video)", "The Tin Orchard", ""),
        ]
        for item in cases {
            #expect(LyricsQuery.songTitle(ofVideo: item.title, artist: item.artist) == item.song, "\(item.title)")
        }
    }

    @Test("The names in a credit; the song is asked about with all of them, then with each")
    func artists() {
        #expect(LyricsQuery.artistParts("Jun Pell, Marlow ve Kite") == ["Jun Pell", "Marlow", "Kite"])
        #expect(LyricsQuery.artistParts("Kite & Marlow") == ["Kite", "Marlow"])
        #expect(LyricsQuery.artistParts("Kite x Marlow feat. Jun Pell") == ["Kite", "Marlow", "Jun Pell"])
        #expect(LyricsQuery.artistParts("Velvet Engines") == ["Velvet Engines"], "\"ve\" inside a word is no separator")

        let video = LyricsQuery(title: "The Tin Orchard - Paper Lanterns | Official Music Video", artist: "The Tin Orchard ve Kite", album: "Somewhere", duration: 230)
        let songs = video.songsOfVideo
        #expect(songs.map(\.artist) == ["The Tin Orchard ve Kite", "The Tin Orchard", "Kite"])
        #expect(songs.allSatisfy { $0.title == "Paper Lanterns" && $0.anyLength && $0.duration == 230 && $0.album == nil })
        #expect(songs[0].durationMatches(164) && !video.durationMatches(164), "a video's length is not the song's")
        #expect(songs[0].sanitized.anyLength)
        #expect(LyricsQuery(title: "Paper Lanterns", artist: "The Tin Orchard", duration: 230).songsOfVideo.count == 1)
    }

    @Test("LRCLIB: any length is taken for a video's song, the nearest first")
    func lrclib() async throws {
        let rows = [
            LyricsFixtures.row(id: 7, duration: 164),
            LyricsFixtures.row(id: 8, duration: 233),
        ]
        func fetcher() -> RouteFetcher {
            RouteFetcher([
                ("/api/get", #"{"code":404,"name":"TrackNotFound"}"#, 404),
                ("/api/search", "[\(rows.joined(separator: ","))]", 200),
            ])
        }
        let video = LyricsQuery(title: "Paper Lanterns", artist: "The Tin Orchard", duration: 230)
        #expect(try await LRCLIBProvider(http: fetcher()).fetch(video) == .notFound, "34 s and 3 s away: other recordings")
        let song = try #require(video.songsOfVideo.first)
        guard case .synced = try await LRCLIBProvider(http: fetcher()).fetch(song) else { Issue.record("expected synced"); return }
        let versions = try await LRCLIBProvider(http: fetcher()).versions(for: song)
        #expect(versions.map(\.reference) == ["8", "7"], "the upload nearest the video's length first")
    }

    @Test("The finder asks about the song only after the video's own metadata missed, and proves nothing about the timing")
    func finder() async throws {
        let scratch = ScratchDirectory()
        let provider = ScriptedLyricsProvider("A") { query in
            query.title == "Paper Lanterns" && query.artist == "The Tin Orchard" && query.anyLength
                ? ChainFixtures.response(.synced(ChainFixtures.synced), from: "A", authority: .canonicalRecording) : .none
        }
        let finder = LyricsFinder(chain: LyricsChain(providers: [provider]), cache: LyricsCache(directory: scratch.url), songs: LyricsSongStore(fileURL: nil))
        let video = LyricsQuery(title: "The Tin Orchard - Paper Lanterns | Official Music Video", artist: "The Tin Orchard ve Kite", duration: 230)

        // As any song: nothing, and that is remembered.
        #expect(await finder.find(video).response.result == .notFound)
        #expect(await finder.find(video).origin == .recentMiss)
        // As a video: the miss before does not count; the first artist alone finds it.
        let found = await finder.find(video, otherwise: video.songsOfVideo)
        #expect(found.origin == .providers && found.response.source == "A")
        guard case .synced = found.response.result else { Issue.record("expected synced"); return }
        #expect(found.response.timingAuthority == .unverified, "timed for the album's recording, whatever the provider proved")
        #expect(provider.queries.last?.artist == "The Tin Orchard")
        // Kept under the video's own identity.
        #expect(await finder.find(video, otherwise: video.songsOfVideo).origin == .cache)

        // A video its own metadata finds is not asked about twice.
        let direct = ScriptedLyricsProvider("B") { _ in ChainFixtures.response(.synced(ChainFixtures.synced), from: "B", authority: .providerMatched) }
        let other = LyricsFinder(chain: LyricsChain(providers: [direct]), cache: nil, songs: LyricsSongStore(fileURL: nil))
        let own = await other.find(video, otherwise: video.songsOfVideo)
        #expect(own.response.timingAuthority == .providerMatched && !direct.queries.contains { $0.anyLength })

        // Nothing either way is a miss; unreachable providers are not.
        let empty = ScriptedLyricsProvider("C") { _ in .none }
        let nothing = LyricsFinder(chain: LyricsChain(providers: [empty]), cache: nil, songs: LyricsSongStore(fileURL: nil))
        #expect(await nothing.find(video, otherwise: video.songsOfVideo).origin == .providers)
        #expect(await nothing.find(video, otherwise: video.songsOfVideo).origin == .recentMiss)
        let broken = ScriptedLyricsProvider("D") { _ in throw URLError(.timedOut) }
        let offline = LyricsFinder(chain: LyricsChain(providers: [broken]), cache: nil, songs: LyricsSongStore(fileURL: nil))
        #expect(await offline.find(video, otherwise: video.songsOfVideo).allFailed)
    }

    @Test("What counts as a music video")
    func isMusicVideo() {
        func snapshot(_ source: MusicSource, _ kind: SongVideoKind?) -> NowPlayingSnapshot {
            NowPlayingSnapshot(
                track: Track(id: "x", source: source, title: "Paper Lanterns", artist: "The Tin Orchard", duration: 230),
                elapsedTime: 0, playbackRate: 1, timestamp: Date(timeIntervalSince1970: 0), songVideoKind: kind
            )
        }
        #expect(snapshot(.youtubeMusic, .officialVideo).isMusicVideo && snapshot(.youtubeMusic, .userVideo).isMusicVideo)
        #expect(!snapshot(.youtubeMusic, .artTrack).isMusicVideo, "the album's recording under a still cover")
        #expect(!snapshot(.youtubeMusic, nil).isMusicVideo, "YouTube Music plays most songs as art tracks: the page must say")
        #expect(snapshot(.youtube, nil).isMusicVideo && !snapshot(.youtube, .artTrack).isMusicVideo)
        #expect(!snapshot(.spotify, .officialVideo).isMusicVideo)
    }
}
