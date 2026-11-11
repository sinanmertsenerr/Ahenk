import Foundation
import Testing
@testable import AhenkKit

// Invented songs, artists and IDs only.

private struct TableReader: SpotifySearchPageReading {
    var rows: [SpotifySearchRow]?
    func rows(for url: URL) async -> [SpotifySearchRow]? { rows }
}

@Suite("A source's own search")
struct SourceSongSearchTests {
    @Test("Spotify's rows are songs with their track ID, album, length and a large cover")
    func spotify() async throws {
        let json = """
        {"rows": [
          {"id": "4uLU6hMCjMI75M1A2tKUQC", "title": " Velvet Harbor Lights ", "artists": ["Orchid Telemetry", "Nadia Ferro"], "album": "Tidal Glass", "duration": 214,
           "artwork": "https://i.scdn.co/image/ab67616d00004851aabbccddeeff00112233445566"},
          {"id": "1301WleyT98MSxVHPZCA6M", "title": "Quiet Engines", "artists": [], "album": "", "duration": null, "artwork": "data:image/png;base64,xx"},
          {"id": "short", "title": "Not a track"}
        ]}
        """
        let rows = try #require(SpotifySearchPage.rows(fromJSON: json))
        #expect(rows.count == 2)
        #expect(rows[0] == SpotifySearchRow(
            id: "4uLU6hMCjMI75M1A2tKUQC", title: "Velvet Harbor Lights", artists: ["Orchid Telemetry", "Nadia Ferro"], album: "Tidal Glass",
            duration: 214, artworkURL: "https://i.scdn.co/image/ab67616d00004851aabbccddeeff00112233445566"
        ))
        #expect(rows[1] == SpotifySearchRow(id: "1301WleyT98MSxVHPZCA6M", title: "Quiet Engines", artists: []))

        let songs = try await SpotifySongSearch(reader: TableReader(rows: rows), source: .spotify).songs("velvet harbor", limit: 50)
        let song = try #require(songs.first)
        #expect(song.id == "spotify:track:4uLU6hMCjMI75M1A2tKUQC" && song.artistName == "Orchid Telemetry, Nadia Ferro")
        #expect(song.albumTitle == "Tidal Glass" && song.duration == 214)
        #expect(song.artwork == .remote(URL(string: "https://i.scdn.co/image/ab67616d0000b273aabbccddeeff00112233445566")!))
        // The pick is that very track, in the app and in the web player.
        #expect(song.originID(in: .spotify) == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        let web = SpotifySongSearch.song(from: rows[0], source: .spotifyWeb)
        #expect(BrowserPlaybackPolicy.bridgeSong(web, on: .spotifyWeb, spotifyTrackID: nil).trackID == "4uLU6hMCjMI75M1A2tKUQC")
        // A page that could not be read is an error (the catalog's results stand); no words, no search.
        await #expect(throws: CatalogError.offline) { try await SpotifySongSearch(reader: TableReader(rows: nil), source: .spotify).songs("velvet", limit: 50) }
        #expect(try await SpotifySongSearch(reader: TableReader(rows: rows), source: .spotify).songs("  ", limit: 50).isEmpty)
        #expect(SpotifySearchPage.url(forTerm: "Kıyıdan Sesler & co")?.absoluteString == "https://open.spotify.com/search/K%C4%B1y%C4%B1dan%20Sesler%20%26%20co/tracks")
        // Only Spotify's covers are resized.
        let other = URL(string: "https://example.com/image/ab67616d00004851aabb")!
        #expect(SpotifySearchPage.largeCover(of: other) == other)
    }

    @Test("A YouTube Music entry is a song opened by its own address there")
    func youtubeMusic() throws {
        let entry = YouTubeMusicEntry(id: "ahenkMock01", title: "Velvet Harbor Lights", artists: ["Orchid Telemetry", "Nadia Ferro"], duration: 214, kind: .artTrack)
        let song = try #require(YouTubeMusicSongSearch.song(from: entry))
        #expect(song.id == "youtubeMusic:ahenkMock01" && song.artistName == "Orchid Telemetry, Nadia Ferro" && song.duration == 214)
        #expect(!YouTubeSongs.isVideo(song), "a song, not one of YouTube's videos")
        let asked = BrowserPlaybackPolicy.bridgeSong(song, on: .youtubeMusic, spotifyTrackID: nil)
        #expect(asked.trackID == "ahenkMock01" && asked.url == "https://music.youtube.com/watch?v=ahenkMock01")
        #expect(YouTubeMusicSongSearch.song(from: YouTubeMusicEntry(id: "bad", title: "x", artists: [], duration: nil, kind: .userUpload)) == nil)
    }

    @Test("Deezer's answer is read; its error object is not an answer")
    func deezer() throws {
        let answer = """
        {"data": [
          {"id": 3769517842, "title": "Velvet Harbor Lights", "duration": 214, "explicit_lyrics": true, "link": "https://www.deezer.com/track/3769517842",
           "artist": {"name": "Orchid Telemetry"}, "album": {"title": "Tidal Glass", "cover_big": "https://cdn-images.dzcdn.net/images/cover/abc/500x500-000000-80-0-0.jpg"}},
          {"id": 12, "title": "  "}
        ], "total": 2}
        """
        let songs = try #require(DeezerSongSearch.songs(from: Data(answer.utf8)))
        #expect(songs.count == 1)
        let song = songs[0]
        #expect(song.id == "deezer:3769517842" && song.title == "Velvet Harbor Lights" && song.artistName == "Orchid Telemetry")
        #expect(song.albumTitle == "Tidal Glass" && song.duration == 214 && song.isExplicit)
        #expect(song.origin?.source == .deezer && song.origin?.id == "https://www.deezer.com/track/3769517842")
        #expect(BrowserPlaybackPolicy.bridgeSong(song, on: .deezer, spotifyTrackID: nil).url == "https://www.deezer.com/track/3769517842")
        #expect(DeezerSongSearch.songs(from: Data(#"{"error": {"type": "Exception", "code": 4}}"#.utf8)) == nil)
        #expect(DeezerSongSearch.url(forTerm: "velvet harbor", limit: 500)?.absoluteString == "https://api.deezer.com/search?q=velvet%20harbor&limit=50")
    }
}
