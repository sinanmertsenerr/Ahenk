import Foundation

/// A music source's own search: the songs it has for a typed term, each
/// with the source's own ID, so a pick plays that very song there instead
/// of the source's best guess for a title from another catalog.
public protocol SourceSongSearching: Sendable {
    /// Songs for `term`, in the source's order; empty when it knows none.
    func songs(_ term: String, limit: Int) async throws -> [CatalogSong]
}

/// What the desktop player's search lists for the source picks play in:
/// that source's own songs, with the catalog's artists and albums beside
/// them for browsing.
public enum SourceSearch {
    /// The source's songs as the songs, the catalog's artists and albums as
    /// they are. On top: the catalog's artist when it names one (the search
    /// was for a person), else the first song.
    public static func results(songs: [CatalogSong], catalog: CatalogSearchResults?, limit: Int = 50) -> CatalogSearchResults {
        let listed = Array(songs.prefix(max(0, limit)))
        var top: CatalogTopResult?
        if case .artist(let artist)? = catalog?.top {
            top = .artist(artist)
        } else if let first = listed.first {
            top = .song(first)
        }
        return CatalogSearchResults(songs: listed, albums: catalog?.albums ?? [], artists: catalog?.artists ?? [], top: top)
    }

    /// Asks the source and the catalog at once. Without songs from the
    /// source (it did not answer, or knows none) the catalog's own results
    /// stand; an error only when neither answered.
    public static func search(
        _ term: String, in source: any SourceSongSearching, catalog: any MusicCatalog, limit: Int
    ) async throws -> CatalogSearchResults {
        async let listed: Result<CatalogSearchResults, Error> = {
            do { return .success(try await catalog.search(term, limit: limit)) } catch { return .failure(error) }
        }()
        let found = (try? await source.songs(term, limit: limit)) ?? []
        let fromCatalog = await listed
        let merged = results(songs: found, catalog: try? fromCatalog.get(), limit: limit)
        if !merged.songs.isEmpty { return merged }
        return try fromCatalog.get()
    }
}

// MARK: YouTube

/// YouTube's videos as songs (`YouTubeSongs`).
public struct YouTubeSongSearch: SourceSongSearching {
    private let videos: any YouTubeVideoSearching

    public init(videos: any YouTubeVideoSearching) {
        self.videos = videos
    }

    public func songs(_ term: String, limit: Int) async throws -> [CatalogSong] {
        try await videos.search(term).compactMap(YouTubeSongs.song(from:))
    }
}

// MARK: YouTube Music

/// YouTube Music's own songs for a term (its "Songs" results).
public struct YouTubeMusicSongSearch: SourceSongSearching {
    public static let idPrefix = "youtubeMusic:"
    private let matcher: YouTubeMusicMatcher

    public init(matcher: YouTubeMusicMatcher) {
        self.matcher = matcher
    }

    public func songs(_ term: String, limit: Int) async throws -> [CatalogSong] {
        guard let entries = await matcher.songs(matching: term) else { throw CatalogError.offline }
        return entries.compactMap(Self.song(from:))
    }

    /// The entry as a song opened by its own address on YouTube Music. Its
    /// picture is the album's cover in the middle of the video's frame.
    public static func song(from entry: YouTubeMusicEntry) -> CatalogSong? {
        guard BrowserSite.youtubeVideoID(entry.id) == entry.id, let watch = BrowserSite.youtubeMusic.watchURL(videoID: entry.id) else { return nil }
        let artist = entry.artists.joined(separator: ", ")
        let picture = YouTubeSongs.thumbnailURL(videoID: entry.id)
        let duration = entry.duration ?? 0
        let track = Track(id: watch.absoluteString, source: .youtubeMusic, title: entry.title, artist: artist, duration: duration, artworkURL: picture)
        return CatalogSong(
            id: idPrefix + entry.id, title: entry.title, artistName: artist, duration: duration,
            artwork: picture.map { .remote($0) }, url: watch, origin: track
        )
    }
}

// MARK: Spotify

/// Spotify's own search page as songs, for the Spotify app or its web
/// player (`source`): each with its track ID, so the pick is that track.
public struct SpotifySongSearch: SourceSongSearching {
    private let reader: any SpotifySearchPageReading
    private let source: MusicSource

    public init(reader: any SpotifySearchPageReading, source: MusicSource) {
        self.reader = reader
        self.source = source
    }

    public func songs(_ term: String, limit: Int) async throws -> [CatalogSong] {
        guard let url = SpotifySearchPage.url(forTerm: term) else { return [] }
        guard let rows = await reader.rows(for: url) else { throw CatalogError.offline }
        return rows.map { Self.song(from: $0, source: source) }
    }

    public static func song(from row: SpotifySearchRow, source: MusicSource) -> CatalogSong {
        let uri = "spotify:track:\(row.id)"
        let artist = row.artists.joined(separator: ", ")
        let cover = row.artworkURL.flatMap(URL.init(string:)).map(SpotifySearchPage.largeCover(of:))
        let duration = row.duration ?? 0
        let track = Track(id: uri, source: source, title: row.title, artist: artist, album: row.album ?? "", duration: duration, artworkURL: cover)
        return CatalogSong(
            id: uri, title: row.title, artistName: artist, albumTitle: row.album ?? "", duration: duration,
            artwork: cover.map { .remote($0) }, url: URL(string: "https://open.spotify.com/track/\(row.id)"), origin: track
        )
    }
}

// MARK: Deezer

/// Deezer's public search (`api.deezer.com/search`, no account or key).
public struct DeezerSongSearch: SourceSongSearching {
    private let fetcher: any HTTPFetching

    public init(fetcher: any HTTPFetching) {
        self.fetcher = fetcher
    }

    public static func url(forTerm term: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: String(max(1, min(50, limit))))]
        return components?.url
    }

    public func songs(_ term: String, limit: Int) async throws -> [CatalogSong] {
        guard let url = Self.url(forTerm: term, limit: limit) else { return [] }
        guard let (data, status) = try? await fetcher.get(url) else { throw CatalogError.offline }
        guard status == 200 else { throw status == 429 ? CatalogError.rateLimited : CatalogError.badStatus(status) }
        guard let songs = Self.songs(from: data) else { throw CatalogError.unreadable }
        return songs
    }

    /// The songs in an answer; `nil` when it is not one (Deezer answers
    /// its errors with status 200 and an `error` object).
    public static func songs(from data: Data) -> [CatalogSong]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object["data"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let number = item["id"] as? NSNumber, let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let page = URL(string: "https://www.deezer.com/track/\(number.int64Value)")
            else { return nil }
            let artist = (item["artist"] as? [String: Any])?["name"] as? String ?? ""
            let album = item["album"] as? [String: Any]
            let cover = ((album?["cover_big"] ?? album?["cover_medium"]) as? String).flatMap(URL.init(string:))
            let duration = (item["duration"] as? NSNumber)?.doubleValue ?? 0
            let albumTitle = album?["title"] as? String ?? ""
            let track = Track(id: page.absoluteString, source: .deezer, title: title, artist: artist, album: albumTitle, duration: duration, artworkURL: cover)
            return CatalogSong(
                id: "deezer:\(number.int64Value)", title: title, artistName: artist, albumTitle: albumTitle, duration: duration,
                isExplicit: (item["explicit_lyrics"] as? Bool) ?? false, artwork: cover.map { .remote($0) }, url: page, origin: track
            )
        }
    }
}
