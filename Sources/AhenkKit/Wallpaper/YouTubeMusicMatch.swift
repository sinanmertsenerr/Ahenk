import Foundation

/// One result of a YouTube Music search, as YouTube itself describes it.
public struct YouTubeMusicEntry: Hashable, Sendable, Codable {
    /// What YouTube says the upload is.
    public enum Kind: String, Sendable, Codable {
        /// The artist's or label's own video of the song.
        case officialVideo
        /// The label's recording over the cover (an "art track").
        case artTrack
        /// Somebody else's upload: a copy, a lyric video, an edit.
        case userUpload
    }

    public var id: String
    public var title: String
    /// The artists YouTube credits, in its order.
    public var artists: [String]
    public var duration: TimeInterval?
    public var kind: Kind

    public init(id: String, title: String, artists: [String], duration: TimeInterval?, kind: Kind) {
        self.id = id
        self.title = title
        self.artists = artists
        self.duration = duration
        self.kind = kind
    }

    public var video: YouTubeVideo {
        YouTubeVideo(
            id: id, title: title, channel: artists.joined(separator: ", "), duration: duration,
            isOfficialArtistChannel: kind != .userUpload, isArtTrack: kind == .artTrack
        )
    }
}

/// The song's own video, as YouTube files it.
public struct YouTubeMusicMatch: Hashable, Sendable, Codable {
    public var entry: YouTubeMusicEntry?

    public init(entry: YouTubeMusicEntry?) {
        self.entry = entry
    }
}

/// Pairs a song with its video the way YouTube does, instead of guessing
/// from titles. YouTube Music's search says of every result whether it is
/// an official music video, the label's recording (an "art track") or
/// somebody's upload, and credits its artists one by one; a plain YouTube
/// search says none of that, so a fan's copy named after the song used to
/// beat the real video named after something else.
///
/// The rules, in order:
/// 1. An **official music video** by the song's artists that is named
///    after the song, or (for a song with several artists) by at least two
///    of them and exactly as long as the song: a session or a series
///    titles its video after itself.
///    When that video is far from the song's length and an upload named
///    after the song and its artists is much closer, the upload is the
///    video (`closerUpload`).
/// 2. Else the **label's recording** of the song (its cover as a still):
///    the right song without a video beats another song's video.
/// 3. Else nothing: the caller falls back to ranking a plain search.
///
/// No account and no key: the same public search the site's own pages use.
public final class YouTubeMusicMatcher: Sendable {
    static let lifetime: TimeInterval = 30 * 86_400
    static let missLifetime: TimeInterval = 86_400
    static let endpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
    /// The site's own filters for "videos" and for "songs".
    static let videosFilter = "EgWKAQIQAWoMEA4QChADEAQQCRAF"
    static let songsFilter = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    private let fetcher: any HTTPFetching
    private let region: @Sendable () -> String
    private let cache: CatalogCache
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "wallpaper")

    public init(
        fetcher: any HTTPFetching,
        region: @escaping @Sendable () -> String,
        cache: CatalogCache = CatalogCache(directory: nil),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.region = region
        self.cache = cache
        self.clock = clock
    }

    /// The song's video (or its recording), or `nil` when YouTube Music
    /// has neither or cannot be asked.
    public func match(title: String, artist: String, duration: TimeInterval?) async -> YouTubeMusicEntry? {
        let names = VideoRanking.artistNames(artist)
        let core = TrackMatching.coreTitle(title)
        guard !core.isEmpty, let whole = names.first else { return nil }
        let key = "ytm-match:v4:\(whole)|\(core)|\(Int((duration ?? 0).rounded()))"
        if let stored = cache.value(YouTubeMusicMatch.self, forKey: key, maxAge: Self.lifetime, now: clock()) {
            if let entry = stored.entry { return entry }
            if cache.value(YouTubeMusicMatch.self, forKey: key, maxAge: Self.missLifetime, now: clock()) != nil { return nil }
        }
        let query = "\(artist) \(WallpaperRequest.plainTitle(title))"
        guard let videos = await search(query, filter: Self.videosFilter) else { return nil }
        var found = Self.officialVideo(among: videos, title: title, artist: artist, duration: duration)
        if found == nil, let songs = await search(query, filter: Self.songsFilter) {
            found = Self.recording(among: songs, title: title, artist: artist, duration: duration)
            // The recording credits everyone on the song; a player may
            // have named only the first artist. Look for the video again
            // with all of them (a session's video is found by its artists).
            if let recording = found, recording.artists.count > 1,
               let video = Self.officialVideo(among: videos, title: title, artist: recording.artists.joined(separator: ", "), duration: duration) {
                found = video
            }
        }
        // An "official" video far from the song's length is looked at
        // once more: YouTube Music files some lyric videos and copies as
        // official and shows them under the song's own name, while the
        // upload's real title says what it is.
        if let official = found, official.kind == .officialVideo, let song = duration, let length = official.duration,
           abs(length - song) > Self.doubtfulDifference,
           let real = await realTitle(of: official.id), Self.isNotTheVideo(real, songTitle: title) {
            Self.log.info("YouTube's official video for the song is \u{201C}\(real)\u{201D}; looking past it")
            found = Self.uploadAbove(official, among: videos, title: title, artist: artist, duration: duration)
                ?? Self.officialVideo(among: videos.filter { $0.id != official.id }, title: title, artist: artist, duration: duration)
        }
        cache.store(YouTubeMusicMatch(entry: found), forKey: key, onDisk: true, now: clock())
        return found
    }

    /// The upload's title on YouTube itself (its public oEmbed answer).
    private func realTitle(of id: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(id)"),
              let (data, status) = try? await fetcher.get(url), status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["title"] as? String
    }

    // MARK: The rules

    /// How many of the song's artists `entry` credits.
    static func sharedArtists(_ entry: YouTubeMusicEntry, names: [String]) -> Int {
        // The first name is the whole credit ("a and b"); its parts follow.
        let parts = names.count > 1 ? Array(names.dropFirst()) : names
        let credited = entry.artists.map(TrackMatching.normalized)
        return parts.filter { part in
            credited.contains { $0 == part || VideoRanking.contains(words: part, in: $0) || VideoRanking.contains(words: $0, in: part) }
        }.count
    }

    /// Another take of the song (live, a remix, an acoustic version) that
    /// the song's own title does not announce.
    static func isAnotherTake(_ videoTitle: String, songTitle: String) -> Bool {
        let song = TrackMatching.normalized(songTitle)
        let text = TrackMatching.normalized(videoTitle)
        let takes = ["live", "canli", "konser", "concert", "remix", "akustik", "acoustic", "cover", "slowed", "sped up", "speed up",
                     "nightcore", "karaoke", "instrumental", "beat", "reverb", "8d"]
        return takes.contains { VideoRanking.contains(words: $0, in: text) && !VideoRanking.contains(words: $0, in: song) }
    }

    /// Words of an upload that is about the song but is not its video.
    static let extras = ["lyrics", "lyric", "sozleri", "sozler", "ceviri", "translation", "reaction", "tepki video"]

    /// A title that says the upload is another take, a lyric video or the
    /// like, when the song's own title does not say so.
    static func isNotTheVideo(_ videoTitle: String, songTitle: String) -> Bool {
        if isAnotherTake(videoTitle, songTitle: songTitle) { return true }
        let text = TrackMatching.normalized(videoTitle)
        let song = TrackMatching.normalized(songTitle)
        return extras.contains { VideoRanking.contains(words: $0, in: text) && !VideoRanking.contains(words: $0, in: song) }
    }

    /// Named after the song and its artists (two of them, or the only
    /// one) and not another take or a lyric video.
    static func isNamedVideo(_ entry: YouTubeMusicEntry, title: String, artist: String) -> Bool {
        let names = VideoRanking.artistNames(artist)
        let parts = names.count > 1 ? Array(names.dropFirst()) : names
        let text = TrackMatching.normalized(entry.title)
        return VideoRanking.contains(words: TrackMatching.coreTitle(title), in: text)
            && parts.filter({ VideoRanking.contains(words: $0, in: text) }).count >= min(2, parts.count)
            && !isNotTheVideo(entry.title, songTitle: title)
    }

    /// With the official video ruled out: the first upload YouTube ranks
    /// above it that is named after the song and its artists and is not
    /// far longer than the song (a re-upload of a video whose own upload
    /// is gone). Handed back as the song's video.
    static func uploadAbove(
        _ official: YouTubeMusicEntry, among entries: [YouTubeMusicEntry], title: String, artist: String, duration: TimeInterval?
    ) -> YouTubeMusicEntry? {
        guard let index = entries.firstIndex(where: { $0.id == official.id }) else { return nil }
        for entry in entries.prefix(upTo: index) where entry.kind == .userUpload && isNamedVideo(entry, title: title, artist: artist) {
            if let song = duration, let length = entry.duration, abs(length - song) > 120 { continue }
            var stand = entry
            stand.kind = .officialVideo
            return stand
        }
        return nil
    }

    /// Rule 1.
    public static func officialVideo(among entries: [YouTubeMusicEntry], title: String, artist: String, duration: TimeInterval?) -> YouTubeMusicEntry? {
        let names = VideoRanking.artistNames(artist)
        let core = TrackMatching.coreTitle(title)
        let artistCount = max(1, names.count > 1 ? names.count - 1 : 1)
        var best: (entry: YouTubeMusicEntry, distance: Double)?
        for entry in entries where entry.kind == .officialVideo {
            let shared = sharedArtists(entry, names: names)
            guard shared > 0, !isAnotherTake(entry.title, songTitle: title) else { continue }
            let difference = duration.flatMap { song in entry.duration.map { abs($0 - song) } }
            let named = VideoRanking.contains(words: core, in: TrackMatching.normalized(entry.title))
            let accepted: Bool
            if named {
                // Videos add an intro or an outro; a far longer one is a
                // film or a medley.
                accepted = difference.map { $0 <= 120 } ?? true
            } else {
                accepted = artistCount >= 2 && shared >= 2 && (difference.map { $0 <= 6 } ?? false)
            }
            guard accepted else { continue }
            // Named after the song first, then the closest in length.
            let distance = (named ? 0 : 1_000) + (difference ?? 60)
            if best == nil || distance < best!.distance { best = (entry, distance) }
        }
        if let official = best?.entry, let stand = closerUpload(than: official, among: entries, title: title, artist: artist, duration: duration) {
            return stand
        }
        return best?.entry
    }

    /// An official video this far from the song's length may be another
    /// take that its title does not announce (a live cut filed under the
    /// artists' own channel, while the real video sits on the label's).
    static let doubtfulDifference: TimeInterval = 30

    /// The upload that is the song's video after all, when YouTube's
    /// "official" one is far from the song's length: named after the song
    /// and its artists (two of them, or the only one), not another take or
    /// a lyric video, within an intro's length of the song and much closer
    /// to it than the official one, and ranked above the official one by
    /// YouTube. It is handed back as the song's video.
    static func closerUpload(
        than official: YouTubeMusicEntry, among entries: [YouTubeMusicEntry], title: String, artist: String, duration: TimeInterval?
    ) -> YouTubeMusicEntry? {
        guard let song = duration, let officialLength = official.duration, abs(officialLength - song) > doubtfulDifference else { return nil }
        // Only what YouTube itself ranks above its official video: the
        // song's real video on a label's channel is the top result, while
        // a cut-down copy with a few views (which fits a shortened release
        // better than the real, longer video does) comes far below it.
        let above = entries.firstIndex(of: official).map { entries.prefix(upTo: $0) } ?? []
        for entry in above where entry.kind == .userUpload {
            guard let length = entry.duration else { continue }
            let difference = abs(length - song)
            guard difference <= 25, difference + 20 <= abs(officialLength - song), isNamedVideo(entry, title: title, artist: artist)
            else { continue }
            var stand = entry
            stand.kind = .officialVideo
            return stand
        }
        return nil
    }

    /// Rule 2.
    public static func recording(among entries: [YouTubeMusicEntry], title: String, artist: String, duration: TimeInterval?) -> YouTubeMusicEntry? {
        let names = VideoRanking.artistNames(artist)
        let core = TrackMatching.coreTitle(title)
        var best: (entry: YouTubeMusicEntry, distance: Double)?
        for entry in entries where entry.kind == .artTrack {
            guard TrackMatching.coreTitle(entry.title) == core, sharedArtists(entry, names: names) > 0 else { continue }
            guard !isAnotherTake(entry.title, songTitle: title) else { continue }
            let difference = duration.flatMap { song in entry.duration.map { abs($0 - song) } }
            if let difference, difference > 5 { continue }
            let distance = difference ?? 5
            if best == nil || distance < best!.distance { best = (entry, distance) }
        }
        return best?.entry
    }

    // MARK: Asking

    private func search(_ query: String, filter: String) async -> [YouTubeMusicEntry]? {
        var country = region().uppercased()
        if country.count != 2 || !country.allSatisfy({ $0.isASCII && $0.isLetter }) { country = "US" }
        let body: [String: Any] = [
            "query": query, "params": filter,
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20251103.01.00", "hl": "en", "gl": country]],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        guard let (data, status) = try? await fetcher.send(request), status == 200 else {
            Self.log.info("YouTube Music could not be asked for the song's video")
            return nil
        }
        return Self.entries(from: data)
    }

    /// The results in an answer, in its order; `nil` when it is not one.
    public static func entries(from data: Data) -> [YouTubeMusicEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var items: [[String: Any]] = []
        collect("musicResponsiveListItemRenderer", in: root, into: &items)
        return items.compactMap(entry)
    }

    private static func collect(_ key: String, in value: Any, into found: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            for (name, child) in dictionary {
                if name == key, let item = child as? [String: Any] {
                    found.append(item)
                } else {
                    collect(key, in: child, into: &found)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collect(key, in: child, into: &found) }
        }
    }

    private static func first(_ key: String, in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let hit = dictionary[key] { return hit }
            for child in dictionary.values {
                if let hit = first(key, in: child) { return hit }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let hit = first(key, in: child) { return hit }
            }
        }
        return nil
    }

    private static func runs(ofColumn index: Int, in item: [String: Any]) -> [[String: Any]] {
        guard let columns = item["flexColumns"] as? [[String: Any]], columns.indices.contains(index),
              let column = columns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = column["text"] as? [String: Any]
        else { return [] }
        return text["runs"] as? [[String: Any]] ?? []
    }

    static func entry(_ item: [String: Any]) -> YouTubeMusicEntry? {
        guard let id = first("videoId", in: item) as? String, id.count == 11 else { return nil }
        let title = runs(ofColumn: 0, in: item).compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        // "Artist, Artist & Artist • Album or views • 3:28": the artists
        // are the pieces before the first bullet that link somewhere (a
        // channel), or the plain text there when none does.
        let detail = runs(ofColumn: 1, in: item)
        var artists: [String] = []
        var plain: [String] = []
        var duration: TimeInterval?
        var pastArtists = false
        for run in detail {
            guard let text = run["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed == "\u{2022}" {
                pastArtists = true
                continue
            }
            if !pastArtists {
                if run["navigationEndpoint"] != nil, !trimmed.isEmpty {
                    artists.append(trimmed)
                } else if !trimmed.isEmpty, ![",", "&", "and", "ve"].contains(trimmed) {
                    plain.append(trimmed)
                }
            } else if let seconds = seconds(trimmed) {
                duration = seconds
            }
        }
        if artists.isEmpty { artists = plain }
        let kind: YouTubeMusicEntry.Kind
        switch first("musicVideoType", in: item) as? String {
        case "MUSIC_VIDEO_TYPE_OMV": kind = .officialVideo
        case "MUSIC_VIDEO_TYPE_ATV": kind = .artTrack
        default: kind = .userUpload
        }
        return YouTubeMusicEntry(id: id, title: title, artists: artists, duration: duration, kind: kind)
    }

    /// "3:28" or "1:02:03" in seconds.
    static func seconds(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
