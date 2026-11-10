import Foundation

/// How a wallpaper video runs.
public enum VideoSyncMode: Equatable, Sendable {
    /// Starts at the song's position and stays roughly in step with it.
    case followsSong
    /// Plays on its own, round and round.
    case loops
}

/// Keeping the song's own video in step with the song. The wallpaper is
/// muted: the song plays in its own app, the video only shows. Only the
/// song's own video follows the song, and only when the two are about as
/// long (a music video often adds an intro or an outro; a different cut
/// would never line up); everything else loops.
public enum VideoSync {
    /// Seconds of difference in length still followed (or this share of the
    /// song, if larger).
    public static let lengthTolerance: TimeInterval = 10
    public static let lengthShare = 0.06
    /// Drift that brings a jump. A jump costs a moment of buffering, and
    /// playing faster or slower to close a small gap showed as a hitch at
    /// every change of speed, so anything smaller is left alone: the video
    /// always runs at its own speed.
    public static let driftTolerance: TimeInterval = 1.5
    /// How often a following video is compared with the song.
    public static let checkInterval: TimeInterval = 2
    /// A jump aims this far ahead: the player needs a moment to buffer,
    /// and the song goes on meanwhile.
    public static let jumpLead: TimeInterval = 0.9
    /// After a jump the player is left to settle this long before the next.
    public static let settleTime: TimeInterval = 4

    public static func mode(isSongVideo: Bool, syncEnabled: Bool, songDuration: TimeInterval?, videoDuration: TimeInterval?) -> VideoSyncMode {
        guard isSongVideo, syncEnabled else { return .loops }
        guard let song = songDuration, song > 0, let video = videoDuration, video > 0 else { return .loops }
        return abs(video - song) <= max(lengthTolerance, song * lengthShare) ? .followsSong : .loops
    }

    /// Where a following video starts when the song is at `songPosition`:
    /// a little ahead, by the time the player needs to start (`lead`), and
    /// never past its last seconds.
    public static func startPosition(songPosition: TimeInterval, lead: TimeInterval, videoDuration: TimeInterval?) -> TimeInterval {
        let wanted = max(0, songPosition + max(0, lead))
        guard let videoDuration, videoDuration > 1 else { return wanted }
        return min(wanted, videoDuration - 1)
    }

    /// Where the video should jump to (a little ahead of the song, see
    /// `jumpLead`), or `nil` when it is close enough. Past the video's end
    /// (a longer song), it holds its last moments.
    public static func correction(
        songPosition: TimeInterval, videoPosition: TimeInterval, videoDuration: TimeInterval?, tolerance: TimeInterval = driftTolerance
    ) -> TimeInterval? {
        guard songPosition.isFinite, videoPosition.isFinite else { return nil }
        var target = max(0, songPosition)
        var last = TimeInterval.infinity
        if let videoDuration, videoDuration > 1 {
            guard target < videoDuration - 0.5 else { return nil }
            last = videoDuration - 1
            target = min(target, last)
        }
        guard abs(videoPosition - target) > tolerance else { return nil }
        return min(target + jumpLead, last)
    }
}
