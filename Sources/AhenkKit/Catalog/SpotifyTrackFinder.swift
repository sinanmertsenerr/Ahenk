import Foundation
import os

/// A song as the link lookups see it: title, artist and album, cleaned of
/// decorations that differ between services.
public struct SongQuery: Hashable, Sendable, Codable {
    public var title: String
    public var artist: String
    public var album: String

    public init(title: String, artist: String, album: String) {
        self.title = title
        self.artist = artist
        self.album = album
    }

    public init(song: CatalogSong) {
        self.init(title: song.title, artist: song.artistName, album: song.albumTitle)
    }

    /// "Song (feat. X)" → "Song"; "Album - Single" / "Album (Deluxe)" → "Album".
    public var cleaned: SongQuery {
        func strip(_ text: String) -> String {
            var result = text
            for suffix in [" - Single", " - EP"] where result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
            let bracketed = result.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            let trimmed = bracketed.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? text.trimmingCharacters(in: .whitespaces) : trimmed
        }
        return SongQuery(title: strip(title), artist: artist.trimmingCharacters(in: .whitespaces), album: strip(album))
    }

    var cacheKey: String {
        [artist, album, title].map(TrackMatching.normalized).joined(separator: "|")
    }
}

/// Finds songs' Spotify track IDs so a pick from Apple's catalog can play
/// in the Spotify app (`play track "spotify:track:…"`).
public protocol SpotifyTrackFinding: Sendable {
    /// The best Spotify track ID (base-62) for every song that was found.
    func spotifyTrackIDs(for songs: [SongQuery]) async -> [SongQuery: String]
}

/// ListenBrainz Labs' public "Spotify ID from metadata" mapping (MetaBrainz:
/// no account, no key), asked in batches of up to 25 songs, one request a
/// second at most. Answers are kept a month (a miss three days).
///
/// Odesli (song.link), the usual service for this, answers
/// `401 PUBLIC_API_ACCESS_DEPRECATED` without a key since 2026, so it is not
/// used (see docs/PROGRESS.md, Step 5).
public final class ListenBrainzSpotifyFinder: SpotifyTrackFinding {
    public static let endpoint = URL(string: "https://labs.api.listenbrainz.org/spotify-id-from-metadata/json")!
    public static let batchSize = 25
    static let hitLifetime: TimeInterval = 30 * 86_400
    static let missLifetime: TimeInterval = 3 * 86_400

    private let fetcher: any HTTPFetching
    private let cache: CatalogCache
    private let throttle: RequestThrottle
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "catalog")

    public init(
        fetcher: any HTTPFetching,
        cache: CatalogCache = CatalogCache(directory: nil),
        throttle: RequestThrottle = RequestThrottle(limit: 1, per: 1.1, maximumWait: 10),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.throttle = throttle
        self.clock = clock
    }

    /// One answer: the query echoed back and the Spotify IDs, best first.
    public struct Match: Equatable, Sendable, Decodable {
        public var artistName: String
        public var releaseName: String
        public var trackName: String
        public var spotifyTrackIDs: [String]

        enum CodingKeys: String, CodingKey {
            case artistName = "artist_name"
            case releaseName = "release_name"
            case trackName = "track_name"
            case spotifyTrackIDs = "spotify_track_ids"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            artistName = (try? c.decode(String.self, forKey: .artistName)) ?? ""
            releaseName = (try? c.decode(String.self, forKey: .releaseName)) ?? ""
            trackName = (try? c.decode(String.self, forKey: .trackName)) ?? ""
            let ids = (try? c.decode([String].self, forKey: .spotifyTrackIDs)) ?? []
            spotifyTrackIDs = ids.filter(Self.isTrackID)
        }

        static func isTrackID(_ text: String) -> Bool {
            text.count == 22 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    public static func requestBody(_ queries: [SongQuery]) throws -> Data {
        let items = queries.map { query in
            ["artist_name": query.artist, "release_name": query.album, "track_name": query.title]
        }
        return try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
    }

    public static func decode(_ data: Data) throws -> [Match] {
        do {
            return try JSONDecoder().decode([Match].self, from: data)
        } catch {
            throw CatalogError.unreadable
        }
    }

    private struct Stored: Codable {
        var id: String?
    }

    public func spotifyTrackIDs(for songs: [SongQuery]) async -> [SongQuery: String] {
        var found: [SongQuery: String] = [:]
        var missing: [SongQuery] = []
        let now = clock()
        for song in songs {
            let query = song.cleaned
            let key = "spotify-id:v1:" + query.cacheKey
            if let known = cache.value(Stored.self, forKey: key, maxAge: Self.missLifetime, now: now) {
                if let id = known.id { found[song] = id }
            } else if let known = cache.value(Stored.self, forKey: key, maxAge: Self.hitLifetime, now: now), let id = known.id {
                found[song] = id
            } else if !missing.contains(song) {
                missing.append(song)
            }
        }
        var start = 0
        while start < missing.count {
            let batch = Array(missing[start..<min(missing.count, start + Self.batchSize)])
            start += batch.count
            guard let answers = await ask(batch.map(\.cleaned)) else { break }
            for (song, match) in zip(batch, answers) {
                let id = match.spotifyTrackIDs.first
                cache.store(Stored(id: id), forKey: "spotify-id:v1:" + song.cleaned.cacheKey, onDisk: true, now: clock())
                if let id { found[song] = id }
            }
        }
        return found
    }

    /// One batch; `nil` when the service did not answer usefully.
    private func ask(_ queries: [SongQuery]) async -> [Match]? {
        do {
            try await throttle.acquire()
            let (data, status) = try await fetcher.post(Self.endpoint, json: try Self.requestBody(queries))
            if status == 429 {
                await throttle.backOff(for: 30)
                return nil
            }
            guard status == 200 else {
                Self.log.notice("Spotify ID lookup answered \(status)")
                return nil
            }
            let answers = try Self.decode(data)
            // The service answers in request order, one entry per song.
            guard answers.count == queries.count else { return nil }
            return answers
        } catch {
            Self.log.debug("Spotify ID lookup failed: \(error)")
            return nil
        }
    }
}
