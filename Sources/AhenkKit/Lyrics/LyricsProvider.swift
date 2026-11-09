import Foundation

/// What is known about a song when asking a provider for lyrics.
public struct LyricsQuery: Sendable, Equatable, Hashable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?
    /// Spotify's ID of the exact recording (the 22 characters after
    /// `spotify:track:`), when the source exposes it. Unlike title and
    /// artist, it names the very master whose timing Spotify plays.
    public var spotifyTrackID: String?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil, spotifyTrackID: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.spotifyTrackID = Self.normalizedSpotifyTrackID(spotifyTrackID)
    }

    public init(track: Track) {
        let spotify = track.source == .spotify || track.source == .spotifyWeb
        self.init(
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            duration: track.duration > 0 ? track.duration : nil,
            spotifyTrackID: spotify ? track.id : nil
        )
    }

    /// The song's identity for the lyrics cache and the per-song store
    /// (offsets, chosen versions). A Spotify ID outranks the metadata.
    public var cacheKey: String {
        if let spotifyTrackID {
            return ["lyrics-v3", "spotify", spotifyTrackID].joined(separator: "\u{1}")
        }
        let seconds = duration.map { String(Int($0.rounded())) } ?? "unknown"
        return [
            "lyrics-v2",
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            seconds,
        ].joined(separator: "\u{1}")
    }

    /// The query without the noise that breaks exact lookups: "(feat. …)",
    /// "[Explicit]", "- Remastered 2011", "- Live".
    public var sanitized: LyricsQuery {
        LyricsQuery(
            title: Self.cleanTitle(title),
            artist: Self.cleanArtist(artist),
            album: album.map(Self.cleanArtist),
            duration: duration,
            spotifyTrackID: spotifyTrackID
        )
    }

    /// Accepts the forms Spotify uses (URI, URL, bare ID); anything else
    /// (local files, episodes, adverts) is no recording ID.
    static func normalizedSpotifyTrackID(_ raw: String?) -> String? {
        guard var candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { return nil }
        if candidate.hasPrefix("spotify:track:") {
            candidate = String(candidate.dropFirst("spotify:track:".count))
        } else if let url = URL(string: candidate), let index = url.pathComponents.firstIndex(of: "track"),
                  url.pathComponents.indices.contains(index + 1) {
            candidate = url.pathComponents[index + 1]
        }
        candidate = candidate.components(separatedBy: "?").first ?? candidate
        guard candidate.count == 22,
              candidate.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return candidate
    }

    public static func cleanArtist(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "\\s*(feat\\.|ft\\.|featuring)\\s.*$", with: "", options: [.regularExpression, .caseInsensitive]
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func cleanTitle(_ text: String) -> String {
        var result = cleanArtist(text)
        result = result.replacingOccurrences(
            of: "\\s*-\\s*(Remaster(ed)?|Live|Single|Radio|Mono|Stereo|Deluxe|Bonus|Acoustic|Demo|Anniversary|Version|Edit).*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The form used to compare titles and artists between providers:
    /// case, accents and punctuation folded, locale-neutral (a Turkish
    /// locale would fold "I" to "ı"), the Turkish "ı" read as "i".
    public static func matchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lengths of one recording differ by a fraction of a second between
    /// catalogs; LRCLIB documents ±2 s, and beyond that it is another edit.
    public func durationMatches(_ candidate: TimeInterval) -> Bool {
        guard let duration, duration > 0, candidate > 0 else { return true }
        return abs(duration - candidate) <= 2
    }
}

/// Outcome of one provider's lookup.
public enum LyricsResult: Sendable, Equatable, Codable {
    case synced(SyncedLyrics)
    case plain(String)
    case instrumental
    case notFound

    /// True when this carries lyrics to show (synced or plain).
    public var hasLyrics: Bool {
        switch self {
        case .synced, .plain: true
        case .instrumental, .notFound: false
        }
    }
}

/// How strongly a provider proved that its timestamps belong to the exact
/// recording that plays. Only a canonical match turns automatic timing
/// correction off.
public enum LyricsTimingAuthority: String, Codable, Sendable, Equatable {
    case unverified
    case providerMatched
    case canonicalRecording

    public var allowsAutomaticCorrection: Bool { self != .canonicalRecording }
}

/// The lyrics a lookup found and who answered.
public struct LyricsResponse: Sendable, Equatable, Codable {
    public var result: LyricsResult
    public var source: String
    public var timingAuthority: LyricsTimingAuthority

    public init(result: LyricsResult, source: String, timingAuthority: LyricsTimingAuthority = .unverified) {
        self.result = result
        self.source = source
        self.timingAuthority = timingAuthority
    }

    public static let none = LyricsResponse(result: .notFound, source: "none")

    private enum CodingKeys: String, CodingKey {
        case result, source, timingAuthority
    }

    /// Entries without provenance decode as unverified: still shown, never
    /// claiming canonical timing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(LyricsResult.self, forKey: .result)
        source = try container.decode(String.self, forKey: .source)
        timingAuthority = try container.decodeIfPresent(LyricsTimingAuthority.self, forKey: .timingAuthority) ?? .unverified
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result, forKey: .result)
        try container.encode(source, forKey: .source)
        try container.encode(timingAuthority, forKey: .timingAuthority)
    }
}

/// One version of a song's lyrics a provider offers: the choices behind
/// "Other Lyrics" and the results of "Search Lyrics".
public struct LyricsVersion: Sendable, Equatable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case synced
        case plain
        case instrumental
        /// Known only once loaded (a listing without the lyrics).
        case unknown
    }

    /// `provider` + `reference`: unique across providers.
    public var id: String { "\(provider)\u{1}\(reference)" }
    /// `LyricsProvider.name` of the provider that lists it.
    public var provider: String
    /// The provider's own ID for the version (loads it again later).
    public var reference: String
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?
    public var kind: Kind
    /// The lyrics, when the listing already carried them.
    public var lyrics: LyricsResult?

    public init(
        provider: String, reference: String, title: String, artist: String, album: String? = nil,
        duration: TimeInterval? = nil, kind: Kind, lyrics: LyricsResult? = nil
    ) {
        self.provider = provider
        self.reference = reference
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.kind = kind
        self.lyrics = lyrics
    }

    /// Number of timed lines, when known.
    public var lineCount: Int? {
        if case .synced(let lyrics) = lyrics { return lyrics.lines.count }
        return nil
    }

    /// The same version without its lyrics (what the per-song store keeps).
    public var withoutLyrics: LyricsVersion {
        var copy = self
        copy.lyrics = nil
        return copy
    }

    public static func kind(of result: LyricsResult) -> Kind {
        switch result {
        case .synced: .synced
        case .plain: .plain
        case .instrumental: .instrumental
        case .notFound: .unknown
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(reference)
    }

    public static func == (lhs: LyricsVersion, rhs: LyricsVersion) -> Bool {
        lhs.provider == rhs.provider && lhs.reference == rhs.reference && lhs.title == rhs.title
            && lhs.artist == rhs.artist && lhs.album == rhs.album && lhs.duration == rhs.duration
            && lhs.kind == rhs.kind && lhs.lyrics == rhs.lyrics
    }
}

public enum LyricsError: Error, Equatable, Sendable {
    case http(Int)
    case malformed
}

/// A lyrics source (LRCLIB, Musixmatch, NetEase, the demo). Implementations
/// must be safe to call concurrently.
public protocol LyricsProvider: Sendable {
    /// Stable identifier for logs, settings (`disabledProviders`) and for
    /// labelling which source answered.
    var name: String { get }
    /// Relative trust, higher is better; diagnostics only (the chain's
    /// order decides precedence).
    var reliability: Int { get }
    /// True when this provider can verify a response against
    /// `LyricsQuery.spotifyTrackID`; the chain then waits for it before a
    /// faster fuzzy result may win a Spotify lookup.
    var supportsCanonicalSpotifyLookup: Bool { get }
    /// True for a provider that answers from memory at once with lyrics the
    /// playing source itself supplied (a music site's own lyrics): the
    /// finder asks it before the cache.
    var answersFromMemory: Bool { get }
    func fetch(_ query: LyricsQuery) async throws -> LyricsResult
    /// Provenance-aware form the chain uses.
    func fetchResponse(_ query: LyricsQuery) async throws -> LyricsResponse
    /// Every version this provider has for the song ("Other Lyrics").
    func versions(for query: LyricsQuery) async throws -> [LyricsVersion]
    /// A free search by title and artist ("Search Lyrics").
    func search(_ query: LyricsQuery) async throws -> [LyricsVersion]
    /// The lyrics of a version from `versions` or `search`.
    func lyrics(of version: LyricsVersion) async throws -> LyricsResult
}

public extension LyricsProvider {
    var reliability: Int { 0 }
    var supportsCanonicalSpotifyLookup: Bool { false }
    var answersFromMemory: Bool { false }

    func fetchResponse(_ query: LyricsQuery) async throws -> LyricsResponse {
        LyricsResponse(result: try await fetch(query), source: name)
    }

    /// One version: whatever `fetch` finds.
    func versions(for query: LyricsQuery) async throws -> [LyricsVersion] {
        let result = try await fetch(query)
        guard result.hasLyrics || result == .instrumental else { return [] }
        return [LyricsVersion(
            provider: name, reference: query.cacheKey, title: query.title, artist: query.artist,
            album: query.album, duration: query.duration, kind: LyricsVersion.kind(of: result), lyrics: result
        )]
    }

    func search(_ query: LyricsQuery) async throws -> [LyricsVersion] {
        try await versions(for: query)
    }

    func lyrics(of version: LyricsVersion) async throws -> LyricsResult {
        if let lyrics = version.lyrics { return lyrics }
        return try await fetch(LyricsQuery(title: version.title, artist: version.artist, album: version.album, duration: version.duration))
    }
}
