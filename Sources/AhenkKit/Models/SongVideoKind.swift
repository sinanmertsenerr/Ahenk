import Foundation

/// What the video of a YouTube or YouTube Music song shows, from the page's
/// own `musicVideoType` (the browser extension reports it). An "art track"
/// is the album cover as a still picture over the song: it plays as a
/// video on the site but is not one worth showing as a live wallpaper.
public enum SongVideoKind: String, Codable, Sendable, CaseIterable {
    /// An official music video (`MUSIC_VIDEO_TYPE_OMV`).
    case officialVideo
    /// A video somebody uploaded (`MUSIC_VIDEO_TYPE_UGC`).
    case userVideo
    /// The cover as a still picture (`MUSIC_VIDEO_TYPE_ATV`, a privately
    /// owned upload, a YouTube "- Topic" channel's upload).
    case artTrack
    /// Anything else: a podcast episode, a type YouTube adds later.
    case other

    /// The kind for one of YouTube's `MUSIC_VIDEO_TYPE_…` values; `nil`
    /// when the page named none.
    public init?(youTubeType raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "MUSIC_VIDEO_TYPE_OMV": self = .officialVideo
        case "MUSIC_VIDEO_TYPE_UGC": self = .userVideo
        case "MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK": self = .artTrack
        default: self = .other
        }
    }

    /// Moving pictures: worth showing as the song's own video.
    public var isMovingPicture: Bool {
        self == .officialVideo || self == .userVideo
    }
}
