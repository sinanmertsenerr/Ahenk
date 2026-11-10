import Foundation

/// Search as Apple Music's own app does it: the store's ranking (what
/// people there play comes first, so a Turkish store answers with Turkish
/// music), a best match, artists with their pictures, albums and songs.
/// The older iTunes Search API, which `base` uses, matches words without
/// knowing what is played and misses new releases; it stays for everything
/// else (albums of an artist, songs of an album) and as the fallback when
/// this search cannot be reached.
///
/// Read with the web player's anonymous token (see ``MotionArtworkFinder``):
/// no account, no key of Ahenk's. The catalog's numbers are the same as the
/// iTunes API's, so results open the same album and artist pages.
public final class AppleMusicSearchCatalog: MusicCatalog {
    /// The most the catalog gives per kind in one answer.
    public static let pageSize = 25
    static let lifetime: TimeInterval = 3_600

    private let base: any MusicCatalog
    private let fetcher: any HTTPFetching
    private let storefront: @Sendable () -> String
    private let tokens: MotionArtworkFinder
    private let cache: CatalogCache
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "catalog")

    public init(
        base: any MusicCatalog,
        fetcher: any HTTPFetching,
        storefront: @escaping @Sendable () -> String,
        tokens: MotionArtworkFinder,
        cache: CatalogCache = CatalogCache(directory: nil),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.fetcher = fetcher
        self.storefront = storefront
        self.tokens = tokens
        self.cache = cache
        self.clock = clock
    }

    public func search(_ term: String, limit: Int) async throws -> CatalogSearchResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CatalogSearchResults() }
        let country = storefront().lowercased()
        let key = "am-search:v1:\(country):\(limit):\(trimmed.lowercased())"
        if let cached = cache.value(CatalogSearchResults.self, forKey: key, maxAge: Self.lifetime, now: clock()) {
            return cached
        }
        guard var results = await page(term: trimmed, country: country, offset: 0), !results.isEmpty else {
            return try await base.search(trimmed, limit: limit)
        }
        // A second page of songs, when more are wanted than one page holds.
        if limit > Self.pageSize, results.songs.count >= Self.pageSize,
           let more = await page(term: trimmed, country: country, offset: Self.pageSize, songsOnly: true) {
            for song in more.songs where !results.songs.contains(where: { $0.id == song.id }) {
                results.songs.append(song)
            }
        }
        results.songs = Array(results.songs.prefix(max(1, limit)))
        cache.store(results, forKey: key, onDisk: false, now: clock())
        return results
    }

    public func artist(for track: Track) async throws -> CatalogArtistMatch? {
        try await base.artist(for: track)
    }

    public func albums(of artist: CatalogArtist) async throws -> [CatalogAlbum] {
        try await base.albums(of: artist)
    }

    public func songs(of album: CatalogAlbum) async throws -> [CatalogSong] {
        try await base.songs(of: album)
    }

    public func topSongs(of artist: CatalogArtist, limit: Int) async throws -> [CatalogSong] {
        try await base.topSongs(of: artist, limit: limit)
    }

    // MARK: Requests

    public static func searchURL(term: String, country: String, offset: Int, songsOnly: Bool) -> URL? {
        guard country.count == 2, country.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(country.lowercased())/search")
        var items = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: songsOnly ? "songs" : "songs,albums,artists"),
            URLQueryItem(name: "limit", value: String(pageSize)),
        ]
        if offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        if !songsOnly { items.append(URLQueryItem(name: "with", value: "topResults")) }
        components?.queryItems = items
        return components?.url
    }

    private func page(term: String, country: String, offset: Int, songsOnly: Bool = false) async -> CatalogSearchResults? {
        guard let url = Self.searchURL(term: term, country: country, offset: offset, songsOnly: songsOnly) else { return nil }
        for attempt in 0..<2 {
            guard let token = await tokens.catalogToken() else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            guard let (data, status) = try? await fetcher.send(request) else { return nil }
            switch status {
            case 200:
                return Self.results(from: data)
            case 401 where attempt == 0, 403 where attempt == 0:
                await tokens.catalogTokenRefused()
            default:
                Self.log.info("The catalog's search answered \(status); using the older search")
                return nil
            }
        }
        return nil
    }

    // MARK: Reading the answer

    /// The answer's songs, albums, artists and best match; `nil` when it
    /// is not the catalog's answer.
    public static func results(from data: Data) -> CatalogSearchResults? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any]
        else { return nil }
        func items(_ key: String) -> [[String: Any]] {
            ((results[key] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        }
        let top = items("topResults").lazy.compactMap { item -> CatalogTopResult? in
            switch item["type"] as? String {
            case "artists": return artist(item).map(CatalogTopResult.artist)
            case "songs": return song(item).map(CatalogTopResult.song)
            case "albums": return album(item).map(CatalogTopResult.album)
            default: return nil
            }
        }.first
        return CatalogSearchResults(
            songs: items("songs").compactMap(song), albums: items("albums").compactMap(album),
            artists: items("artists").compactMap(artist), top: top
        )
    }

    private static func number(_ item: [String: Any]) -> String? {
        guard let id = item["id"] as? String, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    /// "…/{w}x{h}bb.jpg" → a cover the app can ask for at any size.
    static func artwork(_ attributes: [String: Any], square: Bool = false) -> CatalogArtwork? {
        guard let template = (attributes["artwork"] as? [String: Any])?["url"] as? String, template.hasPrefix("https://") else { return nil }
        var address = template
        if square {
            // Artists' pictures are not square: cut them round their centre.
            address = address.replacingOccurrences(of: #"\{w\}x\{h\}[a-z]*\.[a-z{}]+$"#, with: "100x100cc.jpg", options: .regularExpression)
        }
        address = address
            .replacingOccurrences(of: "{w}x{h}", with: "100x100")
            .replacingOccurrences(of: "{c}", with: "bb")
            .replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: address).map { .remote($0) }
    }

    static func artist(_ item: [String: Any]) -> CatalogArtist? {
        guard let id = number(item), let attributes = item["attributes"] as? [String: Any],
              let name = attributes["name"] as? String, !name.isEmpty
        else { return nil }
        return CatalogArtist(
            id: "itunes:artist:\(id)", name: name, genre: (attributes["genreNames"] as? [String])?.first,
            url: (attributes["url"] as? String).flatMap(URL.init(string:)), artwork: artwork(attributes, square: true)
        )
    }

    static func album(_ item: [String: Any]) -> CatalogAlbum? {
        guard let id = number(item), let attributes = item["attributes"] as? [String: Any],
              let name = attributes["name"] as? String, !name.isEmpty
        else { return nil }
        var (title, kind) = ITunesCatalog.albumTitle(name, collectionType: (attributes["isCompilation"] as? Bool) == true ? "Compilation" : nil)
        if kind == .album, (attributes["isSingle"] as? Bool) == true { kind = .single }
        return CatalogAlbum(
            id: "itunes:album:\(id)", title: title, artistName: attributes["artistName"] as? String ?? "",
            // A day without a time ("2026-01-23"): noon, so the year holds everywhere.
            releaseDate: (attributes["releaseDate"] as? String).flatMap { CatalogDates.parse($0.count == 10 ? $0 + "T12:00:00Z" : $0) },
            trackCount: attributes["trackCount"] as? Int ?? 0, kind: kind,
            isExplicit: (attributes["contentRating"] as? String) == "explicit",
            artwork: artwork(attributes), url: (attributes["url"] as? String).flatMap(URL.init(string:))
        )
    }

    static func song(_ item: [String: Any]) -> CatalogSong? {
        guard let id = number(item), let attributes = item["attributes"] as? [String: Any],
              let name = attributes["name"] as? String, !name.isEmpty
        else { return nil }
        let url = (attributes["url"] as? String).flatMap(URL.init(string:))
        // The song's page is its album's, with `?i=` naming the song.
        let albumNumber = url.map(\.lastPathComponent).flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil }
        return CatalogSong(
            id: "itunes:song:\(id)", title: name, artistName: attributes["artistName"] as? String ?? "",
            albumTitle: attributes["albumName"] as? String ?? "", albumID: albumNumber.map { "itunes:album:\($0)" },
            duration: ((attributes["durationInMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            trackNumber: attributes["trackNumber"] as? Int, discNumber: attributes["discNumber"] as? Int,
            isExplicit: (attributes["contentRating"] as? String) == "explicit",
            artwork: artwork(attributes), url: url
        )
    }
}
