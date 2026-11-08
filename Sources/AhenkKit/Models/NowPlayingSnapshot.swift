import Foundation

public enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one
}

/// What kind of thing plays. The light, the lyrics and "start every song at
/// 0:15" act on music only; a plain video or an advert must not move them.
public enum ContentKind: String, CaseIterable, Codable, Sendable {
    case music
    case video
    /// Podcasts, audiobooks and other spoken word.
    case podcast
    case advertisement
    /// The source does not say and nothing hints either way.
    case unknown

    public var isMusic: Bool { self == .music }
}

/// The commands a source accepts for its current song, so the UI shows only
/// controls that work and the hub routes each command to a provider that can
/// carry it out.
public struct PlaybackCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Play, pause and toggle.
    public static let playPause = PlaybackCapabilities(rawValue: 1 << 0)
    /// Next and previous.
    public static let skip = PlaybackCapabilities(rawValue: 1 << 1)
    public static let seek = PlaybackCapabilities(rawValue: 1 << 2)
    public static let shuffle = PlaybackCapabilities(rawValue: 1 << 3)
    /// Repeat off and repeat all.
    public static let repeatAll = PlaybackCapabilities(rawValue: 1 << 4)
    public static let repeatOne = PlaybackCapabilities(rawValue: 1 << 5)
    public static let like = PlaybackCapabilities(rawValue: 1 << 6)
    public static let unlike = PlaybackCapabilities(rawValue: 1 << 7)

    public static let transport: PlaybackCapabilities = [.playPause, .skip, .seek]
    public static let all: PlaybackCapabilities = [.transport, .shuffle, .repeatAll, .repeatOne, .like, .unlike]

    public func supports(_ command: PlaybackCommand) -> Bool {
        switch command {
        case .play, .pause, .togglePlayPause: contains(.playPause)
        case .next, .previous: contains(.skip)
        case .seek: contains(.seek)
        case .setShuffle: contains(.shuffle)
        case .setRepeat(.one): contains(.repeatOne)
        case .setRepeat: contains(.repeatAll)
        case .setLiked(true): contains(.like)
        case .setLiked(false): contains(.unlike)
        }
    }
}

/// An immutable sample of what one provider is playing.
///
/// `elapsedTime` is the position **at `timestamp`**; call ``elapsed(at:)`` for
/// the live position so lyrics and the progress bar stay in time without
/// polling the source.
public struct NowPlayingSnapshot: Hashable, Sendable {
    public var track: Track
    /// The app that plays the song: the music app itself, or the browser for
    /// web sources. The audio engine taps this app's processes.
    public var bundleIdentifier: String?
    /// The process that published the song, when known (it can be a helper
    /// of `bundleIdentifier`, e.g. WebKit's GPU process for Safari).
    public var processIdentifier: Int32?
    /// Tells several players of one app apart (browser tabs, Step 7).
    public var instanceIdentifier: String?
    /// Position in seconds, valid at `timestamp`.
    public var elapsedTime: TimeInterval
    /// 0 while paused, 1 at normal speed.
    public var playbackRate: Double
    /// When `elapsedTime` was sampled.
    public var timestamp: Date
    /// False when the source did not report a position (a notification
    /// without one); `elapsedTime` is then only a guess.
    public var isPositionKnown: Bool
    /// `nil` when the source does not report it.
    public var isShuffled: Bool?
    public var repeatMode: RepeatMode?
    public var isLiked: Bool?
    public var capabilities: PlaybackCapabilities
    public var contentKind: ContentKind
    /// Cover bytes handed over by the source (the system's Now Playing
    /// artwork, Apple Music's embedded artwork). Sources with a cover URL use
    /// `track.artworkURL` instead.
    public var artworkData: Data?
    /// Stable identity of `artworkData`, when the source has one.
    public var artworkIdentifier: String?

    public init(
        track: Track,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        instanceIdentifier: String? = nil,
        elapsedTime: TimeInterval,
        playbackRate: Double,
        timestamp: Date,
        isPositionKnown: Bool = true,
        isShuffled: Bool? = nil,
        repeatMode: RepeatMode? = nil,
        isLiked: Bool? = nil,
        capabilities: PlaybackCapabilities = [],
        contentKind: ContentKind = .unknown,
        artworkData: Data? = nil,
        artworkIdentifier: String? = nil
    ) {
        self.track = track
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.instanceIdentifier = instanceIdentifier
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.timestamp = timestamp
        self.isPositionKnown = isPositionKnown
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
        self.isLiked = isLiked
        self.capabilities = capabilities
        self.contentKind = contentKind
        self.artworkData = artworkData
        self.artworkIdentifier = artworkIdentifier
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
    /// can be kept and only the position updated. Two providers may name one
    /// song differently (a persistent ID and a metadata key), so this falls
    /// back to comparing the metadata (see ``Track/isSameSong(as:)``).
    public func isSameTrack(as other: NowPlayingSnapshot) -> Bool {
        track.isSameSong(as: other.track)
    }

    /// Re-anchors the position at `now` and sets the play state, keeping the
    /// position reached so far.
    public mutating func setPlaying(_ playing: Bool, at now: Date) {
        elapsedTime = elapsed(at: now)
        timestamp = now
        playbackRate = playing ? (playbackRate > 0 ? playbackRate : 1) : 0
    }

    /// True when the change from `other` is worth telling the UI: another
    /// song or metadata, play state, shuffle, repeat, like, artwork, the
    /// commands, or a jump in position beyond `tolerance` (a seek). Steady
    /// playback re-sampled by a poll is not a change: views interpolate.
    public func differsNoticeably(from other: NowPlayingSnapshot, at now: Date, tolerance: TimeInterval = 0.5) -> Bool {
        if track != other.track || bundleIdentifier != other.bundleIdentifier
            || processIdentifier != other.processIdentifier || instanceIdentifier != other.instanceIdentifier {
            return true
        }
        if isPlaying != other.isPlaying || playbackRate != other.playbackRate || isPositionKnown != other.isPositionKnown {
            return true
        }
        if isShuffled != other.isShuffled || repeatMode != other.repeatMode || isLiked != other.isLiked {
            return true
        }
        if capabilities != other.capabilities || contentKind != other.contentKind {
            return true
        }
        if artworkIdentifier != other.artworkIdentifier || artworkData != other.artworkData {
            return true
        }
        return abs(elapsed(at: now) - other.elapsed(at: now)) > tolerance
    }
}
