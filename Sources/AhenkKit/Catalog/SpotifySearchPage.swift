import Foundation

/// One song in the results of Spotify's own search page.
public struct SpotifySearchRow: Equatable, Sendable {
    /// The base-62 track ID.
    public var id: String
    public var title: String
    /// Everyone the row names; empty when the page did not say.
    public var artists: [String]

    public init(id: String, title: String, artists: [String]) {
        self.id = id
        self.title = title
        self.artists = artists
    }
}

/// Spotify's public search page (open.spotify.com/search/…/tracks), as
/// anyone sees it without an account: where to find it, how to read its
/// rows and which row is the song that was asked for.
///
/// The mapping services know few new or local releases (see
/// ``ListenBrainzSpotifyFinder``); Spotify's own search knows every song it
/// has. Its Web API needs a key of a paying account, so the page is read
/// instead, in a web view the app keeps off screen
/// (``SpotifySearchPageReading``).
public enum SpotifySearchPage {
    /// The page that lists the songs for `query` ("artist title").
    public static func url(for query: SongQuery) -> URL? {
        let cleaned = query.cleaned
        let text = [cleaned.artist, cleaned.title].filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://open.spotify.com/search/\(encoded)/tracks")
    }

    /// Only this host is ever loaded in the reading web view.
    public static let host = "open.spotify.com"

    /// Run in the page: the first songs it lists, as JSON
    /// (`{"rows": [{"id", "title", "artists"}]}`). A song is a link to
    /// `/track/<id>`; its artists are the artist links of the same row.
    /// Nothing is clicked and nothing plays.
    public static let readScript = """
    (function () {
      var rows = [];
      var seen = {};
      var links = document.querySelectorAll('a[href*="/track/"]');
      for (var i = 0; i < links.length && rows.length < 12; i++) {
        var link = links[i];
        var match = /\\/track\\/([A-Za-z0-9]{22})/.exec(link.getAttribute('href') || '');
        var title = (link.textContent || '').trim();
        if (!match || !title || seen[match[1]]) continue;
        seen[match[1]] = true;
        var row = link.closest('[data-testid="tracklist-row"]') || link.closest('[role="row"]');
        var artists = [];
        if (row) {
          var names = row.querySelectorAll('a[href*="/artist/"]');
          for (var j = 0; j < names.length; j++) {
            var name = (names[j].textContent || '').trim();
            if (name) artists.push(name);
          }
        }
        rows.push({ id: match[1], title: title, artists: artists });
      }
      return JSON.stringify({ rows: rows });
    })()
    """

    /// The rows the script answered; `nil` when the answer cannot be read.
    /// Rows without a proper track ID or a title are dropped.
    public static func rows(fromJSON text: String) -> [SpotifySearchRow]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let items = object["rows"] as? [[String: Any]]
        else { return nil }
        return items.compactMap { item in
            guard let id = item["id"] as? String, SpotifyAppScripts.isBase62ID(id),
                  let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            let artists = (item["artists"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return SpotifySearchRow(id: id, title: title, artists: artists)
        }
    }

    /// The row that is the song asked for, in the page's own order: first
    /// one with the very title, then one with the plain title (asked with
    /// "(feat. …)", listed without), then one whose title differs only in
    /// its decorations ("- Live Version", "- Remastered"). The artist must
    /// be one of the row's (a row that names nobody is taken on its title:
    /// the search itself asked for the artist). `nil`: none of the rows is
    /// the song.
    public static func bestMatch(_ rows: [SpotifySearchRow], for query: SongQuery) -> String? {
        let title = TrackMatching.normalized(query.title)
        let core = TrackMatching.coreTitle(query.title)
        guard !core.isEmpty else { return nil }
        let candidates = rows.filter { performs($0, artist: query.artist) }
        if let exact = candidates.first(where: { TrackMatching.normalized($0.title) == title }) { return exact.id }
        if let plain = candidates.first(where: { TrackMatching.normalized($0.title) == core }) { return plain.id }
        return candidates.first { TrackMatching.coreTitle($0.title) == core }?.id
    }

    /// Whether one of the row's artists is named, in full, in the asked
    /// artist ("A", "A & B", "A feat. B").
    static func performs(_ row: SpotifySearchRow, artist: String) -> Bool {
        let wanted = TrackMatching.normalized(artist)
        guard !wanted.isEmpty, !row.artists.isEmpty else { return true }
        let padded = " \(wanted) "
        return row.artists.contains { name in
            let plain = TrackMatching.normalized(name)
            guard !plain.isEmpty else { return false }
            return padded.contains(" \(plain) ")
        }
    }
}

/// Opens Spotify's search page and reads its rows (the app does it in a
/// web view that is never shown; tests answer from a table).
public protocol SpotifySearchPageReading: Sendable {
    /// The songs the page lists; `nil` when it could not be read (offline,
    /// no rows in time, a page that changed).
    func rows(for url: URL) async -> [SpotifySearchRow]?
}

/// Songs' Spotify track IDs from Spotify's own search page. Answers are
/// kept a month; a song the page does not list is asked again after a day;
/// a page that could not be read is not remembered at all.
public final class SpotifyPageFinder: SpotifyTrackFinding {
    static let hitLifetime: TimeInterval = 30 * 86_400
    static let missLifetime: TimeInterval = 86_400

    private struct Stored: Codable {
        var id: String?
    }

    private let reader: any SpotifySearchPageReading
    private let cache: CatalogCache
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "catalog")

    public init(
        reader: any SpotifySearchPageReading,
        cache: CatalogCache = CatalogCache(directory: nil),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.cache = cache
        self.clock = clock
    }

    public func spotifyTrackIDs(for songs: [SongQuery]) async -> [SongQuery: String] {
        var found: [SongQuery: String] = [:]
        for song in songs where found[song] == nil {
            let query = song.cleaned
            let key = "spotify-page-id:v1:" + query.cacheKey
            let now = clock()
            if let known = cache.value(Stored.self, forKey: key, maxAge: Self.missLifetime, now: now) {
                if let id = known.id { found[song] = id }
                continue
            }
            if let known = cache.value(Stored.self, forKey: key, maxAge: Self.hitLifetime, now: now), let id = known.id {
                found[song] = id
                continue
            }
            guard let url = SpotifySearchPage.url(for: query), let rows = await reader.rows(for: url) else {
                Self.log.notice("Spotify's search page could not be read")
                continue
            }
            let id = SpotifySearchPage.bestMatch(rows, for: query)
            cache.store(Stored(id: id), forKey: key, onDisk: true, now: clock())
            if let id {
                found[song] = id
                Self.log.info("Spotify's search page lists the song (\(rows.count) rows read)")
            } else {
                Self.log.info("Spotify's search page does not list the song (\(rows.count) rows read)")
            }
        }
        return found
    }
}

/// Several finders, asked in order: a later one is asked only for the
/// songs the earlier ones did not find.
public struct SpotifyFinderChain: SpotifyTrackFinding {
    private let finders: [any SpotifyTrackFinding]

    public init(_ finders: [any SpotifyTrackFinding]) {
        self.finders = finders
    }

    public func spotifyTrackIDs(for songs: [SongQuery]) async -> [SongQuery: String] {
        var found: [SongQuery: String] = [:]
        for finder in finders {
            let missing = songs.filter { found[$0] == nil }
            guard !missing.isEmpty else { break }
            found.merge(await finder.spotifyTrackIDs(for: missing)) { first, _ in first }
        }
        return found
    }
}
