import Foundation

/// What the live wallpaper looks up for the playing song, from its
/// snapshot: the song, who sings it (or the name the user typed for that
/// artist), and, when it plays on YouTube Music or YouTube, its own video.
public struct WallpaperRequest: Hashable, Sendable {
    public var title: String
    /// The artist to search with: the player's, or the name the user typed.
    public var artist: String
    /// The artist as the player names it (the key of a typed name).
    public var reportedArtist: String
    public var album: String
    /// Seconds; 0 when unknown.
    public var duration: TimeInterval
    public var source: MusicSource
    public var trackID: String
    public var songVideoKind: SongVideoKind?
    public var contentKind: ContentKind

    public init(snapshot: NowPlayingSnapshot, artistOverride: String? = nil) {
        let track = snapshot.track
        title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        reportedArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = artistOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        artist = typed.isEmpty ? reportedArtist : typed
        album = track.album
        duration = track.duration
        source = track.source
        trackID = track.id
        songVideoKind = snapshot.songVideoKind
        contentKind = snapshot.contentKind
    }

    /// The live wallpaper follows music the light would react to: music, or
    /// a player that does not say (unless it is a video site); never a plain
    /// video, a podcast or an advert.
    public static func follows(_ snapshot: NowPlayingSnapshot) -> Bool {
        AudioCapturePolicy.reactsTo(snapshot)
    }

    /// Picks are remembered per song.
    public var songKey: String {
        WallpaperSongStore.songKey(title: title, artist: reportedArtist)
    }

    /// The song's own video when it plays on YouTube Music or YouTube and is
    /// a real video. YouTube Music plays most songs as "art tracks" (the
    /// cover as a still): there the page must say it is a video (an official
    /// one or an upload). On YouTube a music video page is a video unless
    /// the page calls it an art track.
    public var tabVideo: WallpaperCandidate? {
        guard source == .youtubeMusic || source == .youtube, let id = BrowserSite.youtubeVideoID(trackID) else { return nil }
        switch (source, songVideoKind) {
        case (_, .some(let kind)) where !kind.isMovingPicture:
            return nil
        case (.youtubeMusic, nil):
            return nil
        default:
            return .tabVideo(id: id, title: title, artist: reportedArtist, duration: duration)
        }
    }

    /// The video ID the tab plays, real video or not (never searched for:
    /// an art track's ID is not the song's video).
    public var tabVideoID: String? {
        guard source == .youtubeMusic || source == .youtube else { return nil }
        return BrowserSite.youtubeVideoID(trackID)
    }

    /// Enough to search for: a title and an artist.
    public var isSearchable: Bool {
        !title.isEmpty && !artist.isEmpty
    }

    /// Search terms for the song's own video.
    public var songQuery: String {
        "\(artist) \(Self.plainTitle(title)) official video"
    }

    /// Search terms for other videos by the artist.
    public var artistQuery: String {
        "\(artist) official music video"
    }

    /// The title without bracketed decorations ("(feat. …)", "[Remastered]")
    /// that would narrow a search.
    static func plainTitle(_ title: String) -> String {
        let stripped = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }
}
