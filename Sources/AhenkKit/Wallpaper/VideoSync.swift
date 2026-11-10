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
    public static let checkInterval: TimeInterval = 2

    /// What brings a following video back in step.
    public enum Step: Equatable, Sendable {
        /// Close enough: normal speed.
        case hold
        /// A little off: play faster or slower until it has caught up (no
        /// jump, nothing to buffer).
        case rate(Double)
        /// Far off (a seek in the song, a stall): jump there.
        case jump(TimeInterval)
    }

    /// Drift that starts a catch-up, and the drift at which it ends.
    public static let catchUpStart: TimeInterval = 0.35
    public static let catchUpEnd: TimeInterval = 0.12
    /// Beyond this a catch-up would take too long: jump.
    public static let jumpBeyond: TimeInterval = 3
    /// A jump aims this far ahead: the player needs a moment to buffer,
    /// and the song goes on meanwhile.
    public static let jumpLead: TimeInterval = 0.9
    /// The speeds YouTube's player has next to normal.
    public static let fast = 1.25
    public static let slow = 0.75

    /// The step for a video at `videoPosition` while the song is at
    /// `songPosition`; `catchingUp` says a faster or slower speed is on.
    public static func step(
        songPosition: TimeInterval, videoPosition: TimeInterval, videoDuration: TimeInterval?, catchingUp: Bool
    ) -> Step {
        guard songPosition.isFinite, videoPosition.isFinite else { return .hold }
        var target = max(0, songPosition)
        if let videoDuration, videoDuration > 1 {
            // Past the video's end (a longer song) it holds its last moments.
            guard target < videoDuration - 0.5 else { return .hold }
            target = min(target, videoDuration - 1)
        }
        let drift = videoPosition - target
        let size = abs(drift)
        if size > jumpBeyond {
            var landing = target + jumpLead
            if let videoDuration, videoDuration > 1 { landing = min(landing, videoDuration - 1) }
            return .jump(landing)
        }
        if size > catchUpStart || (catchingUp && size > catchUpEnd) {
            return .rate(drift < 0 ? fast : slow)
        }
        return .hold
    }

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
