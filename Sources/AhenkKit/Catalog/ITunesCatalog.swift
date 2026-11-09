import Foundation
import os

/// Apple's public iTunes Search and Lookup API as a `MusicCatalog`: no
/// account, no key. Feeds the desktop player's cover flow (the artist's
/// albums), album and artist pages and search, for every source: Spotify
/// and the browser sites are searched here too, and a pick is played in the
/// chosen source by its title, artist and album.
///
/// Apple allows about 20 requests a minute, so answers are cached (albums
/// for a week, an album's songs and the artist of a song for a month, on
/// disk; searches for an hour, in memory), identical requests in flight are
/// shared, and `RequestThrottle` keeps the pace.
public final class ITunesCatalog: MusicCatalog, Sendable {
    public enum Entity: String, Sendable {
        case song
        case album
        case musicArtist
    }

    /// One result of a search or lookup.
    public enum Item: Hashable, Sendable {
        case artist(CatalogArtist)
        case album(CatalogAlbum)
        case song(CatalogSong)
    }

    public static let requestsPerMinute = 18
    static let albumsLifetime: TimeInterval = 7 * 86_400
    static let songsLifetime: TimeInterval = 30 * 86_400
    static let artistMatchLifetime: TimeInterval = 30 * 86_400
    static let missLifetime: TimeInterval = 3 * 86_400
    static let searchLifetime: TimeInterval = 3_600
    static let topSongsLifetime: TimeInterval = 86_400

    private let fetcher: any HTTPFetching
    private let storefront: @Sendable () -> String
    private let cache: CatalogCache
    private let throttle: RequestThrottle
    private let clock: @Sendable () -> Date
    private let inFlight = OSAllocatedUnfairLock(initialState: [String: Task<Data, any Error>]())
    private static let log = AhenkLogger(category: "catalog")

    /// `storefront` returns the two-letter store country (the setting, or
    /// the Mac's region).
    public init(
        fetcher: any HTTPFetching,
        storefront: @escaping @Sendable () -> String,
        cache: CatalogCache = CatalogCache(directory: nil),
        throttle: RequestThrottle = RequestThrottle(limit: ITunesCatalog.requestsPerMinute, per: 60),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.storefront = storefront
        self.cache = cache
        self.throttle = throttle
        self.clock = clock
    }

    // MARK: MusicCatalog

    public func search(_ term: String, limit: Int) async throws -> CatalogSearchResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CatalogSearchResults() }
        let country = storefront()
        let key = "search:v1:\(country.lowercased()):\(limit):\(trimmed.lowercased())"
        if let cached = cache.value(CatalogSearchResults.self, forKey: key, maxAge: Self.searchLifetime, now: clock()) {
            return cached
        }
        // Artists and songs in one request; albums come from the songs (a
        // mixed request returns albums only now and then).
        guard let url = Self.searchURL(term: trimmed, country: country, entities: [.musicArtist, .song], limit: max(limit, 25)) else {
            return CatalogSearchResults()
        }
        let results = Self.searchResults(from: try Self.rawResults(try await fetch(url)), limit: limit)
        cache.store(results, forKey: key, onDisk: false, now: clock())
        return results
    }

    public func artist(for track: Track) async throws -> CatalogArtistMatch? {
        let artistName = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistName.isEmpty else { return nil }
        let country = storefront()
        let key = "artist-of:v1:\(country.lowercased()):" + [
            TrackMatching.normalized(artistName), TrackMatching.coreTitle(track.title), TrackMatching.normalized(track.album),
        ].joined(separator: "|")
        if let known = cache.value(StoredMatch.self, forKey: key, maxAge: Self.missLifetime, now: clock()) { return known.match }
        if let known = cache.value(StoredMatch.self, forKey: key, maxAge: Self.artistMatchLifetime, now: clock()), known.match != nil {
            return known.match
        }
        var match: CatalogArtistMatch?
        if !track.title.isEmpty, let url = Self.searchURL(term: ITunesSearch.searchTerm(for: track), country: country, entities: [.song], limit: 15) {
            let raws = try Self.rawResults(try await fetch(url)).filter { $0.song != nil }
            if let raw = Self.bestMatch(for: track, in: raws), let artist = raw.artistOfTrack {
                match = CatalogArtistMatch(artist: artist, albumID: raw.albumOfTrack?.id, song: raw.song)
            }
        }
        if match == nil, let url = Self.searchURL(term: artistName, country: country, entities: [.musicArtist], limit: 8) {
            let wanted = TrackMatching.normalized(artistName)
            let artists = try Self.decode(try await fetch(url)).compactMap { item -> CatalogArtist? in
                if case .artist(let artist) = item { return artist }
                return nil
            }
            if let artist = artists.first(where: { TrackMatching.normalized($0.name) == wanted }) {
                match = CatalogArtistMatch(artist: artist)
            }
        }
        cache.store(StoredMatch(match: match), forKey: key, onDisk: true, now: clock())
        return match
    }

    public func albums(of artist: CatalogArtist) async throws -> [CatalogAlbum] {
        guard let number = Self.number(in: artist.id) else { return [] }
        let country = storefront()
        let key = "albums:v1:\(country.lowercased()):\(number)"
        if let cached = cache.value([CatalogAlbum].self, forKey: key, maxAge: Self.albumsLifetime, now: clock()) { return cached }
        guard let url = Self.lookupURL(id: number, entity: .album, country: country, limit: 200) else { return [] }
        let albums = Self.arrangeAlbums(try Self.rawResults(try await fetch(url)).compactMap(\.album))
        cache.store(albums, forKey: key, onDisk: true, now: clock())
        return albums
    }

    public func songs(of album: CatalogAlbum) async throws -> [CatalogSong] {
        guard let number = Self.number(in: album.id) else { return [] }
        let country = storefront()
        let key = "album-songs:v1:\(country.lowercased()):\(number)"
        if let cached = cache.value([CatalogSong].self, forKey: key, maxAge: Self.songsLifetime, now: clock()) { return cached }
        guard let url = Self.lookupURL(id: number, entity: .song, country: country, limit: 200) else { return [] }
        let songs = Self.albumOrder(try Self.rawResults(try await fetch(url)).compactMap(\.song)).map { song -> CatalogSong in
            var song = song
            if song.artwork == nil { song.artwork = album.artwork }
            return song
        }
        cache.store(songs, forKey: key, onDisk: true, now: clock())
        return songs
    }

    public func topSongs(of artist: CatalogArtist, limit: Int) async throws -> [CatalogSong] {
        guard let number = Self.number(in: artist.id) else { return [] }
        let country = storefront()
        let key = "top-songs:v1:\(country.lowercased()):\(number):\(limit)"
        if let cached = cache.value([CatalogSong].self, forKey: key, maxAge: Self.topSongsLifetime, now: clock()) { return cached }
        guard let url = Self.lookupURL(id: number, entity: .song, country: country, limit: limit) else { return [] }
        let songs = Array(try Self.rawResults(try await fetch(url)).compactMap(\.song).prefix(limit))
        cache.store(songs, forKey: key, onDisk: true, now: clock())
        return songs
    }

    private struct StoredMatch: Codable {
        var match: CatalogArtistMatch?
    }

    // MARK: Requests

    private func fetch(_ url: URL) async throws -> Data {
        let key = url.absoluteString
        let fetcher = self.fetcher
        let throttle = self.throttle
        let task = inFlight.withLock { tasks -> Task<Data, any Error> in
            if let running = tasks[key] { return running }
            let created = Task<Data, any Error> {
                try await throttle.acquire()
                let response: (data: Data, status: Int)
                do {
                    response = try await fetcher.get(url)
                } catch {
                    throw CatalogError.offline
                }
                switch response.status {
                case 200: return response.data
                case 403, 429:
                    await throttle.backOff(for: 60)
                    throw CatalogError.rateLimited
                default: throw CatalogError.badStatus(response.status)
                }
            }
            tasks[key] = created
            return created
        }
        defer { inFlight.withLock { tasks in if tasks[key] == task { tasks[key] = nil } } }
        do {
            return try await task.value
        } catch let error as CatalogError {
            if error != .offline { Self.log.notice("iTunes catalog: \(error) for \(url.path)") }
            throw error
        }
    }

    // MARK: URLs

    public static func searchURL(term: String, country: String, entities: [Entity], limit: Int) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entities.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(min(200, max(1, limit)))),
        ]
        return components?.url
    }

    public static func lookupURL(id: String, entity: Entity, country: String, limit: Int) -> URL? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "entity", value: entity.rawValue),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "limit", value: String(min(200, max(1, limit)))),
        ]
        return components?.url
    }

    /// The catalog number in "itunes:album:1234".
    public static func number(in id: String) -> String? {
        guard id.hasPrefix("itunes:"), let last = id.split(separator: ":").last, last.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }

    // MARK: Decoding

    /// Every result that reads as an artist, album or song, in order.
    /// Malformed results are skipped; a body that is not the API's JSON
    /// throws `CatalogError.unreadable`.
    public static func decode(_ data: Data) throws -> [Item] {
        try rawResults(data).compactMap { raw in
            if let artist = raw.artist { return .artist(artist) }
            if let album = raw.album { return .album(album) }
            if let song = raw.song { return .song(song) }
            return nil
        }
    }

    /// Search results: songs as found, artists the catalog named first and
    /// then the songs' artists, albums of the songs in order of appearance.
    static func searchResults(from raws: [RawResult], limit: Int) -> CatalogSearchResults {
        let songs = Array(raws.compactMap(\.song).prefix(limit))
        var artists: [CatalogArtist] = []
        for artist in raws.compactMap(\.artist) + raws.compactMap(\.artistOfTrack) where !artists.contains(where: { $0.id == artist.id }) {
            artists.append(artist)
        }
        var albums: [CatalogAlbum] = []
        for album in raws.compactMap(\.albumOfTrack) where !albums.contains(where: { $0.id == album.id }) {
            albums.append(album)
        }
        return CatalogSearchResults(songs: songs, albums: Array(albums.prefix(10)), artists: Array(artists.prefix(6)))
    }

    /// One edition per title and kind (explicit and longer editions win),
    /// oldest first; undated ones last.
    public static func arrangeAlbums(_ albums: [CatalogAlbum]) -> [CatalogAlbum] {
        var best: [String: CatalogAlbum] = [:]
        var order: [String] = []
        for album in albums {
            let key = "\(album.kind.rawValue)|\(TrackMatching.normalized(album.title))"
            if let current = best[key] {
                let better = (album.isExplicit && !current.isExplicit)
                    || (album.isExplicit == current.isExplicit && album.trackCount > current.trackCount)
                if better { best[key] = album }
            } else {
                best[key] = album
                order.append(key)
            }
        }
        let unique = order.compactMap { best[$0] }
        return unique.enumerated().sorted { a, b in
            switch (a.element.releaseDate, b.element.releaseDate) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Disc, then track number; unnumbered songs keep their order at the end.
    static func albumOrder(_ songs: [CatalogSong]) -> [CatalogSong] {
        songs.enumerated().sorted { a, b in
            let left = (a.element.discNumber ?? 1, a.element.trackNumber ?? Int.max, a.offset)
            let right = (b.element.discNumber ?? 1, b.element.trackNumber ?? Int.max, b.offset)
            return left < right
        }.map(\.element)
    }

    /// The song result that is clearly `track` (rules of `ITunesSearch.bestMatch`).
    static func bestMatch(for track: Track, in raws: [RawResult]) -> RawResult? {
        let candidates = raws.map { raw in
            ITunesSong(
                trackId: raw.trackId, trackName: raw.trackName ?? "", artistName: raw.artistName ?? "",
                collectionName: raw.collectionName, trackTimeMillis: raw.trackTimeMillis.map { Int($0) }
            )
        }
        guard let match = ITunesSearch.bestMatch(for: track, in: candidates),
              let index = candidates.firstIndex(of: match)
        else { return nil }
        return raws[index]
    }

    static func rawResults(_ data: Data) throws -> [RawResult] {
        struct Response: Decodable {
            var results: [Lenient]
        }
        struct Lenient: Decodable {
            var raw: RawResult?
            init(from decoder: Decoder) throws {
                raw = try? RawResult(from: decoder)
            }
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data).results.compactMap(\.raw)
        } catch {
            throw CatalogError.unreadable
        }
    }

    /// One result as the API spells it.
    struct RawResult: Decodable, Sendable {
        var wrapperType: String?
        var kind: String?
        var collectionType: String?
        var artistId: Int?
        var collectionId: Int?
        var trackId: Int?
        var artistName: String?
        var collectionArtistName: String?
        var collectionName: String?
        var trackName: String?
        var artistLinkUrl: String?
        var artistViewUrl: String?
        var collectionViewUrl: String?
        var trackViewUrl: String?
        var artworkUrl100: String?
        var releaseDate: String?
        var collectionExplicitness: String?
        var trackExplicitness: String?
        var trackCount: Int?
        var trackNumber: Int?
        var discNumber: Int?
        var trackTimeMillis: Double?
        var primaryGenreName: String?

        var artist: CatalogArtist? {
            guard wrapperType == "artist", let artistId, let name = artistName, !name.isEmpty else { return nil }
            return CatalogArtist(id: "itunes:artist:\(artistId)", name: name, genre: primaryGenreName, url: ITunesCatalog.cleanURL(artistLinkUrl ?? artistViewUrl))
        }

        var album: CatalogAlbum? {
            guard wrapperType == "collection", let collectionId, let name = collectionName, !name.isEmpty else { return nil }
            let (title, kind) = ITunesCatalog.albumTitle(name, collectionType: collectionType)
            return CatalogAlbum(
                id: "itunes:album:\(collectionId)", title: title, artistName: collectionArtistName ?? artistName ?? "",
                artistID: artistId.map { "itunes:artist:\($0)" }, releaseDate: CatalogDates.parse(releaseDate),
                trackCount: trackCount ?? 0, kind: kind, isExplicit: collectionExplicitness == "explicit",
                artwork: artworkUrl100.flatMap(URL.init(string:)).map { .remote($0) }, url: ITunesCatalog.cleanURL(collectionViewUrl)
            )
        }

        var song: CatalogSong? {
            guard wrapperType == "track", kind == nil || kind == "song", let trackId, let title = trackName, !title.isEmpty else { return nil }
            return CatalogSong(
                id: "itunes:song:\(trackId)", title: title, artistName: artistName ?? "", albumTitle: collectionName ?? "",
                albumID: collectionId.map { "itunes:album:\($0)" }, artistID: artistId.map { "itunes:artist:\($0)" },
                duration: (trackTimeMillis ?? 0) / 1000, trackNumber: trackNumber, discNumber: discNumber,
                isExplicit: trackExplicitness == "explicit",
                artwork: artworkUrl100.flatMap(URL.init(string:)).map { .remote($0) }, url: ITunesCatalog.cleanURL(trackViewUrl)
            )
        }

        /// The album a song result belongs to.
        var albumOfTrack: CatalogAlbum? {
            guard wrapperType == "track", let collectionId, let name = collectionName, !name.isEmpty else { return nil }
            let (title, kind) = ITunesCatalog.albumTitle(name, collectionType: nil)
            var url = ITunesCatalog.cleanURL(collectionViewUrl)
            if let current = url, var components = URLComponents(url: current, resolvingAgainstBaseURL: false) {
                components.queryItems = components.queryItems?.filter { $0.name != "i" }
                if components.queryItems?.isEmpty == true { components.queryItems = nil }
                url = components.url ?? current
            }
            return CatalogAlbum(
                id: "itunes:album:\(collectionId)", title: title, artistName: collectionArtistName ?? artistName ?? "",
                artistID: collectionArtistName == nil ? artistId.map { "itunes:artist:\($0)" } : nil,
                releaseDate: CatalogDates.parse(releaseDate), trackCount: trackCount ?? 0, kind: kind,
                isExplicit: collectionExplicitness == "explicit",
                artwork: artworkUrl100.flatMap(URL.init(string:)).map { .remote($0) }, url: url
            )
        }

        /// The artist of a song result.
        var artistOfTrack: CatalogArtist? {
            guard wrapperType == "track", let artistId, let name = artistName, !name.isEmpty else { return nil }
            return CatalogArtist(id: "itunes:artist:\(artistId)", name: name, genre: primaryGenreName, url: ITunesCatalog.cleanURL(artistViewUrl))
        }
    }

    /// "Name - Single" → ("Name", .single); compilations by their type.
    static func albumTitle(_ name: String, collectionType: String?) -> (String, AlbumKind) {
        for (suffix, kind) in [(" - Single", AlbumKind.single), (" - EP", .ep)] where name.hasSuffix(suffix) {
            return (String(name.dropLast(suffix.count)), kind)
        }
        return (name, collectionType == "Compilation" ? .compilation : .album)
    }

    /// The URL without Apple's `uo` tracking parameter.
    static func cleanURL(_ text: String?) -> URL? {
        guard let text, var components = URLComponents(string: text) else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name != "uo" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }
}
