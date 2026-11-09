import Foundation
import os
import Testing
@testable import AhenkKit

/// iTunes Search/Lookup answers in the API's shape, with invented artists,
/// albums and songs.
enum CatalogFixtures {
    static let artistLookup = #"""
    {"resultCount": 4, "results": [
     {"wrapperType":"artist","artistType":"Artist","artistName":"Juniper Coast","artistLinkUrl":"https://music.apple.com/us/artist/juniper-coast/5550001?uo=4","artistId":5550001,"primaryGenreName":"Indie Pop","primaryGenreId":14},
     {"wrapperType":"collection","collectionType":"Album","artistId":5550001,"collectionId":7770003,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","collectionViewUrl":"https://music.apple.com/us/album/paper-lighthouse/7770003?uo=4","artworkUrl60":"https://is1-ssl.mzstatic.com/image/thumb/Music1/v4/aa/bb/cc/fixture.jpg/60x60bb.jpg","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music1/v4/aa/bb/cc/fixture.jpg/100x100bb.jpg","collectionExplicitness":"notExplicit","trackCount":11,"releaseDate":"2021-05-14T07:00:00Z","primaryGenreName":"Indie Pop"},
     {"wrapperType":"collection","collectionType":"Album","artistId":5550001,"collectionId":7770001,"artistName":"Juniper Coast","collectionName":"Saltwater Letters - EP","collectionViewUrl":"https://music.apple.com/us/album/saltwater-letters-ep/7770001?uo=4","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music1/v4/dd/ee/ff/fixture.jpg/100x100bb.jpg","collectionExplicitness":"notExplicit","trackCount":5,"releaseDate":"2018-02-02T08:00:00Z"},
     {"wrapperType":"collection","collectionType":"Album","artistId":5550001,"collectionId":7770002,"artistName":"Juniper Coast","collectionName":"Northern Porch - Single","collectionViewUrl":"https://music.apple.com/us/album/northern-porch-single/7770002?uo=4","collectionExplicitness":"explicit","trackCount":1,"releaseDate":"2019-09-20T07:00:00Z"}
    ]}
    """#

    static let albumLookup = #"""
    {"resultCount": 4, "results": [
     {"wrapperType":"collection","collectionType":"Album","artistId":5550001,"collectionId":7770003,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","trackCount":3,"releaseDate":"2021-05-14T07:00:00Z"},
     {"wrapperType":"track","kind":"song","artistId":5550001,"collectionId":7770003,"trackId":9990003,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","trackName":"Third Window","trackViewUrl":"https://music.apple.com/us/album/third-window/7770003?i=9990003&uo=4","discNumber":1,"trackNumber":3,"trackTimeMillis":201500,"trackExplicitness":"notExplicit"},
     {"wrapperType":"track","kind":"song","artistId":5550001,"collectionId":7770003,"trackId":9990001,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","trackName":"Harbor Bells (feat. Mira Sol)","trackViewUrl":"https://music.apple.com/us/album/harbor-bells/7770003?i=9990001&uo=4","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music1/v4/aa/bb/cc/fixture.jpg/100x100bb.jpg","discNumber":1,"trackNumber":1,"trackTimeMillis":187000,"trackExplicitness":"explicit"},
     {"wrapperType":"track","kind":"song","artistId":5550001,"collectionId":7770003,"trackId":9990002,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","trackName":"Lighthouse Static","discNumber":1,"trackNumber":2,"trackTimeMillis":222000},
     {"wrapperType":"track","kind":"music-video","trackId":9990009,"artistName":"Juniper Coast","trackName":"Harbor Bells (Video)"}
    ]}
    """#

    static let search = #"""
    {"resultCount": 5, "results": [
     {"wrapperType":"artist","artistType":"Artist","artistName":"Juniper Coast","artistLinkUrl":"https://music.apple.com/us/artist/juniper-coast/5550001?uo=4","artistId":5550001,"primaryGenreName":"Indie Pop"},
     {"wrapperType":"track","kind":"song","artistId":5550001,"collectionId":7770003,"trackId":9990001,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","trackName":"Harbor Bells (feat. Mira Sol)","collectionViewUrl":"https://music.apple.com/us/album/harbor-bells/7770003?i=9990001&uo=4","trackViewUrl":"https://music.apple.com/us/album/harbor-bells/7770003?i=9990001&uo=4","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music1/v4/aa/bb/cc/fixture.jpg/100x100bb.jpg","releaseDate":"2021-05-14T12:00:00Z","trackCount":11,"trackTimeMillis":187000,"primaryGenreName":"Indie Pop"},
     {"wrapperType":"track","kind":"song","artistId":5550002,"collectionId":7770010,"trackId":9990010,"artistName":"Mira Sol","collectionName":"Harbor Bells - Single","trackName":"Harbor Bells","releaseDate":"2022-01-07T12:00:00Z","trackCount":1,"trackTimeMillis":190000},
     {"wrapperType":"track","kind":"song","artistId":5550001,"collectionId":7770003,"trackId":9990002,"artistName":"Juniper Coast","collectionName":"Paper Lighthouse","trackName":"Lighthouse Static","trackTimeMillis":222000},
     {"wrapperType":"track","kind":"song","trackName":"Broken entry without an ID"}
    ]}
    """#
}

/// Answers GET requests from a table and counts them.
final class TableFetcher: HTTPFetching, Sendable {
    private let state: OSAllocatedUnfairLock<(table: [String: (Data, Int)], requests: [String], posts: [Data])>

    init(_ table: [String: (String, Int)] = [:]) {
        state = OSAllocatedUnfairLock(initialState: (table.mapValues { (Data($0.0.utf8), $0.1) }, [], []))
    }

    func set(_ fragment: String, _ body: String, status: Int = 200) {
        state.withLock { $0.table[fragment] = (Data(body.utf8), status) }
    }

    var requests: [String] { state.withLock { $0.requests } }
    var posts: [Data] { state.withLock { $0.posts } }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let text = url.absoluteString
        let answer = state.withLock { state -> (Data, Int)? in
            state.requests.append(text)
            return state.table.first { text.contains($0.key) }?.value
        }
        guard let answer else { throw URLError(.notConnectedToInternet) }
        return (answer.0, answer.1)
    }

    func post(_ url: URL, json body: Data) async throws -> (data: Data, status: Int) {
        let text = url.absoluteString
        let answer = state.withLock { state -> (Data, Int)? in
            state.requests.append(text)
            state.posts.append(body)
            return state.table.first { text.contains($0.key) }?.value
        }
        guard let answer else { throw URLError(.notConnectedToInternet) }
        return (answer.0, answer.1)
    }
}

@Suite("iTunes catalog")
struct ITunesCatalogTests {
    @Test("An artist lookup reads the artist and its albums, EPs and singles")
    func decodesLookup() throws {
        let items = try ITunesCatalog.decode(Data(CatalogFixtures.artistLookup.utf8))
        #expect(items.count == 4)
        guard case .artist(let artist) = items[0] else {
            Issue.record("first item is not the artist")
            return
        }
        #expect(artist.id == "itunes:artist:5550001")
        #expect(artist.name == "Juniper Coast")
        #expect(artist.genre == "Indie Pop")
        #expect(artist.url?.absoluteString == "https://music.apple.com/us/artist/juniper-coast/5550001", "the uo tracking parameter is dropped")
        let albums = items.compactMap { item -> CatalogAlbum? in
            if case .album(let album) = item { return album }
            return nil
        }
        #expect(albums.map(\.title) == ["Paper Lighthouse", "Saltwater Letters", "Northern Porch"])
        #expect(albums.map(\.kind) == [.album, .ep, .single])
        #expect(albums.map(\.year) == [2021, 2018, 2019])
        #expect(albums[0].trackCount == 11)
        #expect(albums[2].isExplicit && !albums[0].isExplicit)
        #expect(albums[0].artistID == "itunes:artist:5550001")
        #expect(albums[1].artwork?.url(pixelSize: 600)?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Music1/v4/dd/ee/ff/fixture.jpg/600x600bb.jpg")
        #expect(albums[2].artwork == nil)
    }

    @Test("An album lookup reads its songs; other kinds and broken entries are skipped")
    func decodesSongs() throws {
        let songs = try ITunesCatalog.decode(Data(CatalogFixtures.albumLookup.utf8)).compactMap { item -> CatalogSong? in
            if case .song(let song) = item { return song }
            return nil
        }
        #expect(songs.count == 3, "the music video is not a song")
        let ordered = ITunesCatalog.albumOrder(songs)
        #expect(ordered.map(\.trackNumber) == [1, 2, 3])
        let first = ordered[0]
        #expect(first.id == "itunes:song:9990001")
        #expect(first.title == "Harbor Bells (feat. Mira Sol)")
        #expect(first.albumID == "itunes:album:7770003")
        #expect(first.duration == 187)
        #expect(first.isExplicit)
        #expect(first.url?.absoluteString == "https://music.apple.com/us/album/harbor-bells/7770003?i=9990001")
    }

    @Test("A body that is not the API's answer is unreadable")
    func unreadable() throws {
        #expect(throws: CatalogError.unreadable) { try ITunesCatalog.decode(Data("<html>".utf8)) }
        #expect(try ITunesCatalog.decode(Data(#"{"resultCount":0,"results":[]}"#.utf8)).isEmpty)
    }

    @Test("Search results: songs, their albums and artists")
    func searchResults() throws {
        let raws = try ITunesCatalog.rawResults(Data(CatalogFixtures.search.utf8))
        let results = ITunesCatalog.searchResults(from: raws, limit: 10)
        #expect(results.songs.map(\.title) == ["Harbor Bells (feat. Mira Sol)", "Harbor Bells", "Lighthouse Static"])
        #expect(results.artists.map(\.name) == ["Juniper Coast", "Mira Sol"])
        #expect(results.albums.map(\.title) == ["Paper Lighthouse", "Harbor Bells"])
        #expect(results.albums.map(\.kind) == [.album, .single])
        #expect(results.albums[0].url?.absoluteString == "https://music.apple.com/us/album/harbor-bells/7770003", "the album link has no song")
        #expect(ITunesCatalog.searchResults(from: raws, limit: 1).songs.count == 1)
    }

    @Test("Albums: one edition per title, explicit and longer first, oldest first")
    func arrangesAlbums() {
        func album(_ id: String, _ title: String, _ year: Int?, explicit: Bool = false, tracks: Int = 10, kind: AlbumKind = .album) -> CatalogAlbum {
            CatalogAlbum(
                id: id, title: title, artistName: "Juniper Coast",
                releaseDate: year.flatMap { CatalogDates.utcCalendar.date(from: DateComponents(year: $0, month: 3, day: 1)) },
                trackCount: tracks, kind: kind, isExplicit: explicit
            )
        }
        let arranged = ITunesCatalog.arrangeAlbums([
            album("a", "Paper Lighthouse", 2021),
            album("b", "Paper Lighthouse", 2021, explicit: true),
            album("c", "Saltwater Letters", 2018, tracks: 5, kind: .ep),
            album("d", "Undated Sketches", nil),
            album("e", "Northern Porch", 2019, tracks: 1, kind: .single),
            album("f", "Northern Porch", 2019, tracks: 3),
        ])
        #expect(arranged.map(\.id) == ["c", "e", "f", "b", "d"])
    }

    @Test("Search and lookup URLs")
    func urls() throws {
        let search = try #require(ITunesCatalog.searchURL(term: "juniper coast", country: "TR", entities: [.musicArtist, .song], limit: 25))
        let query = try #require(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "country", value: "tr")))
        #expect(query.contains(URLQueryItem(name: "entity", value: "musicArtist,song")))
        #expect(query.contains(URLQueryItem(name: "term", value: "juniper coast")))
        #expect(ITunesCatalog.lookupURL(id: "7770003", entity: .song, country: "us", limit: 500)?.absoluteString
            == "https://itunes.apple.com/lookup?id=7770003&entity=song&country=us&limit=200")
        #expect(ITunesCatalog.lookupURL(id: "12a", entity: .song, country: "us", limit: 5) == nil)
        #expect(ITunesCatalog.number(in: "itunes:album:7770003") == "7770003")
        #expect(ITunesCatalog.number(in: "demo:album:x") == nil)
    }

    @Test("Answers are cached and identical requests share one fetch")
    func caches() async throws {
        let fetcher = TableFetcher(["lookup?id=5550001": (CatalogFixtures.artistLookup, 200)])
        let catalog = ITunesCatalog(fetcher: fetcher, storefront: { "US" })
        let artist = CatalogArtist(id: "itunes:artist:5550001", name: "Juniper Coast")
        async let first = catalog.albums(of: artist)
        async let second = catalog.albums(of: artist)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(a.map(\.title) == ["Saltwater Letters", "Northern Porch", "Paper Lighthouse"])
        _ = try await catalog.albums(of: artist)
        #expect(fetcher.requests.count == 1)
    }

    @Test("Errors: offline, rate limited and an unexpected status")
    func errors() async {
        let fetcher = TableFetcher(["lookup?id=1": ("{}", 429), "lookup?id=2": ("{}", 500)])
        let catalog = ITunesCatalog(fetcher: fetcher, storefront: { "US" })
        await #expect(throws: CatalogError.rateLimited) {
            try await catalog.albums(of: CatalogArtist(id: "itunes:artist:1", name: "x"))
        }
        await #expect(throws: CatalogError.rateLimited, "the back-off holds every request") {
            try await catalog.albums(of: CatalogArtist(id: "itunes:artist:2", name: "y"))
        }
        let other = ITunesCatalog(fetcher: fetcher, storefront: { "US" })
        await #expect(throws: CatalogError.badStatus(500)) {
            try await other.albums(of: CatalogArtist(id: "itunes:artist:2", name: "y"))
        }
        await #expect(throws: CatalogError.offline) {
            try await other.albums(of: CatalogArtist(id: "itunes:artist:3", name: "z"))
        }
    }

    @Test("The artist of a song: from the matching song, else by name; misses are remembered")
    func artistOfTrack() async throws {
        let fetcher = TableFetcher([
            "entity=song": (CatalogFixtures.search, 200),
            "entity=musicArtist": (CatalogFixtures.artistLookup, 200),
        ])
        let catalog = ITunesCatalog(fetcher: fetcher, storefront: { "US" })
        let track = Track(id: "x", source: .spotify, title: "Harbor Bells", artist: "Juniper Coast", album: "Paper Lighthouse", duration: 188)
        let match = try #require(try await catalog.artist(for: track))
        #expect(match.artist.id == "itunes:artist:5550001")
        #expect(match.albumID == "itunes:album:7770003")
        #expect(match.song?.id == "itunes:song:9990001")

        let byName = Track(id: "y", source: .spotify, title: "Unknown Tune", artist: "juniper coast")
        let found = try #require(try await catalog.artist(for: byName))
        #expect(found.artist.name == "Juniper Coast")
        #expect(found.albumID == nil)

        let nobody = Track(id: "z", source: .spotify, title: "Nothing", artist: "Nobody Invented")
        #expect(try await catalog.artist(for: nobody) == nil)
        let before = fetcher.requests.count
        #expect(try await catalog.artist(for: nobody) == nil)
        #expect(fetcher.requests.count == before, "a miss is remembered")
    }
}

@Suite("Request throttle")
struct RequestThrottleTests {
    @Test("Requests over the limit wait for a slot or fail")
    func limits() async throws {
        let clock = ManualClock()
        let slept = Recorder<TimeInterval>()
        let throttle = RequestThrottle(limit: 2, per: 10, maximumWait: 4, clock: clock.function) { seconds in
            slept.append(seconds)
            clock.advance(seconds)
        }
        try await throttle.acquire()
        clock.advance(7)
        try await throttle.acquire()
        // The third must wait until the first leaves the window (3 s).
        try await throttle.acquire()
        #expect(slept.values.count == 1 && abs(slept.values[0] - 3) < 1e-9)
        // The fourth would wait 7 s: more than the 4 s allowed.
        await #expect(throws: CatalogError.rateLimited) { try await throttle.acquire() }
        clock.advance(7)
        #expect(await throttle.delay() == 0)
    }

    @Test("A back-off holds every request until it ends")
    func backOff() async throws {
        let clock = ManualClock()
        let throttle = RequestThrottle(limit: 5, per: 1, clock: clock.function) { _ in }
        await throttle.backOff(for: 30)
        await #expect(throws: CatalogError.rateLimited) { try await throttle.acquire() }
        #expect(await throttle.delay() == nil)
        clock.advance(31)
        try await throttle.acquire()
    }
}

@Suite("Spotify track IDs")
struct SpotifyTrackFinderTests {
    static let answer = #"""
    [{"recording_mbid": null, "artist_name": "Juniper Coast", "release_name": "Paper Lighthouse", "track_name": "Harbor Bells", "spotify_track_ids": ["0AbCdEfGhIjKlMnOpQrStU", "1AbCdEfGhIjKlMnOpQrStU"]},
     {"recording_mbid": null, "artist_name": "Juniper Coast", "release_name": "Paper Lighthouse", "track_name": "Lighthouse Static", "spotify_track_ids": []},
     {"recording_mbid": null, "artist_name": "Mira Sol", "release_name": "Harbor Bells", "track_name": "Harbor Bells", "spotify_track_ids": ["not-an-id", "2AbCdEfGhIjKlMnOpQrStU"]}]
    """#

    @Test("Queries drop decorations; the request lists each song")
    func request() throws {
        let query = SongQuery(title: "Harbor Bells (feat. Mira Sol)", artist: "Juniper Coast ", album: "Paper Lighthouse (Deluxe Edition)").cleaned
        #expect(query == SongQuery(title: "Harbor Bells", artist: "Juniper Coast", album: "Paper Lighthouse"))
        #expect(SongQuery(title: "(Interlude)", artist: "A", album: "Northern Porch - Single").cleaned
            == SongQuery(title: "(Interlude)", artist: "A", album: "Northern Porch"))
        let body = try ListenBrainzSpotifyFinder.requestBody([query])
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [[String: String]])
        #expect(decoded == [["artist_name": "Juniper Coast", "release_name": "Paper Lighthouse", "track_name": "Harbor Bells"]])
    }

    @Test("Answers decode; malformed IDs are dropped")
    func decodes() throws {
        let matches = try ListenBrainzSpotifyFinder.decode(Data(Self.answer.utf8))
        #expect(matches.count == 3)
        #expect(matches[0].spotifyTrackIDs.first == "0AbCdEfGhIjKlMnOpQrStU")
        #expect(matches[1].spotifyTrackIDs.isEmpty)
        #expect(matches[2].spotifyTrackIDs == ["2AbCdEfGhIjKlMnOpQrStU"])
        #expect(throws: CatalogError.unreadable) { try ListenBrainzSpotifyFinder.decode(Data(#"{"code":401}"#.utf8)) }
    }

    @Test("Songs are looked up in one batch and remembered, misses too")
    func batches() async throws {
        let fetcher = TableFetcher(["spotify-id-from-metadata": (Self.answer, 200)])
        let finder = ListenBrainzSpotifyFinder(fetcher: fetcher, throttle: RequestThrottle(limit: 10, per: 1))
        let songs = [
            SongQuery(title: "Harbor Bells (feat. Mira Sol)", artist: "Juniper Coast", album: "Paper Lighthouse"),
            SongQuery(title: "Lighthouse Static", artist: "Juniper Coast", album: "Paper Lighthouse"),
            SongQuery(title: "Harbor Bells", artist: "Mira Sol", album: "Harbor Bells - Single"),
        ]
        let found = await finder.spotifyTrackIDs(for: songs)
        #expect(found[songs[0]] == "0AbCdEfGhIjKlMnOpQrStU")
        #expect(found[songs[1]] == nil)
        #expect(found[songs[2]] == "2AbCdEfGhIjKlMnOpQrStU")
        #expect(fetcher.posts.count == 1)
        let again = await finder.spotifyTrackIDs(for: songs)
        #expect(again == found)
        #expect(fetcher.posts.count == 1, "hits and misses come from the cache")
    }

    @Test("An answer of the wrong length is not trusted")
    func wrongLength() async {
        let fetcher = TableFetcher(["spotify-id-from-metadata": (Self.answer, 200)])
        let finder = ListenBrainzSpotifyFinder(fetcher: fetcher, throttle: RequestThrottle(limit: 10, per: 1))
        let found = await finder.spotifyTrackIDs(for: [SongQuery(title: "One", artist: "A", album: "B")])
        #expect(found.isEmpty)
    }
}

@Suite("Catalog artwork")
struct CatalogArtworkTests {
    @Test("Remote covers resize through the URL; generated ones carry a palette")
    func artwork() throws {
        let remote = CatalogArtwork.remote(try #require(URL(string: "https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/100x100bb.jpg")))
        #expect(remote.url(pixelSize: 300)?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/300x300bb.jpg")
        #expect(remote.url(pixelSize: 9_000)?.absoluteString.hasSuffix("/3000x3000bb.jpg") == true)
        #expect(remote.cacheKey(pixelSize: 300) != remote.cacheKey(pixelSize: 600))
        let generated = CatalogArtwork.generated(seed: 7, colors: [SRGBColor("#112233")])
        #expect(generated.url(pixelSize: 100) == nil)
        #expect(generated.palette?.primary == SRGBColor("#112233"))
    }

    @Test("Catalog answers survive the cache for their lifetime only")
    func cacheLifetime() {
        let cache = CatalogCache(directory: nil)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        cache.store(["a", "b"], forKey: "k", onDisk: false, now: start)
        #expect(cache.value([String].self, forKey: "k", maxAge: 60, now: start.addingTimeInterval(30)) == ["a", "b"])
        #expect(cache.value([String].self, forKey: "k", maxAge: 60, now: start.addingTimeInterval(90)) == nil)
        #expect(cache.value([Int].self, forKey: "k", maxAge: 60, now: start) == nil, "another type does not decode")
    }

    @Test("The disk cache keeps answers across instances")
    func diskCache() {
        let directory = ScratchDirectory()
        let first = CatalogCache(directory: directory.url)
        first.store(CatalogArtist(id: "itunes:artist:1", name: "Juniper Coast"), forKey: "artist", onDisk: true)
        first.flush()
        let second = CatalogCache(directory: directory.url)
        #expect(second.value(CatalogArtist.self, forKey: "artist", maxAge: 60)?.name == "Juniper Coast")
    }
}
