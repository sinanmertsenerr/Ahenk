import Foundation

/// The first lyrics source: lrclib.net, free, no key, line-level LRC. The
/// exact `/api/get` match and the fuzzy `/api/search` run together; with
/// three or more synced uploads the timelines vote (`LyricsConsensus`).
public struct LRCLIBProvider: LyricsProvider {
    public let name = "LRCLIB"
    public let reliability = 100

    private let http: any HTTPFetching
    private let baseURL: URL

    public init(http: any HTTPFetching, baseURL: URL = URL(string: "https://lrclib.net")!) {
        self.http = http
        self.baseURL = baseURL
    }

    /// One row of LRCLIB's answers.
    struct Row: Decodable, Equatable {
        var id: Int?
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        // Both requests at once: one after the other could run out the
        // shared timeout and lose a usable plain answer.
        async let exactLookup = get(query)
        async let fuzzyLookup = search(query, scored: true)
        var firstError: Error?
        let exact: Row?
        do {
            exact = try await exactLookup
        } catch {
            exact = nil
            firstError = error
        }
        let fuzzy: [Scored]
        do {
            fuzzy = try await fuzzyLookup
        } catch {
            fuzzy = []
            if firstError == nil { firstError = error }
        }
        if exact == nil, fuzzy.isEmpty, let firstError { throw firstError }

        // With three or more independent synced uploads the majority
        // timeline outranks the metadata score (a copy synced against
        // another edit is voted out). Not when `/api/get` says
        // instrumental: search rows then describe a sung cut.
        if exact?.instrumental != true, let elected = consensusPick(exact: exact, fuzzy: fuzzy) {
            return .synced(elected)
        }

        // An exact row with plain lyrics only is the fallback while a
        // synced row may still be in the search results.
        var exactFallback: LyricsResult?
        if let exact {
            let value = Self.result(from: exact)
            switch value {
            case .synced, .instrumental: return value
            case .plain: exactFallback = value
            case .notFound: break
            }
        }
        if let best = fuzzy.max(by: { $0.score < $1.score }) {
            let value = Self.result(from: best.row)
            if case .synced = value { return value }
            return exactFallback ?? value
        }
        return exactFallback ?? .notFound
    }

    public func versions(for query: LyricsQuery) async throws -> [LyricsVersion] {
        async let exactLookup = get(query)
        async let fuzzyLookup = search(query, scored: true)
        let exact = try? await exactLookup
        let fuzzy = (try? await fuzzyLookup) ?? []
        var rows: [Row] = []
        if let exact { rows.append(exact) }
        for scored in fuzzy.sorted(by: { $0.score > $1.score }) where !rows.contains(where: { $0.id != nil && $0.id == scored.row.id }) {
            rows.append(scored.row)
        }
        return rows.compactMap(version(from:))
    }

    public func search(_ query: LyricsQuery) async throws -> [LyricsVersion] {
        let rows = try await search(query, scored: false)
        return rows.map(\.row).compactMap(version(from:))
    }

    public func lyrics(of version: LyricsVersion) async throws -> LyricsResult {
        if let lyrics = version.lyrics { return lyrics }
        guard let id = Int(version.reference) else { return .notFound }
        guard let request = makeRequest(path: "/api/get/\(id)", queryItems: []) else { return .notFound }
        let (data, status) = try await http.send(request)
        if status == 404 { return .notFound }
        guard (200..<300).contains(status) else { throw LyricsError.http(status) }
        return Self.result(from: try JSONDecoder().decode(Row.self, from: data))
    }

    // MARK: Rows

    static func result(from row: Row) -> LyricsResult {
        if row.instrumental == true { return .instrumental }
        if let synced = row.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = LRCParser.parse(synced)
            if parsed.lines.contains(where: { !$0.text.isEmpty }) { return .synced(parsed) }
        }
        if let plain = row.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(plain)
        }
        return .notFound
    }

    private func version(from row: Row) -> LyricsVersion? {
        let result = Self.result(from: row)
        guard result != .notFound, let id = row.id else { return nil }
        return LyricsVersion(
            provider: name, reference: String(id), title: row.trackName ?? "", artist: row.artistName ?? "",
            album: row.albumName.flatMap { $0.isEmpty ? nil : $0 }, duration: row.duration,
            kind: LyricsVersion.kind(of: result), lyrics: result
        )
    }

    /// Score of the `/api/get` row: above anything `score` gives, so it
    /// wins unless the timelines disagree.
    private static let exactMatchScore = 10_000

    private func consensusPick(exact: Row?, fuzzy: [Scored]) -> SyncedLyrics? {
        var pool = fuzzy
        if let exact {
            // The same upload usually shows up in the search too; it must
            // not vote twice.
            pool.removeAll { $0.row.id != nil && $0.row.id == exact.id }
            pool.insert(Scored(row: exact, score: Self.exactMatchScore), at: 0)
        }
        let synced: [LyricsConsensus.Candidate] = pool.compactMap { candidate in
            guard let raw = candidate.row.syncedLyrics, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let parsed = LRCParser.parse(raw)
            return parsed.isEmpty ? nil : .init(lyrics: parsed, score: candidate.score)
        }
        guard let index = LyricsConsensus.pick(synced) else { return nil }
        return synced[index].lyrics
    }

    // MARK: Requests

    /// `/api/get`: the exact match, or nil (404).
    private func get(_ query: LyricsQuery) async throws -> Row? {
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if let album = query.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = query.duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let request = makeRequest(path: "/api/get", queryItems: items) else { return nil }
        let (data, status) = try await http.send(request)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw LyricsError.http(status) }
        return try JSONDecoder().decode(Row.self, from: data)
    }

    struct Scored {
        let row: Row
        let score: Int
    }

    /// `/api/search`. Scored: rows are graded against title, artist, album
    /// and above all the length (the API's order puts live and radio edits
    /// first as often as not); rows of another length are dropped. Not
    /// scored (the user's own search): every row with lyrics, in order.
    private func search(_ query: LyricsQuery, scored: Bool) async throws -> [Scored] {
        var items: [URLQueryItem]
        if query.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            items = [URLQueryItem(name: "q", value: query.title)]
        } else {
            items = [
                URLQueryItem(name: "track_name", value: query.title),
                URLQueryItem(name: "artist_name", value: query.artist),
            ]
            // Never the album: the search then returns only rows filed
            // under that very album, and uploads often name it "Unknown" or
            // after the single. The score rewards a matching album instead.
        }
        guard let request = makeRequest(path: "/api/search", queryItems: items) else { return [] }
        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status) else {
            if status == 404 { return [] }
            throw LyricsError.http(status)
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let usable = rows.filter { $0.instrumental == true || $0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false }
        guard scored else {
            return usable.enumerated().map { Scored(row: $0.element, score: -$0.offset) }
        }
        let wantedTitle = LyricsQuery.matchText(query.title)
        let wantedArtist = LyricsQuery.matchText(query.artist)
        let wantedAlbum = query.album.map(LyricsQuery.matchText)
        return usable
            .filter { row in row.duration.map(query.durationMatches) ?? true }
            .enumerated()
            .map { Scored(row: $0.element, score: Self.score($0.element, index: $0.offset, query: query, title: wantedTitle, artist: wantedArtist, album: wantedAlbum)) }
    }

    static func score(_ row: Row, index: Int, query: LyricsQuery, title wantedTitle: String, artist wantedArtist: String, album wantedAlbum: String?) -> Int {
        var value = row.syncedLyrics?.isEmpty == false ? 40 : 0
        if let duration = row.duration, let wanted = query.duration {
            value += max(0, 100 - Int(abs(duration - wanted) * 20))
        }
        if let title = row.trackName.map(LyricsQuery.matchText) {
            if title == wantedTitle {
                value += 60
            } else if title.contains(wantedTitle) || wantedTitle.contains(title) {
                value += 25
            }
        }
        if let artist = row.artistName.map(LyricsQuery.matchText) {
            if artist == wantedArtist {
                value += 45
            } else if artist.contains(wantedArtist) || wantedArtist.contains(artist) {
                value += 15
            }
        }
        if let wantedAlbum, let album = row.albumName.map(LyricsQuery.matchText), album == wantedAlbum {
            value += 20
        }
        // Ties keep the server's order.
        return value - index
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem]) -> URLRequest? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        // LRCLIB asks clients to say who they are.
        request.setValue("Ahenk (https://github.com/sinanmertsenerr/Ahenk)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
