import Foundation

/// The last fallback: NetEase Cloud Music, a large synced catalog, free and
/// keyless. Only a song whose title matches (and whose artist matches when
/// one is known) is taken; any failure is "not found".
public struct NetEaseProvider: LyricsProvider {
    public let name = "NetEase"
    public let reliability = 60

    private let http: any HTTPFetching
    private let base = URL(string: "https://music.163.com")!

    public init(http: any HTTPFetching) {
        self.http = http
    }

    struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable, Equatable {
            let id: Int
            let name: String
            let artists: [Artist]?
            let album: Album?
            /// Milliseconds, as `duration` or `dt`.
            let duration: Double?

            private enum CodingKeys: String, CodingKey {
                case id, name, artists, album, duration, dt
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(Int.self, forKey: .id)
                name = try container.decode(String.self, forKey: .name)
                artists = try container.decodeIfPresent([Artist].self, forKey: .artists)
                album = try container.decodeIfPresent(Album.self, forKey: .album)
                let raw = try container.decodeIfPresent(Double.self, forKey: .duration)
                    ?? container.decodeIfPresent(Double.self, forKey: .dt)
                duration = raw.map { $0 > 10_000 ? $0 / 1000 : $0 }
            }
        }
        struct Artist: Decodable, Equatable { let name: String }
        struct Album: Decodable, Equatable { let name: String? }
        let result: Result?
    }

    struct LyricResponse: Decodable {
        struct Lrc: Decodable { let lyric: String? }
        let lrc: Lrc?
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        guard let song = try await matchingSongs(query).first else { return .notFound }
        return try await lyrics(id: song.id)
    }

    public func versions(for query: LyricsQuery) async throws -> [LyricsVersion] {
        var versions: [LyricsVersion] = []
        for song in try await matchingSongs(query).prefix(3) {
            let result = try await lyrics(id: song.id)
            guard result.hasLyrics else { continue }
            versions.append(version(song, result: result))
        }
        return versions
    }

    public func search(_ query: LyricsQuery) async throws -> [LyricsVersion] {
        try await songs(query).prefix(8).map { version($0, result: nil) }
    }

    public func lyrics(of version: LyricsVersion) async throws -> LyricsResult {
        if let lyrics = version.lyrics { return lyrics }
        guard let id = Int(version.reference) else { return .notFound }
        return try await lyrics(id: id)
    }

    private func version(_ song: SearchResponse.Song, result: LyricsResult?) -> LyricsVersion {
        LyricsVersion(
            provider: name, reference: String(song.id), title: song.name,
            artist: (song.artists ?? []).map(\.name).joined(separator: ", "), album: song.album?.name,
            duration: song.duration, kind: result.map(LyricsVersion.kind(of:)) ?? .unknown, lyrics: result
        )
    }

    /// Songs whose title matches, those with a matching artist first.
    private func matchingSongs(_ query: LyricsQuery) async throws -> [SearchResponse.Song] {
        let songs = try await songs(query)
        let wantedTitle = LyricsQuery.matchText(query.title)
        let wantedArtist = LyricsQuery.matchText(query.artist)
        func artistMatches(_ song: SearchResponse.Song) -> Bool {
            guard !wantedArtist.isEmpty, let artists = song.artists, !artists.isEmpty else { return true }
            return artists.contains {
                let name = LyricsQuery.matchText($0.name)
                return wantedArtist.contains(name) || name.contains(wantedArtist)
            }
        }
        let titleHits = songs.filter {
            LyricsQuery.matchText($0.name) == wantedTitle && $0.duration.map(query.durationMatches) != false
        }
        if wantedArtist.isEmpty { return titleHits }
        return titleHits.filter(artistMatches)
    }

    private func songs(_ query: LyricsQuery) async throws -> [SearchResponse.Song] {
        let term = [query.title, query.artist].filter { !$0.isEmpty }.joined(separator: " ")
        // `/api/search/get`, not `/web`: the latter answers with an
        // encrypted blob.
        guard var components = URLComponents(url: base.appendingPathComponent("/api/search/get"), resolvingAgainstBaseURL: false) else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "s", value: term),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        guard let request = makeRequest(components) else { return [] }
        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status) else { return [] }
        return (try JSONDecoder().decode(SearchResponse.self, from: data)).result?.songs ?? []
    }

    private func lyrics(id: Int) async throws -> LyricsResult {
        guard var components = URLComponents(url: base.appendingPathComponent("/api/song/lyric"), resolvingAgainstBaseURL: false) else {
            return .notFound
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        guard let request = makeRequest(components) else { return .notFound }
        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status) else { return .notFound }
        guard let raw = (try JSONDecoder().decode(LyricResponse.self, from: data)).lrc?.lyric,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .notFound }
        // Credits ("作词 : …") come as timed lines at the top; they are not lyrics.
        let lrc = Self.stripCredits(raw)
        let parsed = LRCParser.parse(lrc)
        if parsed.lines.contains(where: { !$0.text.isEmpty }) { return .synced(parsed) }
        let plain = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? .notFound : .plain(plain)
    }

    /// Credit keys NetEase ships as timed lines, matched before the first
    /// colon (half or full width).
    private static let creditKeys: Set<String> = [
        "作词", "作曲", "编曲", "制作", "制作人", "出品", "出品人", "监制", "混音",
        "母带", "和声", "录音", "配唱", "配唱制作人", "吉他", "贝斯", "鼓", "弦乐",
        "键盘", "提琴", "钢琴", "统筹", "企划", "策划", "发行", "艺人统筹",
        "producer", "produced by", "mixed by", "mastered by", "written by",
        "composed by", "arranged by", "lyrics by", "music by", "mixing",
        "mastering", "recording", "vocal", "vocals", "guitar", "bass",
    ]

    static func stripCredits(_ lrc: String) -> String {
        lrc.components(separatedBy: .newlines).filter { line in
            let content = line.lastIndex(of: "]").map { String(line[line.index(after: $0)...]) } ?? line
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return true }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            return !creditKeys.contains(key)
        }.joined(separator: "\n")
    }

    private func makeRequest(_ components: URLComponents) -> URLRequest? {
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
