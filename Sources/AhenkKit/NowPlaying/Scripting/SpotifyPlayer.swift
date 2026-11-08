import Foundation

/// `com.spotify.client.PlaybackStateChanged`: posted by Spotify on every
/// play, pause and song change, to anyone listening (no permission needed).
/// Carries the position, so it is a complete update without Automation.
public struct SpotifyPlaybackEvent: Sendable, Equatable {
    public var state: NotifiedPlayerState
    /// `spotify:track:…`, `spotify:episode:…`, `spotify:ad:…`, `spotify:local:…`.
    public var trackID: String?
    /// Seconds.
    public var position: TimeInterval?
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds.
    public var duration: TimeInterval?

    public init(state: NotifiedPlayerState, trackID: String? = nil, position: TimeInterval? = nil, title: String = "", artist: String = "", album: String = "", duration: TimeInterval? = nil) {
        self.state = state
        self.trackID = trackID
        self.position = position
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo, let state = NotifiedPlayerState(info["Player State"]) else { return nil }
        self.state = state
        trackID = (info["Track ID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        position = (info["Playback Position"] as? NSNumber)?.doubleValue
        title = info["Name"] as? String ?? ""
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        if let milliseconds = (info["Duration"] as? NSNumber)?.doubleValue, milliseconds > 0 {
            duration = milliseconds / 1000
        }
    }
}

/// The Spotify app through AppleScript (`tell application id
/// "com.spotify.client"`). Spotify's dictionary has no like command and only
/// an on/off repeat.
public enum SpotifyPlayer: ScriptedPlayer {
    public typealias Notification = SpotifyPlaybackEvent

    public static let providerID = "spotify"
    public static let bundleIdentifier = KnownApps.spotify
    public static let source = MusicSource.spotify
    public static let capabilities: PlaybackCapabilities = [.transport, .shuffle, .repeatAll]
    static let notificationName = "com.spotify.client.PlaybackStateChanged"

    /// One round trip. Spotify reports durations in milliseconds.
    public static let readScript = ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: #"{"notrunning"}"#, body: """
    with timeout of 4 seconds
    \ttell application id "com.spotify.client"
    \t\tset playerState to (player state as string)
    \t\tif playerState is "stopped" then return {playerState}
    \t\tset t to current track
    \t\tset artURL to ""
    \t\ttry
    \t\t\tset artURL to artwork url of t
    \t\tend try
    \t\treturn {playerState, player position, name of t, artist of t, album of t, duration of t, id of t, artURL, shuffling, repeating}
    \tend tell
    end timeout
    """)

    public static let artworkScript: String? = nil

    public static func parse(_ value: ScriptValue, sampledAt: Date) -> ScriptedReading {
        guard let items = value.list, let state = items.first?.text else { return .unreadable }
        // "notrunning": the app quit just before the script ran.
        if state == "stopped" || state == "notrunning" || items.count == 1 { return .stopped }
        guard items.count >= 10 else { return .unreadable }
        let title = items[2].text ?? ""
        let artist = items[3].text ?? ""
        let album = items[4].text ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return .stopped }
        let id = items[6].text.flatMap { $0.isEmpty ? nil : $0 }
        let position = items[1].number
        let artwork = items[7].text.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let snapshot = NowPlayingSnapshot(
            track: Track(
                id: id ?? TrackMatching.metadataKey(title: title, artist: artist, album: album),
                source: .spotify,
                title: title,
                artist: artist,
                album: album,
                duration: (items[5].number ?? 0) / 1000,
                artworkURL: artwork
            ),
            elapsedTime: max(0, position ?? 0),
            playbackRate: state == "playing" ? 1 : 0,
            timestamp: sampledAt,
            isPositionKnown: position != nil,
            isShuffled: items[8].boolean,
            repeatMode: items[9].boolean.map { $0 ? .all : .off },
            contentKind: contentKind(forTrackID: id)
        )
        return .track(snapshot, hasArtwork: artwork != nil)
    }

    static func contentKind(forTrackID id: String?) -> ContentKind {
        guard let id else { return .music }
        if id.hasPrefix("spotify:ad:") { return .advertisement }
        if id.hasPrefix("spotify:episode:") { return .podcast }
        return .music
    }

    public static func script(for command: PlaybackCommand) -> String? {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .seek(let seconds):
            guard seconds.isFinite else { return nil }
            verb = "set player position to \(ScriptFormatting.number(max(0, seconds)))"
        case .setShuffle(let on): verb = "set shuffling to \(on)"
        case .setRepeat(.one): return nil
        case .setRepeat(let mode): verb = "set repeating to \(mode != .off)"
        case .setLiked: return nil
        }
        return ScriptFormatting.command(verb, bundleIdentifier: bundleIdentifier)
    }

    public static func outcome(of event: SpotifyPlaybackEvent, current: NowPlayingSnapshot?, now: Date) -> NotificationOutcome {
        guard event.state != .stopped else { return .stopped }
        guard !event.title.isEmpty || !event.artist.isEmpty else { return .ignore }
        let track = Track(
            id: event.trackID ?? TrackMatching.metadataKey(title: event.title, artist: event.artist, album: event.album),
            source: .spotify,
            title: event.title,
            artist: event.artist,
            album: event.album,
            duration: event.duration ?? 0,
            artworkURL: current.flatMap { $0.track.id == event.trackID ? $0.track.artworkURL : nil }
        )
        let playing = event.state == .playing
        var snapshot: NowPlayingSnapshot
        if let position = event.position {
            snapshot = NowPlayingSnapshot(
                track: track,
                elapsedTime: max(0, position),
                playbackRate: playing ? 1 : 0,
                timestamp: now,
                contentKind: contentKind(forTrackID: event.trackID)
            )
        } else if var current, current.track.isSameSong(as: track) {
            current.setPlaying(playing, at: now)
            current.track = track
            snapshot = current
        } else {
            snapshot = NowPlayingSnapshot(
                track: track,
                elapsedTime: 0,
                playbackRate: playing ? 1 : 0,
                timestamp: now,
                isPositionKnown: playing,
                contentKind: contentKind(forTrackID: event.trackID)
            )
        }
        if let current, current.isSameTrack(as: snapshot) {
            snapshot.isShuffled = current.isShuffled
            snapshot.repeatMode = current.repeatMode
        }
        return .snapshot(snapshot)
    }
}

public typealias AppleMusicProvider = ScriptedPlayerProvider<AppleMusicPlayer>
public typealias SpotifyProvider = ScriptedPlayerProvider<SpotifyPlayer>
