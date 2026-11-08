import Foundation

/// `com.apple.Music.playerInfo`: posted by Music on every play, pause,
/// stop and song change, to anyone listening (no permission needed). It names
/// the song but carries no position.
public struct AppleMusicPlayerInfo: Sendable, Equatable {
    public var state: NotifiedPlayerState
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; `nil` for streams.
    public var duration: TimeInterval?
    /// Hex, as AppleScript's `persistent ID` spells it.
    public var persistentID: String?

    public init(state: NotifiedPlayerState, title: String = "", artist: String = "", album: String = "", duration: TimeInterval? = nil, persistentID: String? = nil) {
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.persistentID = persistentID
    }

    /// Reads the notification's `userInfo`; `nil` without a player state.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo, let state = NotifiedPlayerState(info["Player State"]) else { return nil }
        self.state = state
        title = info["Name"] as? String ?? info["Display Line 0"] as? String ?? ""
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        if let total = (info["Total Time"] as? NSNumber)?.doubleValue, total > 0 {
            duration = total / 1000
        }
        persistentID = Self.hexPersistentID(info["PersistentID"])
    }

    /// Music sends the persistent ID as a signed 64-bit number; AppleScript
    /// returns the same ID as 16 upper-case hex digits.
    static func hexPersistentID(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text.uppercased() }
        guard let number = value as? NSNumber else { return nil }
        let bits = UInt64(bitPattern: number.int64Value)
        let hex = String(bits, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

/// Apple Music through AppleScript (`tell application id "com.apple.Music"`).
public enum AppleMusicPlayer: ScriptedPlayer {
    public typealias Notification = AppleMusicPlayerInfo

    public static let providerID = "apple-music"
    public static let bundleIdentifier = KnownApps.appleMusic
    public static let source = MusicSource.appleMusic
    public static let capabilities: PlaybackCapabilities = .all
    static let notificationName = "com.apple.Music.playerInfo"

    /// One round trip. Every field that can fail on odd items (streams,
    /// files without artwork) is read in its own `try`.
    public static let readScript = ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: #"{"notrunning"}"#, body: """
    with timeout of 4 seconds
    \ttell application id "com.apple.Music"
    \t\tset playerState to (player state as string)
    \t\tif playerState is "stopped" then return {playerState}
    \t\ttry
    \t\t\tset t to current track
    \t\ton error
    \t\t\treturn {playerState}
    \t\tend try
    \t\tset pos to missing value
    \t\ttry
    \t\t\tset pos to player position
    \t\tend try
    \t\tset dur to missing value
    \t\ttry
    \t\t\tset dur to duration of t
    \t\tend try
    \t\tset pid to ""
    \t\ttry
    \t\t\tset pid to persistent ID of t
    \t\tend try
    \t\tset fav to missing value
    \t\ttry
    \t\t\tset fav to favorited of t
    \t\tend try
    \t\tset artCount to 0
    \t\ttry
    \t\t\tset artCount to count of artworks of t
    \t\tend try
    \t\treturn {playerState, pos, name of t, artist of t, album of t, dur, pid, shuffle enabled, (song repeat as string), fav, artCount}
    \tend tell
    end timeout
    """)

    public static let artworkScript: String? = ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: "missing value", body: """
    with timeout of 6 seconds
    \ttell application id "com.apple.Music"
    \t\ttry
    \t\t\treturn raw data of artwork 1 of current track
    \t\ton error
    \t\t\treturn missing value
    \t\tend try
    \tend tell
    end timeout
    """)

    public static func parse(_ value: ScriptValue, sampledAt: Date) -> ScriptedReading {
        guard let items = value.list, let state = items.first?.text else { return .unreadable }
        // "notrunning": the app quit just before the script ran.
        if state == "stopped" || state == "notrunning" || items.count == 1 { return .stopped }
        guard items.count >= 11 else { return .unreadable }
        let title = items[2].text ?? ""
        let artist = items[3].text ?? ""
        let album = items[4].text ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return .stopped }
        let persistentID = items[6].text.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let playing = state == "playing" || state == "fast forwarding" || state == "rewinding"
        let position = items[1].number
        let repeatMode: RepeatMode? = switch items[8].text {
        case "off": .off
        case "one": .one
        case "all": .all
        default: nil
        }
        let snapshot = NowPlayingSnapshot(
            track: Track(
                id: persistentID.map { "music:\($0)" } ?? TrackMatching.metadataKey(title: title, artist: artist, album: album),
                source: .appleMusic,
                title: title,
                artist: artist,
                album: album,
                duration: items[5].number ?? 0
            ),
            elapsedTime: max(0, position ?? 0),
            playbackRate: playing ? 1 : 0,
            timestamp: sampledAt,
            isPositionKnown: position != nil,
            isShuffled: items[7].boolean,
            repeatMode: repeatMode,
            isLiked: items[9].boolean,
            contentKind: .music
        )
        return .track(snapshot, hasArtwork: (items[10].number ?? 0) > 0)
    }

    public static func script(for command: PlaybackCommand) -> String? {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        // Like Music's own button: back to the start, or to the previous
        // song when already at the start.
        case .previous: verb = "back track"
        case .seek(let seconds):
            guard seconds.isFinite else { return nil }
            verb = "set player position to \(ScriptFormatting.number(max(0, seconds)))"
        case .setShuffle(let on): verb = "set shuffle enabled to \(on)"
        case .setRepeat(let mode): verb = "set song repeat to \(mode.rawValue)"
        case .setLiked(let liked): verb = "set favorited of current track to \(liked)"
        }
        return ScriptFormatting.command(verb, bundleIdentifier: bundleIdentifier)
    }

    public static func outcome(of info: AppleMusicPlayerInfo, current: NowPlayingSnapshot?, now: Date) -> NotificationOutcome {
        guard info.state != .stopped else { return .stopped }
        guard !info.title.isEmpty || !info.artist.isEmpty else { return .ignore }
        let track = Track(
            id: info.persistentID.map { "music:\($0)" } ?? TrackMatching.metadataKey(title: info.title, artist: info.artist, album: info.album),
            source: .appleMusic,
            title: info.title,
            artist: info.artist,
            album: info.album,
            duration: info.duration ?? 0
        )
        let playing = info.state == .playing
        var snapshot: NowPlayingSnapshot
        if var current, current.track.isSameSong(as: track) {
            // Same song: keep the position reached so far.
            current.setPlaying(playing, at: now)
            current.track = track
            snapshot = current
        } else {
            // A new song starts from the top; a paused one is somewhere
            // unknown until the next read.
            snapshot = NowPlayingSnapshot(
                track: track,
                elapsedTime: 0,
                playbackRate: playing ? 1 : 0,
                timestamp: now,
                isPositionKnown: playing,
                contentKind: .music
            )
        }
        return .snapshot(snapshot)
    }
}

/// Helpers for building AppleScript source.
enum ScriptFormatting {
    /// A decimal number AppleScript reads the same in every locale.
    static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Runs `body` only while the app runs. `tell application` launches an
    /// app that is not running; this check, made by AppleScript right before
    /// the first event, never does. It closes the gap between the
    /// provider's own check and the moment the queued script runs.
    static func ifRunning(bundleIdentifier: String, otherwise: String, body: String) -> String {
        let indented = body.split(separator: "\n", omittingEmptySubsequences: false).map { "\t" + $0 }.joined(separator: "\n")
        return """
        if application id "\(bundleIdentifier)" is running then
        \(indented)
        else
        \treturn \(otherwise)
        end if
        """
    }

    /// One command to an app, bounded in time, only while it runs.
    static func command(_ verb: String, bundleIdentifier: String) -> String {
        ifRunning(bundleIdentifier: bundleIdentifier, otherwise: "missing value", body: """
        with timeout of 4 seconds
        \ttell application id "\(bundleIdentifier)" to \(verb)
        end timeout
        """)
    }
}
