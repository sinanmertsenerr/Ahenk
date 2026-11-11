import Foundation

/// The song's own clip, in step with the song: when a song plays as sound
/// (Spotify, Apple Music, a song on YouTube Music, …) the live wallpaper
/// shows the official video YouTube files for it, silent, at the song's
/// place in it.
///
/// A clip is its own recording of the song: often the album's, later (an
/// intro) or with a scene in between. Where the song falls in it is its
/// map (`SongClipMap`), found the fastest way there is and kept
/// (`SongClipMaps`):
/// 1. YouTube Music's own pairing of the song and its video, asked of a
///    signed-in tab through the browser extension: exact, in about a second.
/// 2. Heard: the clip's words are read from the sound its player holds and
///    looked up in the song's timed lyrics (`LyricShiftEstimator`); half a
///    minute, once.
/// Until the map is known a clip about as long as the song runs from the
/// song's own position (most are the same recording).
public enum SongClip {
    /// A clip is looked for: music that plays as sound, with a title and an
    /// artist to ask by. A music video in the browser is its own picture
    /// already (`YouTubeSongs.clipPictureURLs`); the demo asks nobody.
    public static func isWanted(for snapshot: NowPlayingSnapshot) -> Bool {
        let track = snapshot.track
        guard track.source != .demo, !snapshot.isMusicVideo, AudioCapturePolicy.reactsTo(snapshot) else { return false }
        return !track.title.trimmingCharacters(in: .whitespaces).isEmpty && !track.artist.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A song's clip and what its length says about it.
    public struct Found: Equatable, Sendable {
        public var video: YouTubeVideo
        /// About as long as the song: most likely the same recording from
        /// the same start, so it may play before its offset is heard.
        public var isAsLongAsTheSong: Bool
    }

    /// What YouTube files for the song, as the clip to play: its official
    /// video. `nil`: the song has none (only its recording over the cover,
    /// or somebody's upload), or one of a length nobody knows.
    public static func clip(from entry: YouTubeMusicEntry?, songDuration: TimeInterval) -> Found? {
        guard let entry, entry.kind == .officialVideo, let length = entry.duration, length > 0 else { return nil }
        let fits = VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: songDuration, videoDuration: length) == .followsSong
        return Found(video: entry.video, isAsLongAsTheSong: fits)
    }

    /// Where the song most likely falls in a clip, from their lengths
    /// alone, for the first moments (the clip starts there at once and is
    /// put right when its map is known): a clip about as long as the song
    /// is the same recording from the same start; what a longer one has
    /// more is nearly always an intro before the song, so the song starts
    /// that much later in it. `nil` when a length is not known.
    public static func guess(songDuration: TimeInterval, videoDuration: TimeInterval?) -> SongClipMap? {
        guard songDuration > 0, let videoDuration, videoDuration > 0 else { return nil }
        let more = videoDuration - songDuration
        let fits = VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: songDuration, videoDuration: videoDuration) == .followsSong
        return SongClipMap(offset: fits || more < 0 ? 0 : more)
    }

    /// The offsets that are possible at all: the song lies inside its clip
    /// (give or take a few seconds of silence cut from either), so it
    /// starts no earlier than the clip and no later than the clip is
    /// longer. `nil` when a length is not known.
    public static func possibleOffsets(songDuration: TimeInterval, videoDuration: TimeInterval?) -> ClosedRange<TimeInterval>? {
        guard songDuration > 0, let videoDuration, videoDuration > 0 else { return nil }
        return -4...(max(0, videoDuration - songDuration) + 4)
    }

    /// An offset this small is the song's own start: the words are heard
    /// to about half a second, so less than this is not told apart.
    public static let smallestOffset: TimeInterval = 0.75

    /// The offset a heard shift stands for: a small one is none.
    public static func offset(from shift: LyricShift) -> TimeInterval {
        abs(shift.seconds) < smallestOffset ? 0 : shift.seconds
    }

    /// A clip that is only heard (the live check) is asked for at no more than 480p.
    public static let hearingPlan = WallpaperPowerPlan(quality: .full, reason: .normal, maximumVideoSide: 854, peakBitRate: 0, animationFrameRate: 30)

    /// One song, for telling a new song from news about the same one.
    public static func songKey(_ snapshot: NowPlayingSnapshot) -> String {
        let track = snapshot.track
        return "\(track.source.rawValue)|\(track.id)|\(TrackMatching.normalized(track.title))|\(TrackMatching.normalized(track.artist))"
    }
}

/// Where a song falls in its clip: the stretches the two share, in the
/// clip's order. Most clips are one stretch (the album's recording after
/// an intro); a clip with a scene in the middle is two.
public struct SongClipMap: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var video: TimeInterval
        public var song: TimeInterval
        public var duration: TimeInterval

        public init(video: TimeInterval, song: TimeInterval, duration: TimeInterval) {
            self.video = video
            self.song = song
            self.duration = duration
        }
    }

    public var segments: [Segment]

    /// The song runs through the clip from `offset` seconds into it.
    public init(offset: TimeInterval) {
        segments = [Segment(video: max(0, offset), song: max(0, -offset), duration: 86_400)]
    }

    /// The stretches a site pairs; `nil` when none is usable.
    public init?(segments: [Segment]) {
        let usable = segments
            .filter { [$0.video, $0.song, $0.duration].allSatisfy(\.isFinite) && $0.video >= 0 && $0.song >= 0 && $0.duration > 0 }
            .sorted { $0.song < $1.song }
        guard !usable.isEmpty else { return nil }
        self.segments = usable
    }

    /// What YouTube Music says about a clip, when it is about the song
    /// that plays: a song of another length is another recording (a live
    /// take, another edit), whose stretches say nothing about this one.
    public init?(_ clip: BridgeClip, songDuration: TimeInterval) {
        if songDuration > 0, let length = clip.songSeconds, abs(length - songDuration) > max(3, songDuration * 0.02) { return nil }
        self.init(segments: clip.segments.map { Segment(video: $0.video, song: $0.song, duration: $0.duration) })
    }

    /// Where the clip is when the song is at `song`: inside a shared
    /// stretch, the same moment of it; before the first one, as far before
    /// it in the clip (never before the clip's start); between two or
    /// after the last, the clip runs on from the stretch before.
    public func videoPosition(song: TimeInterval) -> TimeInterval {
        guard let first = segments.first else { return max(0, song) }
        let segment = segments.last { $0.song <= song } ?? first
        return max(0, segment.video + (song - segment.song))
    }

    /// The offset of a clip that is one stretch (for the log).
    public var offset: TimeInterval? {
        segments.count == 1 ? segments[0].video - segments[0].song : nil
    }
}

/// Where songs fall in their clips, kept between runs (the catalog cache):
/// a map once known is not asked for or heard again, and a clip whose map
/// could not be told is not tried again for a few days.
public struct SongClipMaps: Sendable {
    /// What is known about one song and clip.
    public enum Known: Equatable, Sendable {
        case map(SongClipMap)
        /// Tried, and it could not be told.
        case unknown
    }

    private struct Stored: Codable {
        var map: SongClipMap?
    }

    static let lifetime: TimeInterval = 365 * 86_400
    static let unknownLifetime: TimeInterval = 3 * 86_400

    private let cache: CatalogCache
    private let clock: @Sendable () -> Date

    public init(cache: CatalogCache, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.clock = clock
    }

    static func key(videoID: String, track: Track) -> String {
        "clip-map:v1:\(videoID)|\(TrackMatching.normalized(track.artist))|\(TrackMatching.coreTitle(track.title))|\(Int(track.duration.rounded()))"
    }

    public func known(videoID: String, track: Track) -> Known? {
        let key = Self.key(videoID: videoID, track: track)
        guard let stored = cache.value(Stored.self, forKey: key, maxAge: Self.lifetime, now: clock()) else { return nil }
        if let map = stored.map { return .map(map) }
        return cache.value(Stored.self, forKey: key, maxAge: Self.unknownLifetime, now: clock()) != nil ? .unknown : nil
    }

    public func remember(_ known: Known, videoID: String, track: Track) {
        var stored = Stored(map: nil)
        if case .map(let map) = known { stored.map = map }
        cache.store(stored, forKey: Self.key(videoID: videoID, track: track), onDisk: true, now: clock())
    }
}
