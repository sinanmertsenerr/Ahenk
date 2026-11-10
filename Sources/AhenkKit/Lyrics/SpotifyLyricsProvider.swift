import Foundation

/// Spotify's own lyrics, the ones its apps show, for a user signed in to
/// Spotify in Ahenk (see ``SpotifyRemote``): asked by the track's ID with
/// the web player's session, so they belong to the exact recording that
/// plays and are timed for it.
///
/// Two of these are in the chain. The first answers only songs that come
/// from Spotify (their ID is known): it goes before every other provider.
/// The second answers songs from other sources, whose Spotify ID has to be
/// looked up by title and artist and may be another edit of the song: it
/// goes last, for songs nobody else has lyrics for, and only answers when
/// Spotify's recording is as long as the song that plays.
public final class SpotifyLyricsProvider: LyricsProvider, Sendable {
    public static let providerName = "Spotify"
    public let name = SpotifyLyricsProvider.providerName
    public var reliability: Int { exactOnly ? 110 : 60 }
    public var supportsCanonicalSpotifyLookup: Bool { exactOnly }

    /// Answers songs that carry their Spotify ID, and no others (else the
    /// other way round).
    private let exactOnly: Bool
    private let session: @Sendable () async -> SpotifyRemote.Session?
    private let findTrackID: @Sendable (LyricsQuery) async -> String?
    private let fetcher: any HTTPFetching

    public init(
        exactOnly: Bool, fetcher: any HTTPFetching,
        session: @escaping @Sendable () async -> SpotifyRemote.Session?,
        findTrackID: @escaping @Sendable (LyricsQuery) async -> String? = { _ in nil }
    ) {
        self.exactOnly = exactOnly
        self.fetcher = fetcher
        self.session = session
        self.findTrackID = findTrackID
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        try await fetchResponse(query).result
    }

    public func fetchResponse(_ query: LyricsQuery) async throws -> LyricsResponse {
        let missing = LyricsResponse(result: .notFound, source: name)
        guard exactOnly == (query.spotifyTrackID != nil) else { return missing }
        guard let session = await session() else { return missing }
        let known = query.spotifyTrackID
        let found = known == nil ? await findTrackID(query) : nil
        guard let id = known ?? found, let request = Self.request(session: session, trackID: id) else { return missing }
        // A song found by title and artist must be as long as the one
        // that plays: a music video with an intro runs ahead of the
        // album's recording, and Spotify's lines would come late.
        if known == nil {
            guard let playing = query.duration, playing > 0, let length = await trackLength(id), abs(length - playing) <= Self.lengthTolerance
            else { return missing }
        }
        let (data, status) = try await fetcher.send(request)
        guard status == 200 else { return missing }
        return LyricsResponse(
            result: Self.result(fromJSON: data), source: name,
            timingAuthority: known != nil ? .canonicalRecording : .providerMatched
        )
    }

    /// How far the playing song and Spotify's recording may differ.
    static let lengthTolerance: TimeInterval = 2

    /// The recording's length, from Spotify's public embed page.
    private func trackLength(_ id: String) async -> TimeInterval? {
        guard SpotifyAppScripts.isBase62ID(id), let url = URL(string: "https://open.spotify.com/embed/track/\(id)"),
              let (data, status) = try? await fetcher.get(url), status == 200
        else { return nil }
        return Self.length(inEmbedPage: String(decoding: data, as: UTF8.self))
    }

    /// `"duration":183126` (milliseconds) in the embed page's data.
    static func length(inEmbedPage html: String) -> TimeInterval? {
        guard let range = html.range(of: #""duration":(\d{4,8})"#, options: .regularExpression) else { return nil }
        let digits = html[range].filter(\.isNumber)
        return Double(digits).map { $0 / 1000 }
    }

    // MARK: The request and its answer

    static func request(session: SpotifyRemote.Session, trackID: String) -> URLRequest? {
        guard SpotifyAppScripts.isBase62ID(trackID),
              let url = URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)?format=json&vocalRemoval=false&market=from_token")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let clientToken = session.clientToken { request.setValue(clientToken, forHTTPHeaderField: "client-token") }
        request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `{"lyrics": {"syncType": "LINE_SYNCED", "lines": [{"startTimeMs":
    /// "25890", "words": "…"}]}}`. Lines without words (and the "♪" Spotify
    /// puts in pauses) are left out; untimed lyrics come back as text.
    static func result(fromJSON data: Data) -> LyricsResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = object["lyrics"] as? [String: Any],
              let rows = lyrics["lines"] as? [[String: Any]]
        else { return .notFound }
        var lines: [LyricLine] = []
        var texts: [String] = []
        for row in rows {
            let text = (row["words"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "\u{266A}" else { continue }
            texts.append(text)
            let stamp = (row["startTimeMs"] as? String).flatMap(Double.init) ?? (row["startTimeMs"] as? NSNumber)?.doubleValue
            if let stamp { lines.append(LyricLine(start: stamp / 1000, text: text)) }
        }
        guard !texts.isEmpty else { return .notFound }
        let synced = (lyrics["syncType"] as? String ?? "").uppercased().contains("SYNCED") && (lyrics["syncType"] as? String ?? "").uppercased() != "UNSYNCED"
        // Timed for real: more than one distinct start.
        if synced, lines.count == texts.count, Set(lines.map(\.start)).count > 1 {
            return .synced(SyncedLyrics(lines: lines))
        }
        return .plain(texts.joined(separator: "\n"))
    }
}
