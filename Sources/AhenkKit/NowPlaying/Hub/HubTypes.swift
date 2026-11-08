import Foundation

/// One player the hub tracks: a source in one app (Spotify; YouTube Music
/// in Safari), optionally one of several inside it (a browser tab).
public struct PlayerID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var source: MusicSource
    /// The app that plays: the music app itself, or the browser.
    public var bundleIdentifier: String?
    /// Tells several players of one app apart (tabs, Step 7).
    public var instance: String?

    public init(source: MusicSource, bundleIdentifier: String? = nil, instance: String? = nil) {
        self.source = source
        self.bundleIdentifier = bundleIdentifier
        self.instance = instance
    }

    public init(snapshot: NowPlayingSnapshot) {
        self.init(source: snapshot.track.source, bundleIdentifier: snapshot.bundleIdentifier, instance: snapshot.instanceIdentifier)
    }

    public var description: String {
        [source.rawValue, bundleIdentifier, instance].compactMap { $0 }.joined(separator: "/")
    }
}

/// The settings the hub follows (from `SourceSettings` and `PlayerSettings`).
public struct HubConfiguration: Sendable, Equatable {
    public var selection: SourceSelection
    public var askWhenSeveralPlay: Bool
    public var pauseOthersOnSwitch: Bool
    public var ignoredSources: Set<MusicSource>
    public var startAtFifteenSeconds: Bool
    /// How long two sources must play together before Ahenk asks.
    public var conflictDelay: TimeInterval

    public init(
        selection: SourceSelection = .automatic,
        askWhenSeveralPlay: Bool = true,
        pauseOthersOnSwitch: Bool = true,
        ignoredSources: Set<MusicSource> = [],
        startAtFifteenSeconds: Bool = false,
        conflictDelay: TimeInterval = 3
    ) {
        self.selection = selection
        self.askWhenSeveralPlay = askWhenSeveralPlay
        self.pauseOthersOnSwitch = pauseOthersOnSwitch
        self.ignoredSources = ignoredSources
        self.startAtFifteenSeconds = startAtFifteenSeconds
        self.conflictDelay = conflictDelay
    }

    public init(sources: SourceSettings, player: PlayerSettings) {
        self.init(
            selection: sources.selection,
            askWhenSeveralPlay: sources.askWhenSeveralPlay,
            pauseOthersOnSwitch: sources.pauseOthersOnSwitch,
            ignoredSources: sources.ignoredSources,
            startAtFifteenSeconds: player.startAtFifteenSeconds
        )
    }
}

/// A player as the hub sees it, with its merged snapshot.
public struct HubPlayer: Sendable, Equatable, Identifiable {
    public var id: PlayerID
    public var snapshot: NowPlayingSnapshot
    /// Providers that describe this player, most authoritative first.
    public var providerIDs: [String]
    /// When it last started playing; `nil` while paused.
    public var playingSince: Date?
    public var lastPlayingAt: Date?

    public init(id: PlayerID, snapshot: NowPlayingSnapshot, providerIDs: [String], playingSince: Date? = nil, lastPlayingAt: Date? = nil) {
        self.id = id
        self.snapshot = snapshot
        self.providerIDs = providerIDs
        self.playingSince = playingSince
        self.lastPlayingAt = lastPlayingAt
    }

    public var isPlaying: Bool { snapshot.isPlaying }
}

/// Two or more players have been playing together for a moment; the UI
/// asks which one to follow.
public struct PlaybackConflict: Sendable, Equatable {
    /// Newest start first.
    public var players: [PlayerID]
    public var since: Date

    public init(players: [PlayerID], since: Date) {
        self.players = players
        self.since = since
    }
}

public struct HubState: Sendable, Equatable {
    public var activeID: PlayerID?
    /// Playing players first (newest start first), then paused ones (most
    /// recently playing first).
    public var players: [HubPlayer]
    public var conflict: PlaybackConflict?
    public var selection: SourceSelection

    public init(activeID: PlayerID? = nil, players: [HubPlayer] = [], conflict: PlaybackConflict? = nil, selection: SourceSelection = .automatic) {
        self.activeID = activeID
        self.players = players
        self.conflict = conflict
        self.selection = selection
    }

    public var active: HubPlayer? {
        guard let activeID else { return nil }
        return players.first { $0.id == activeID }
    }

    public var activeSnapshot: NowPlayingSnapshot? { active?.snapshot }

    public func player(_ id: PlayerID) -> HubPlayer? {
        players.first { $0.id == id }
    }

    /// The parts the UI shows besides the song itself: which player is
    /// followed, who plays, the conflict. Position updates do not count.
    public func hasSameOutline(as other: HubState) -> Bool {
        guard activeID == other.activeID, conflict == other.conflict, selection == other.selection,
              players.count == other.players.count
        else { return false }
        return zip(players, other.players).allSatisfy { a, b in
            a.id == b.id && a.isPlaying == b.isPlaying && a.snapshot.track == b.snapshot.track
                && a.providerIDs == b.providerIDs && a.snapshot.capabilities == b.snapshot.capabilities
        }
    }
}

/// What the hub reports besides snapshots.
public enum HubEvent: Sendable, Equatable {
    /// The followed player switched to another song (or the followed player
    /// changed and plays another song).
    case trackChanged(player: PlayerID, previous: NowPlayingSnapshot?, current: NowPlayingSnapshot)
    case playbackChanged(player: PlayerID, isPlaying: Bool)
    case activePlayerChanged(previous: PlayerID?, current: PlayerID?)
    case conflictChanged(PlaybackConflict?)
}

/// The state Ahenk expects right after sending a command, shown at once
/// and held until the player confirms it (or a moment passes), so the
/// progress bar and the buttons never jump back to the old state.
public struct PlaybackExpectation: Sendable, Equatable {
    public var track: Track
    public var isPlaying: Bool?
    /// Position at `anchor`.
    public var position: TimeInterval?
    public var anchor: Date
    public var isShuffled: Bool?
    public var repeatMode: RepeatMode?
    public var isLiked: Bool?
    public var until: Date

    public init(track: Track, anchor: Date, until: Date) {
        self.track = track
        self.anchor = anchor
        self.until = until
    }

    /// The expectation after `command`; `nil` for next and previous (the
    /// new song is not known yet).
    public static func after(_ command: PlaybackCommand, on snapshot: NowPlayingSnapshot, at now: Date, lifetime: TimeInterval = 2) -> PlaybackExpectation? {
        var expectation = PlaybackExpectation(track: snapshot.track, anchor: now, until: now.addingTimeInterval(lifetime))
        let current = snapshot.isPositionKnown ? snapshot.elapsed(at: now) : nil
        switch command {
        case .play:
            expectation.isPlaying = true
            expectation.position = current
        case .pause:
            expectation.isPlaying = false
            expectation.position = current
        case .togglePlayPause:
            expectation.isPlaying = !snapshot.isPlaying
            expectation.position = current
        case .seek(let target):
            guard target.isFinite else { return nil }
            let upper = snapshot.track.duration > 0 ? snapshot.track.duration : .infinity
            expectation.position = min(max(0, target), upper)
        case .setShuffle(let on):
            expectation.isShuffled = on
        case .setRepeat(let mode):
            expectation.repeatMode = mode
        case .setLiked(let liked):
            expectation.isLiked = liked
        case .next, .previous:
            return nil
        }
        return expectation
    }

    func expectedPosition(at now: Date, playing: Bool) -> TimeInterval? {
        guard let position else { return nil }
        return position + (playing ? max(0, now.timeIntervalSince(anchor)) : 0)
    }

    public func apply(to snapshot: NowPlayingSnapshot) -> NowPlayingSnapshot {
        var result = snapshot
        if let isPlaying {
            result.playbackRate = isPlaying ? (snapshot.playbackRate > 0 ? snapshot.playbackRate : 1) : 0
        }
        if let position {
            result.elapsedTime = position
            result.timestamp = anchor
            result.isPositionKnown = true
        }
        if let isShuffled { result.isShuffled = isShuffled }
        if let repeatMode { result.repeatMode = repeatMode }
        if let isLiked { result.isLiked = isLiked }
        return result
    }

    public func isConfirmed(by snapshot: NowPlayingSnapshot, at now: Date) -> Bool {
        if let isPlaying, snapshot.isPlaying != isPlaying { return false }
        if snapshot.isPositionKnown, let expected = expectedPosition(at: now, playing: isPlaying ?? snapshot.isPlaying),
           abs(snapshot.elapsed(at: now) - expected) > 1.5 {
            return false
        }
        if let isShuffled, snapshot.isShuffled != isShuffled { return false }
        if let repeatMode, snapshot.repeatMode != repeatMode { return false }
        if let isLiked, snapshot.isLiked != isLiked { return false }
        return true
    }
}
