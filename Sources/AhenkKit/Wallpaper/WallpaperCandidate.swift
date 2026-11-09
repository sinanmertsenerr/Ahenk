import Foundation

/// One thing the live wallpaper can show for the playing song: the album's
/// motion artwork, the song's own video, another video by the artist, a
/// video from the user's list, the cover itself (blurred and slowly moving)
/// or, in demo mode, Ahenk's generated motion.
///
/// Videos are always streamed while they show: YouTube's embedded player,
/// or AVPlayer for motion artwork, web addresses and the user's files.
/// Nothing is downloaded or kept.
public struct WallpaperCandidate: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// The album's motion artwork from Apple's catalog.
        case motionArtwork
        /// The song's own music video.
        case songVideo
        /// Another video by the same artist.
        case artistVideo
        /// A video from the user's own list.
        case userVideo
        /// The current cover, blurred and slowly moving.
        case artwork
        /// Ahenk's generated motion (demo mode).
        case generated

        /// Moving pictures that are really videos (not drawn by Ahenk).
        public var isVideo: Bool {
            switch self {
            case .motionArtwork, .songVideo, .artistVideo, .userVideo: true
            case .artwork, .generated: false
            }
        }
    }

    public enum Media: Hashable, Sendable {
        /// YouTube's embedded player (privacy-enhanced, muted).
        case youtube(videoID: String)
        /// A video streamed over the network with AVPlayer (HLS or a file
        /// on a web server).
        case stream(URL)
        /// A video file on this Mac.
        case file(URL)
        /// The current cover, blurred and drifting.
        case artwork
        /// Generated motion in one of several looks.
        case generated(look: Int)
    }

    /// Stable for the same thing across lookups ("youtube:<id>",
    /// "motion:<album>", "artwork", …): the user's pick is stored by it.
    public var id: String
    public var kind: Kind
    public var media: Media
    /// The video's title (empty for the cover and the motion artwork).
    public var title: String
    /// Who published it (a video's channel).
    public var channel: String?
    /// Length in seconds, when known.
    public var duration: TimeInterval?

    public init(id: String, kind: Kind, media: Media, title: String = "", channel: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.kind = kind
        self.media = media
        self.title = title
        self.channel = channel
        self.duration = duration
    }

    // MARK: Builders

    public static func youtube(_ video: YouTubeVideo, kind: Kind) -> WallpaperCandidate {
        WallpaperCandidate(
            id: "youtube:\(video.id)", kind: kind, media: .youtube(videoID: video.id), title: video.title,
            channel: video.channel.isEmpty ? nil : video.channel, duration: video.duration
        )
    }

    /// The song's own video when the song plays on YouTube or YouTube Music
    /// (the tab's video, so it plays in step by definition).
    public static func tabVideo(id videoID: String, title: String, artist: String, duration: TimeInterval) -> WallpaperCandidate {
        WallpaperCandidate(
            id: "youtube:\(videoID)", kind: .songVideo, media: .youtube(videoID: videoID), title: title,
            channel: artist.isEmpty ? nil : artist, duration: duration > 0 ? duration : nil
        )
    }

    public static func motion(_ artwork: MotionArtwork, url: URL) -> WallpaperCandidate {
        WallpaperCandidate(id: "motion:\(artwork.albumID)", kind: .motionArtwork, media: .stream(url))
    }

    public static let artwork = WallpaperCandidate(id: "artwork", kind: .artwork, media: .artwork)

    public static func generated(look: Int, kind: Kind, title: String, duration: TimeInterval? = nil) -> WallpaperCandidate {
        WallpaperCandidate(id: "generated:\(look)", kind: kind, media: .generated(look: look), title: title, duration: duration)
    }

    /// A video from the user's list (`nil` for an unusable entry).
    public static func user(_ video: SavedVideo) -> WallpaperCandidate? {
        let media: Media
        switch video.kind {
        case .youtube:
            guard let id = BrowserSite.youtubeVideoID(video.reference) else { return nil }
            media = .youtube(videoID: id)
        case .file:
            let path = (video.reference as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            media = .file(URL(fileURLWithPath: path))
        case .url:
            guard let url = URL(string: video.reference), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false
            else { return nil }
            media = .stream(url)
        }
        return WallpaperCandidate(id: "user:\(video.id)", kind: .userVideo, media: media, title: video.title)
    }

    /// Played by YouTube's embedded player.
    public var isEmbedded: Bool {
        if case .youtube = media { return true }
        return false
    }

    /// Played with AVPlayer (motion artwork, web addresses, files).
    public var playsWithAVPlayer: Bool {
        switch media {
        case .stream, .file: true
        case .youtube, .artwork, .generated: false
        }
    }
}

/// Which source the live wallpaper tries first (Settings › Live Wallpaper).
/// The cover is always the last resort.
public enum WallpaperSourcePreference: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The album's motion artwork, then the song's video, then the artist's.
    case motionArtwork
    /// The song's video, then the artist's, then the motion artwork.
    case musicVideo

    public var id: String { rawValue }
}
