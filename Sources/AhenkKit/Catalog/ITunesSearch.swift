import Foundation

/// A song from Apple's public iTunes Search API.
public struct ITunesSong: Sendable, Equatable, Decodable {
    public var trackId: Int?
    public var trackName: String
    public var artistName: String
    public var collectionName: String?
    public var trackTimeMillis: Int?
    public var artworkUrl100: String?
    public var trackViewUrl: String?

    public init(
        trackId: Int? = nil, trackName: String, artistName: String, collectionName: String? = nil,
        trackTimeMillis: Int? = nil, artworkUrl100: String? = nil, trackViewUrl: String? = nil
    ) {
        self.trackId = trackId
        self.trackName = trackName
        self.artistName = artistName
        self.collectionName = collectionName
        self.trackTimeMillis = trackTimeMillis
        self.artworkUrl100 = artworkUrl100
        self.trackViewUrl = trackViewUrl
    }

    public var duration: TimeInterval? { trackTimeMillis.map { Double($0) / 1000 } }
}

/// Apple's public catalog (no account, no key): finds the catalog entry of
/// a song to get its cover in high resolution. Step 5 reuses it for albums
/// and search.
public struct ITunesSearch: Sendable {
    private let fetcher: any HTTPFetching
    private let storefront: @Sendable () -> String

    /// `storefront` returns the two-letter store country (the setting, or
    /// the Mac's region).
    public init(fetcher: any HTTPFetching, storefront: @escaping @Sendable () -> String) {
        self.fetcher = fetcher
        self.storefront = storefront
    }

    public static func searchURL(term: String, country: String, limit: Int = 8) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return components?.url
    }

    public static func parse(_ data: Data) throws -> [ITunesSong] {
        struct Response: Decodable {
            var results: [Lenient]
        }
        // One malformed result must not hide the others.
        struct Lenient: Decodable {
            var song: ITunesSong?
            init(from decoder: Decoder) throws {
                song = try? ITunesSong(from: decoder)
            }
        }
        return try JSONDecoder().decode(Response.self, from: data).results.compactMap(\.song)
    }

    /// The catalog song that is clearly the same as `track`, or `nil`.
    ///
    /// Title and artist must match after normalization (decorations such
    /// as "(feat. …)" or "- Remastered" do not count; one artist list may
    /// contain the other). A known duration more than 8 s off rules a
    /// candidate out; close durations and the same album rank higher.
    public static func bestMatch(for track: Track, in songs: [ITunesSong]) -> ITunesSong? {
        let title = TrackMatching.coreTitle(track.title)
        let artist = TrackMatching.normalized(track.artist)
        let album = TrackMatching.normalized(track.album)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var best: (song: ITunesSong, score: Double)?
        for song in songs {
            let candidateTitle = TrackMatching.coreTitle(song.trackName)
            let candidateArtist = TrackMatching.normalized(song.artistName)
            let titleScore: Double
            if candidateTitle == title {
                titleScore = 1
            } else if candidateTitle.hasPrefix(title + " ") || title.hasPrefix(candidateTitle + " ") {
                titleScore = 0.8
            } else {
                continue
            }
            let artistScore: Double
            if candidateArtist == artist {
                artistScore = 1
            } else if contains(words: artist, in: candidateArtist) || contains(words: candidateArtist, in: artist) {
                artistScore = 0.8
            } else {
                continue
            }
            var score = titleScore + artistScore
            if track.duration > 0, let duration = song.duration {
                let difference = abs(duration - track.duration)
                if difference > 8 { continue }
                if difference <= 3 { score += 0.4 }
            }
            if !album.isEmpty, TrackMatching.normalized(song.collectionName ?? "") == album {
                score += 0.3
            }
            if best.map({ score > $0.score }) ?? true {
                best = (song, score)
            }
        }
        return best?.song
    }

    /// `artworkUrl100` resized: the catalog serves any size up to the
    /// original through the `NxNbb` path component.
    public static func artworkURL(for song: ITunesSong, pixelSize: Int) -> URL? {
        guard let small = song.artworkUrl100 else { return nil }
        let side = max(100, min(3000, pixelSize))
        let resized = small.replacingOccurrences(
            of: #"/\d+x\d+(bb|cc|sr)?\.(jpg|png|webp)$"#,
            with: "/\(side)x\(side)bb.jpg",
            options: .regularExpression
        )
        return URL(string: resized)
    }

    public enum Lookup: Sendable, Equatable {
        case found(URL)
        /// The catalog answered and has no matching song.
        case notFound
        /// No answer (offline, rate limited); worth asking again later.
        case failed
    }

    /// Searches the catalog for `track` and returns the match's cover URL.
    public func lookupArtwork(for track: Track, pixelSize: Int) async -> Lookup {
        guard let url = Self.searchURL(term: Self.searchTerm(for: track), country: storefront()) else { return .notFound }
        guard let (data, status) = try? await fetcher.get(url), status == 200,
              let songs = try? Self.parse(data)
        else { return .failed }
        guard let match = Self.bestMatch(for: track, in: songs),
              let artwork = Self.artworkURL(for: match, pixelSize: pixelSize)
        else { return .notFound }
        return .found(artwork)
    }

    /// "Artist Title", without bracketed decorations that narrow the search.
    public static func searchTerm(for track: Track) -> String {
        let title = track.title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return [track.artist, title.isEmpty ? track.title : title]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when every word of `needle` appears in `haystack` in order
    /// ("artist" in "artist and friend").
    private static func contains(words needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return (" " + haystack + " ").contains(" " + needle + " ")
    }
}

/// Spotify's public oEmbed endpoint: the cover of a track by its ID, no
/// account or permission needed.
public enum SpotifyOEmbed {
    /// The base-62 track ID from `spotify:track:ID` or an open.spotify.com URL.
    public static func trackID(from identifier: String) -> String? {
        if identifier.hasPrefix("spotify:track:") {
            let id = String(identifier.dropFirst("spotify:track:".count))
            return isTrackID(id) ? id : nil
        }
        if let url = URL(string: identifier), url.host == "open.spotify.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let index = parts.firstIndex(of: "track"), index + 1 < parts.count, isTrackID(parts[index + 1]) {
                return parts[index + 1]
            }
        }
        return nil
    }

    public static func requestURL(trackID: String) -> URL? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(trackID)")]
        return components?.url
    }

    public static func thumbnailURL(from data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["thumbnail_url"] as? String
        else { return nil }
        return URL(string: text)
    }

    /// Spotify's covers come in 64, 300 and 640 px variants that differ
    /// only in a size code inside the image ID; this asks for 640 px.
    public static func largeVariant(of url: URL) -> URL {
        let text = url.absoluteString
        for small in ["ab67616d00001e02", "ab67616d00004851"] where text.contains(small) {
            return URL(string: text.replacingOccurrences(of: small, with: "ab67616d0000b273")) ?? url
        }
        return url
    }

    private static func isTrackID(_ text: String) -> Bool {
        text.count == 22 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
