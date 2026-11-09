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
    /// Drift that brings a seek (seeking costs a moment of buffering, so
    /// small drift is left alone).
    public static let driftTolerance: TimeInterval = 1.2
    /// How often a following video is compared with the song.
    public static let checkInterval: TimeInterval = 4

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

    /// Where the video should jump to, or `nil` when it is close enough.
    /// Past the video's end (a longer song), it holds its last moments.
    public static func correction(
        songPosition: TimeInterval, videoPosition: TimeInterval, videoDuration: TimeInterval?, tolerance: TimeInterval = driftTolerance
    ) -> TimeInterval? {
        guard songPosition.isFinite, videoPosition.isFinite else { return nil }
        var target = max(0, songPosition)
        if let videoDuration, videoDuration > 1 {
            guard target < videoDuration - 0.5 else { return nil }
            target = min(target, videoDuration - 1)
        }
        return abs(videoPosition - target) > tolerance ? target : nil
    }
}
