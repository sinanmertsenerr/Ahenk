import Foundation

/// Finds videos on YouTube for a typed search (`YouTubeVideoSearch`; a
/// stand-in in tests).
public protocol YouTubeVideoSearching: Sendable {
    /// Videos for `query`, in YouTube's order.
    func search(_ query: String) async throws -> [YouTubeVideo]
}

extension YouTubeVideoSearch: YouTubeVideoSearching {}

/// YouTube's videos as songs of the desktop player: what its search lists
/// while YouTube is where picks play (a clip Apple's catalog does not have
/// is found, and a pick opens that very video), and the picture a clip
/// shows while it plays.
public enum YouTubeSongs {
    /// `youtube:<video ID>`.
    public static let idPrefix = "youtube:"

    /// A song that is a video found on YouTube (not a catalog song).
    public static func isVideo(_ song: CatalogSong) -> Bool {
        song.id.hasPrefix(idPrefix)
    }

    /// The video as a song of the player: its uploader as the artist
    /// (without YouTube's channel decorations), its own picture as the
    /// cover, and the watch address as the ID a pick is opened by. Live
    /// streams are not songs (`nil`).
    public static func song(from video: YouTubeVideo) -> CatalogSong? {
        guard !video.isLive, BrowserSite.youtubeVideoID(video.id) == video.id,
              let watch = BrowserSite.youtube.watchURL(videoID: video.id)
        else { return nil }
        let artist = WebSiteInference.cleanedYouTubeArtist(video.channel.trimmingCharacters(in: .whitespacesAndNewlines))
        let picture = thumbnailURL(videoID: video.id)
        let duration = video.duration ?? 0
        let track = Track(
            id: watch.absoluteString, source: .youtube, title: video.title, artist: artist,
            duration: duration, artworkURL: picture
        )
        return CatalogSong(
            id: idPrefix + video.id, title: video.title, artistName: artist, duration: duration,
            artwork: picture.map { .remote($0) }, url: watch, origin: track
        )
    }

    /// The video's own picture (320×180; every video has one).
    public static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    /// A video's picture as wide as the video, largest first: 1280×720 where
    /// YouTube made one, else the 320×180 every video has. (The sizes
    /// between are 4:3 with black bars.)
    public static func widePictureURLs(videoID: String) -> [URL] {
        guard BrowserSite.youtubeVideoID(videoID) == videoID else { return [] }
        return ["hq720", "mqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(videoID)/\($0).jpg") }
    }

    /// The pictures of the clip that plays (`widePictureURLs`), or none: a
    /// song on another source, or one YouTube plays over its album cover.
    /// A clip is its own recording with its own picture; the album's cover
    /// belongs to the song, not to it.
    public static func clipPictureURLs(for snapshot: NowPlayingSnapshot) -> [URL] {
        guard snapshot.isMusicVideo, let id = BrowserSite.youtubeVideoID(snapshot.track.id) else { return [] }
        return widePictureURLs(videoID: id)
    }

    /// The videos as the songs beside the catalog's artists and albums
    /// (`SourceSearch.results`).
    public static func results(videos: [YouTubeVideo], catalog: CatalogSearchResults?, limit: Int = 50) -> CatalogSearchResults {
        SourceSearch.results(songs: videos.compactMap(song(from:)), catalog: catalog, limit: limit)
    }

    /// YouTube and the catalog asked at once (`SourceSearch.search`).
    public static func search(
        _ term: String, videos: any YouTubeVideoSearching, catalog: any MusicCatalog, limit: Int
    ) async throws -> CatalogSearchResults {
        try await SourceSearch.search(term, in: YouTubeSongSearch(videos: videos), catalog: catalog, limit: limit)
    }
}
