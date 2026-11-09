import Foundation

/// A song Ahenk asked a source to play, and whether it has started.
public struct PlaybackAttempt: Hashable, Sendable {
    public var entryID: UUID
    public var song: CatalogSong
    public var source: MusicSource
    public var requestedAt: Date
    /// When the source was first seen playing it.
    public var confirmedAt: Date?

    public init(entryID: UUID, song: CatalogSong, source: MusicSource, requestedAt: Date, confirmedAt: Date? = nil) {
        self.entryID = entryID
        self.song = song
        self.source = source
        self.requestedAt = requestedAt
        self.confirmedAt = confirmedAt
    }

    public var isConfirmed: Bool { confirmedAt != nil }
}

/// What the queue conductor should do after a change of what plays.
public enum ConductorDecision: Hashable, Sendable {
    case none
    /// The requested song plays now (the loading state ends).
    case confirmed
    /// The source moved on to the queue's next song by itself.
    case followed(UUID)
    /// The song ends (or ended): start the next entry.
    case advance
    /// The requested song never started.
    case startFailed
    /// Something else plays: the user took over in the source's own app.
    case takenOver
}

/// The rules Ahenk's queue follows while songs play in another app. That app
/// only knows the song Ahenk started; Ahenk starts the next one a moment
/// before the current one ends, follows the app when it moves to the
/// queue's next song by itself, and steps back when the user plays
/// something else there.
public enum QueueConductorPolicy {
    /// A started song that is not playing after this long has failed.
    public static let startTimeout: TimeInterval = 12
    /// The next song is started this long before the current one ends, so
    /// the source never moves on to a song of its own choosing.
    public static let endLead: TimeInterval = 0.35
    /// When the source switches songs this close to the end of Ahenk's
    /// song, that song simply ended (autoplay picked a song); later
    /// switches mean the user took over.
    public static let lateEndWindow: TimeInterval = 4
    /// A paused song this close to its end has ended.
    public static let endedWithin: TimeInterval = 1.2

    /// - Parameters:
    ///   - snapshot: what the followed player plays now.
    ///   - lastOwn: the last snapshot that showed the attempt's song.
    public static func decide(
        attempt: PlaybackAttempt?, queue: PlayQueue, snapshot: NowPlayingSnapshot?, lastOwn: NowPlayingSnapshot?, now: Date
    ) -> ConductorDecision {
        guard let attempt else { return .none }
        guard attempt.isConfirmed else {
            if let snapshot, snapshot.isPlaying, SongMatching.matches(attempt.song, snapshot.track) { return .confirmed }
            return now.timeIntervalSince(attempt.requestedAt) > startTimeout ? .startFailed : .none
        }
        guard let snapshot else { return .none }
        if SongMatching.matches(attempt.song, snapshot.track) {
            let duration = snapshot.track.duration > 0 ? snapshot.track.duration : attempt.song.duration
            guard duration > 0, snapshot.isPositionKnown else { return .none }
            let remaining = duration - snapshot.elapsed(at: now)
            if snapshot.isPlaying, remaining <= endLead { return .advance }
            if !snapshot.isPlaying, remaining <= endedWithin { return .advance }
            return .none
        }
        if let next = queue.following, next.id != attempt.entryID, SongMatching.matches(next.song, snapshot.track) {
            return .followed(next.id)
        }
        if let lastOwn {
            let duration = lastOwn.track.duration > 0 ? lastOwn.track.duration : attempt.song.duration
            if duration > 0, duration - lastOwn.elapsed(at: now) <= lateEndWindow { return .advance }
        }
        return .takenOver
    }

    /// When to look again: the moment the next song should start.
    public static func wakeTime(attempt: PlaybackAttempt?, snapshot: NowPlayingSnapshot?, now: Date) -> Date? {
        guard let attempt else { return nil }
        guard attempt.isConfirmed else {
            return attempt.requestedAt.addingTimeInterval(startTimeout + 0.05)
        }
        guard let snapshot, snapshot.isPlaying, snapshot.isPositionKnown,
              SongMatching.matches(attempt.song, snapshot.track)
        else { return nil }
        let duration = snapshot.track.duration > 0 ? snapshot.track.duration : attempt.song.duration
        guard duration > 0 else { return nil }
        let remaining = duration - snapshot.elapsed(at: now) - endLead
        let rate = snapshot.playbackRate > 0 ? snapshot.playbackRate : 1
        return now.addingTimeInterval(max(0, remaining / rate))
    }
}
