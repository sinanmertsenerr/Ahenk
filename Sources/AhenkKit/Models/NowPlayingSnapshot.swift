import Foundation

public enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one
}

/// An immutable sample of what one provider is playing.
///
/// `elapsedTime` is the position **at `timestamp`**; call ``elapsed(at:)`` for
/// the live position so lyrics and the progress bar stay in time without
/// polling the source.
public struct NowPlayingSnapshot: Hashable, Sendable {
    public var track: Track
    /// The app that plays the song (a browser for web sources), when known.
    public var bundleIdentifier: String?
    /// Position in seconds, valid at `timestamp`.
    public var elapsedTime: TimeInterval
    /// 0 while paused, 1 at normal speed.
    public var playbackRate: Double
    /// When `elapsedTime` was sampled.
    public var timestamp: Date
    /// `nil` when the source does not report it.
    public var isShuffled: Bool?
    public var repeatMode: RepeatMode?
    public var isLiked: Bool?

    public init(
        track: Track,
        bundleIdentifier: String? = nil,
        elapsedTime: TimeInterval,
        playbackRate: Double,
        timestamp: Date,
        isShuffled: Bool? = nil,
        repeatMode: RepeatMode? = nil,
        isLiked: Bool? = nil
    ) {
        self.track = track
        self.bundleIdentifier = bundleIdentifier
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.timestamp = timestamp
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
        self.isLiked = isLiked
    }

    public var isPlaying: Bool { playbackRate != 0 }

    /// Interpolated position at `now`, clamped to `0...duration`.
    public func elapsed(at now: Date) -> TimeInterval {
        let projected = isPlaying
            ? elapsedTime + now.timeIntervalSince(timestamp) * playbackRate
            : elapsedTime
        let lower = max(0, projected)
        return track.duration > 0 ? min(track.duration, lower) : lower
    }

    /// Progress in `0...1` at `now`; 0 when the duration is unknown.
    public func progress(at now: Date) -> Double {
        guard track.duration > 0 else { return 0 }
        return min(1, max(0, elapsed(at: now) / track.duration))
    }

    /// True when both snapshots describe the same song, so artwork and lyrics
    /// can be kept and only the position updated.
    public func isSameTrack(as other: NowPlayingSnapshot) -> Bool {
        track.source == other.track.source && track.id == other.track.id
    }
}
