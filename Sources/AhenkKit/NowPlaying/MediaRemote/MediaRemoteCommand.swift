import Foundation

/// MediaRemote transport commands, by the adapter's `send COMMAND` ids.
/// Sending stays open after macOS 15.4 (only reading was restricted).
public enum MediaRemoteCommand: Int, Sendable, CaseIterable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
    case toggleShuffle = 6
    case toggleRepeat = 7
    case goBackFifteenSeconds = 12
    case skipFifteenSeconds = 13
    case likeTrack = 0x6A
    case banTrack = 0x6B
}

/// One invocation of the adapter for a playback command. MediaRemote
/// commands go to whichever app currently owns the system's Now Playing.
public enum MediaRemoteRequest: Hashable, Sendable {
    case send(MediaRemoteCommand)
    /// Absolute position in microseconds.
    case seek(microseconds: Int64)
    /// 1 off, 2 albums, 3 tracks.
    case shuffle(mode: Int)
    /// 1 off, 2 one track, 3 all.
    case repeatMode(mode: Int)

    /// The adapter's command-line arguments (after the script and framework).
    public var arguments: [String] {
        switch self {
        case .send(let command): ["send", String(command.rawValue)]
        case .seek(let micros): ["seek", String(micros)]
        case .shuffle(let mode): ["shuffle", String(mode)]
        case .repeatMode(let mode): ["repeat", String(mode)]
        }
    }

    /// The request for `command`, or `nil` when MediaRemote cannot express
    /// it (unliking: MediaRemote only knows like and ban).
    public init?(_ command: PlaybackCommand) {
        switch command {
        case .play: self = .send(.play)
        case .pause: self = .send(.pause)
        case .togglePlayPause: self = .send(.togglePlayPause)
        case .next: self = .send(.nextTrack)
        case .previous: self = .send(.previousTrack)
        case .seek(let seconds):
            guard seconds.isFinite else { return nil }
            self = .seek(microseconds: Int64((max(0, seconds) * 1_000_000).rounded()))
        case .setShuffle(let on): self = .shuffle(mode: on ? 3 : 1)
        case .setRepeat(let mode):
            switch mode {
            case .off: self = .repeatMode(mode: 1)
            case .one: self = .repeatMode(mode: 2)
            case .all: self = .repeatMode(mode: 3)
            }
        case .setLiked(true): self = .send(.likeTrack)
        case .setLiked(false): return nil
        }
    }
}
