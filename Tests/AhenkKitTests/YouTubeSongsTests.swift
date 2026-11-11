import Foundation
import Testing
@testable import AhenkKit

// Invented videos, channels and songs only.

private struct StubVideos: YouTubeVideoSearching {
    var videos: [YouTubeVideo] = []
    var fails = false
    func search(_ query: String) async throws -> [YouTubeVideo] {
        if fails { throw CatalogError.rateLimited }
        return videos
    }
}

private struct StubCatalog: MusicCatalog {
    var results = CatalogSearchResults()
    var fails = false
    func search(_ term: String, limit: Int) async throws -> CatalogSearchResults {
        if fails { throw CatalogError.offline }
        return results
    }
    func artist(for track: Track) async throws -> CatalogArtistMatch? { nil }
    func albums(of artist: CatalogArtist) async throws -> [CatalogAlbum] { [] }
    func songs(of album: CatalogAlbum) async throws -> [CatalogSong] { [] }
    func topSongs(of artist: CatalogArtist, limit: Int) async throws -> [CatalogSong] { [] }
}

@Suite("YouTube's videos in the player's search")
struct YouTubeSongsTests {
    let clip = YouTubeVideo(id: "ahenkMock01", title: "Orchid Telemetry - Velvet Harbor Lights (Official Video)", channel: "Tidal Glass Records", duration: 214)
    let topic = YouTubeVideo(id: "ahenkMock02", title: "Quiet Engines", channel: "Nadia Ferro - Topic", duration: 187, isArtTrack: true)
    let live = YouTubeVideo(id: "ahenkMock03", title: "Saffron Static (Live Now)", channel: "Kestrel & Vale", isLive: true)
    let catalogSong = CatalogSong(id: "itunes:1", title: "Velvet Harbor Lights", artistName: "Orchid Telemetry", albumTitle: "Tidal Glass", duration: 214)
    let artist = CatalogArtist(id: "itunes:artist:9", name: "Orchid Telemetry")
    let album = CatalogAlbum(id: "itunes:album:4", title: "Tidal Glass", artistName: "Orchid Telemetry")

    @Test("A video becomes a song that is opened by its own address")
    func videoAsSong() throws {
        let song = try #require(YouTubeSongs.song(from: clip))
        #expect(song.id == "youtube:ahenkMock01" && YouTubeSongs.isVideo(song))
        #expect(song.title == clip.title && song.artistName == "Tidal Glass Records" && song.duration == 214)
        #expect(song.url?.absoluteString == "https://www.youtube.com/watch?v=ahenkMock01")
        #expect(song.artwork == .remote(URL(string: "https://i.ytimg.com/vi/ahenkMock01/mqdefault.jpg")!))
        // The site is asked for that very video, not for a search by title.
        let asked = BrowserPlaybackPolicy.bridgeSong(song, on: .youtube, spotifyTrackID: nil)
        #expect(asked.trackID == "ahenkMock01" && asked.url == "https://www.youtube.com/watch?v=ahenkMock01")
        // What the tab then reports is recognised as this pick.
        let playing = Track(id: "https://www.youtube.com/watch?v=ahenkMock01", source: .youtube, title: "Another title the site shows", artist: "Somebody")
        #expect(SongMatching.matches(song, playing))
        // On another site the video's ID means nothing: found by title there.
        #expect(BrowserPlaybackPolicy.bridgeSong(song, on: .youtubeMusic, spotifyTrackID: nil).trackID == nil)
    }

    @Test("The channel's decorations are not the artist; a live stream is not a song")
    func channelsAndStreams() throws {
        #expect(try #require(YouTubeSongs.song(from: topic)).artistName == "Nadia Ferro")
        #expect(YouTubeSongs.song(from: live) == nil)
        #expect(YouTubeSongs.song(from: YouTubeVideo(id: "not an id", title: "x", channel: "y")) == nil)
        #expect(!YouTubeSongs.isVideo(catalogSong))
    }

    @Test("Videos are the songs; the catalog's artists and albums stay")
    func merged() {
        let catalog = CatalogSearchResults(songs: [catalogSong], albums: [album], artists: [artist], top: .song(catalogSong))
        let results = YouTubeSongs.results(videos: [clip, live, topic], catalog: catalog)
        #expect(results.songs.map(\.id) == ["youtube:ahenkMock01", "youtube:ahenkMock02"])
        #expect(results.albums == [album] && results.artists == [artist])
        #expect(results.top == .song(results.songs[0]), "the catalog's song is not on top of YouTube's videos")
        // A search for a person keeps the person on top.
        let person = CatalogSearchResults(songs: [catalogSong], artists: [artist], top: .artist(artist))
        #expect(YouTubeSongs.results(videos: [clip], catalog: person).top == .artist(artist))
        #expect(YouTubeSongs.results(videos: [clip, topic], catalog: nil, limit: 1).songs.count == 1)
        #expect(YouTubeSongs.results(videos: [], catalog: nil).isEmpty)
    }

    @Test("Without videos the catalog's results stand; an error only when neither answered")
    func search() async throws {
        let catalog = CatalogSearchResults(songs: [catalogSong], artists: [artist], top: .song(catalogSong))
        let both = try await YouTubeSongs.search("velvet", videos: StubVideos(videos: [clip]), catalog: StubCatalog(results: catalog), limit: 50)
        #expect(both.songs.map(\.id) == ["youtube:ahenkMock01"] && both.artists == [artist])
        // A clip the catalog does not have at all is still found.
        let clipOnly = try await YouTubeSongs.search("velvet", videos: StubVideos(videos: [clip]), catalog: StubCatalog(fails: true), limit: 50)
        #expect(clipOnly.songs.map(\.id) == ["youtube:ahenkMock01"] && clipOnly.artists.isEmpty)
        // YouTube asked to slow down, or knows none: as for any other source.
        let slowed = try await YouTubeSongs.search("velvet", videos: StubVideos(fails: true), catalog: StubCatalog(results: catalog), limit: 50)
        #expect(slowed == catalog)
        let none = try await YouTubeSongs.search("velvet", videos: StubVideos(), catalog: StubCatalog(results: catalog), limit: 50)
        #expect(none == catalog)
        await #expect(throws: CatalogError.offline) {
            try await YouTubeSongs.search("velvet", videos: StubVideos(fails: true), catalog: StubCatalog(fails: true), limit: 50)
        }
    }

    @Test("A clip shows its own picture; a song played over its album cover keeps the cover")
    func clipPictures() {
        func playing(_ source: MusicSource, id: String, kind: SongVideoKind?) -> NowPlayingSnapshot {
            NowPlayingSnapshot(
                track: Track(id: id, source: source, title: "Velvet Harbor Lights", artist: "Orchid Telemetry"),
                elapsedTime: 0, playbackRate: 1, timestamp: .distantPast, contentKind: .music, songVideoKind: kind
            )
        }
        let wide = ["https://i.ytimg.com/vi/ahenkMock01/hq720.jpg", "https://i.ytimg.com/vi/ahenkMock01/mqdefault.jpg"]
        #expect(YouTubeSongs.widePictureURLs(videoID: "ahenkMock01").map(\.absoluteString) == wide)
        #expect(YouTubeSongs.widePictureURLs(videoID: "not an id").isEmpty)
        let clip = playing(.youtubeMusic, id: "https://music.youtube.com/watch?v=ahenkMock01", kind: .officialVideo)
        #expect(YouTubeSongs.clipPictureURLs(for: clip).map(\.absoluteString) == wide)
        #expect(YouTubeSongs.clipPictureURLs(for: playing(.youtube, id: "https://www.youtube.com/watch?v=ahenkMock01", kind: .userVideo)).count == 2)
        // On YouTube itself a video is a clip unless its page calls it a still.
        #expect(YouTubeSongs.clipPictureURLs(for: playing(.youtube, id: "https://www.youtube.com/watch?v=ahenkMock01", kind: nil)).count == 2)
        // The album's cover over the song: the cover stays, and may come larger from the catalog.
        let still = playing(.youtubeMusic, id: "https://music.youtube.com/watch?v=ahenkMock01", kind: .artTrack)
        #expect(YouTubeSongs.clipPictureURLs(for: still).isEmpty)
        #expect(YouTubeSongs.clipPictureURLs(for: playing(.youtubeMusic, id: "https://music.youtube.com/watch?v=ahenkMock01", kind: nil)).isEmpty)
        #expect(YouTubeSongs.clipPictureURLs(for: playing(.spotify, id: "spotify:track:x", kind: nil)).isEmpty)
        #expect(ArtworkPolicy.allowsCatalogLookup(source: .youtubeMusic, kind: .music, isMusicVideo: still.isMusicVideo))
        // The catalog's cover is the song's, not the clip's.
        #expect(!ArtworkPolicy.allowsCatalogLookup(source: .youtubeMusic, kind: .music, isMusicVideo: clip.isMusicVideo))
        #expect(!ArtworkPolicy.allowsCatalogLookup(source: .youtube, kind: .music, isMusicVideo: true))
    }
}
