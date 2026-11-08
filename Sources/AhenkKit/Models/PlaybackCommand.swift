import Foundation

/// A transport command the hub routes to the provider that owns the song.
public enum PlaybackCommand: Hashable, Sendable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    /// Absolute position in seconds.
    case seek(to: TimeInterval)
    case setShuffle(Bool)
    case setRepeat(RepeatMode)
    case setLiked(Bool)
}
