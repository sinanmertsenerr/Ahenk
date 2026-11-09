import Foundation

// What the desktop player browses: artists, albums and songs from a music
// catalog (Apple's public iTunes catalog, or the invented demo catalog),
// plus the playlists a source shares. Identifiers carry their catalog as a
// prefix ("itunes:…", "demo:…", "music:…"), so items from different
// catalogs never collide in caches, queues or lists.

/// Where a catalog item's cover comes from.
public enum CatalogArtwork: Hashable, Sendable, Codable {
    /// Apple's resizable cover (`…/100x100bb.jpg`): any size up to the
    /// original through the `NxNbb` path component.
    case remote(URL)
    /// Drawn by `DemoArtwork` (the demo catalog).
    case generated(seed: UInt64, colors: [SRGBColor])

    /// The cover at `pixelSize` per side; `nil` for generated covers.
    public func url(pixelSize: Int) -> URL? {
        guard case .remote(let url) = self else { return nil }
        let side = max(60, min(3000, pixelSize))
        let resized = url.absoluteString.replacingOccurrences(
            of: #"/\d+x\d+(bb|cc|sr)?\.(jpg|png|webp)$"#,
            with: "/\(side)x\(side)bb.jpg",
            options: .regularExpression
        )
        return URL(string: resized) ?? url
    }

    /// Identifies this cover at one size in image caches.
    public func cacheKey(pixelSize: Int) -> String {
        switch self {
        case .remote: "url:\(url(pixelSize: pixelSize)?.absoluteString ?? "")"
        case .generated(let seed, let colors): "gen:\(seed):\(colors.map(\.hex).joined()):\(pixelSize)"
        }
    }

    public var palette: Palette? {
        guard case .generated(_, let colors) = self else { return nil }
        return Palette(colors: colors)
    }
}

public struct CatalogArtist: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var genre: String?
    /// The artist's page (music.apple.com for the iTunes catalog).
    public var url: URL?

    public init(id: String, name: String, genre: String? = nil, url: URL? = nil) {
        self.id = id
        self.name = name
        self.genre = genre
        self.url = url
    }
}

public enum AlbumKind: String, Hashable, Sendable, Codable, CaseIterable {
    case album
    case ep
    case single
    case compilation
}

public struct CatalogAlbum: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    /// Without the catalog's " - Single" / " - EP" suffix (see `kind`).
    public var title: String
    public var artistName: String
    public var artistID: String?
    public var releaseDate: Date?
    public var trackCount: Int
    public var kind: AlbumKind
    public var isExplicit: Bool
    public var artwork: CatalogArtwork?
    public var url: URL?

    public init(
        id: String, title: String, artistName: String, artistID: String? = nil, releaseDate: Date? = nil,
        trackCount: Int = 0, kind: AlbumKind = .album, isExplicit: Bool = false, artwork: CatalogArtwork? = nil, url: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistID = artistID
        self.releaseDate = releaseDate
        self.trackCount = max(0, trackCount)
        self.kind = kind
        self.isExplicit = isExplicit
        self.artwork = artwork
        self.url = url
    }

    /// The release year in UTC (catalog dates are UTC midnights or noons).
    public var year: Int? {
        releaseDate.map { CatalogDates.utcCalendar.component(.year, from: $0) }
    }
}

public struct CatalogSong: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var albumID: String?
    public var artistID: String?
    /// Seconds; 0 when unknown.
    public var duration: TimeInterval
    public var trackNumber: Int?
    public var discNumber: Int?
    public var isExplicit: Bool
    public var artwork: CatalogArtwork?
    /// The song's page (music.apple.com, with the album and `?i=` track).
    public var url: URL?
    /// The song as a player names it, when it came from one (Continue
    /// Playing, a source's playlist): its source and that source's own ID
    /// (`spotify:track:…`, `music:<persistent ID>`, `demo:…`). Playing it
    /// again in the same source can then use that ID directly.
    public var origin: Track?

    public init(
        id: String, title: String, artistName: String, albumTitle: String = "", albumID: String? = nil,
        artistID: String? = nil, duration: TimeInterval = 0, trackNumber: Int? = nil, discNumber: Int? = nil,
        isExplicit: Bool = false, artwork: CatalogArtwork? = nil, url: URL? = nil, origin: Track? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.artistID = artistID
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.isExplicit = isExplicit
        self.artwork = artwork
        self.url = url
        self.origin = origin
    }

    /// A song that played in a source (Continue Playing).
    public init(playing track: Track, artwork: CatalogArtwork? = nil) {
        self.init(
            id: "\(track.source.rawValue):\(track.id)", title: track.title, artistName: track.artist,
            albumTitle: track.album, duration: track.duration,
            artwork: artwork ?? track.artworkURL.map { .remote($0) }, origin: track
        )
    }

    /// The source's own ID when the song came from `source`.
    public func originID(in source: MusicSource) -> String? {
        guard let origin, origin.source == source else { return nil }
        return origin.id
    }
}

/// What a search found, in the catalog's order of relevance.
public struct CatalogSearchResults: Hashable, Sendable, Codable {
    public var songs: [CatalogSong]
    public var albums: [CatalogAlbum]
    public var artists: [CatalogArtist]

    public init(songs: [CatalogSong] = [], albums: [CatalogAlbum] = [], artists: [CatalogArtist] = []) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
    }

    public var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }
}

/// A playlist a source shares (Apple Music's library playlists, the demo's
/// invented ones; browser sites through Step 7's extension).
public struct CatalogPlaylist: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var songCount: Int?
    public var artwork: CatalogArtwork?

    public init(id: String, name: String, songCount: Int? = nil, artwork: CatalogArtwork? = nil) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.artwork = artwork
    }
}

/// The catalog's artist for a song that plays, and that song's album when
/// the catalog has it.
public struct CatalogArtistMatch: Hashable, Sendable, Codable {
    public var artist: CatalogArtist
    public var albumID: String?
    public var song: CatalogSong?

    public init(artist: CatalogArtist, albumID: String? = nil, song: CatalogSong? = nil) {
        self.artist = artist
        self.albumID = albumID
        self.song = song
    }
}

public enum CatalogError: Error, Equatable, Sendable {
    /// No connection, or the request timed out.
    case offline
    /// Too many requests; try again later.
    case rateLimited
    /// The service answered with an unexpected status.
    case badStatus(Int)
    /// The answer could not be read.
    case unreadable
}

/// A searchable music catalog with albums by artist (Step 5's desktop
/// player: cover flow, search, album and artist pages).
public protocol MusicCatalog: Sendable {
    func search(_ term: String, limit: Int) async throws -> CatalogSearchResults
    /// The catalog's artist of a song that plays (`nil`: not in the catalog).
    func artist(for track: Track) async throws -> CatalogArtistMatch?
    /// The artist's albums, EPs and singles, oldest first.
    func albums(of artist: CatalogArtist) async throws -> [CatalogAlbum]
    /// The album's songs in disc and track order.
    func songs(of album: CatalogAlbum) async throws -> [CatalogSong]
    func topSongs(of artist: CatalogArtist, limit: Int) async throws -> [CatalogSong]
}

enum CatalogDates {
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// ISO 8601 with or without fractional seconds ("2024-03-01T08:00:00Z").
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
