import Foundation

/// "Start every song at 0:15": when a new song starts, jump over its intro,
/// but only where that makes sense. Never for a song Ahenk found already
/// playing, a song that is past its first seconds (the user moved it), a
/// short song, an advert, a video or a podcast, a source that cannot seek,
/// or the same song again (repeat).
public enum IntroSkipPolicy {
    public static let target: TimeInterval = 15
    /// Shorter songs play from the top.
    public static let minimumDuration: TimeInterval = 60
    /// Only songs that have just started.
    public static let latestStartPosition: TimeInterval = 5

    public static func shouldSkip(
        to current: NowPlayingSnapshot,
        previous: NowPlayingSnapshot?,
        lastSkipped: Track?,
        now: Date
    ) -> Bool {
        guard current.isPlaying, current.isPositionKnown, current.contentKind == .music,
              current.capabilities.contains(.seek)
        else { return false }
        guard current.track.duration >= minimumDuration else { return false }
        guard current.elapsed(at: now) < latestStartPosition else { return false }
        if let previous, previous.isSameTrack(as: current) { return false }
        if let lastSkipped, lastSkipped.isSameSong(as: current.track) { return false }
        return true
    }
}
