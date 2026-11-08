import CoreGraphics
import Foundation
import os
import Testing
@testable import AhenkKit

/// Serves canned responses by URL and counts requests. No network.
final class FakeFetcher: HTTPFetching, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (routes: [String: (Data, Int)](), requests: [String]()))

    func serve(_ url: String, _ data: Data, status: Int = 200) {
        state.withLock { $0.routes[url] = (data, status) }
    }

    /// Serves every URL that starts with `prefix`.
    func serve(prefix: String, _ data: Data, status: Int = 200) {
        state.withLock { $0.routes["prefix:" + prefix] = (data, status) }
    }

    var requests: [String] { state.withLock { $0.requests } }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let text = url.absoluteString
        return try state.withLock { state in
            state.requests.append(text)
            if let hit = state.routes[text] { return hit }
            if let match = state.routes.first(where: { $0.key.hasPrefix("prefix:") && text.hasPrefix(String($0.key.dropFirst(7))) }) {
                return match.value
            }
            throw URLError(.cannotConnectToHost)
        }
    }
}

// Covers are generated; catalog answers are invented JSON.

@Suite("Artwork pipeline")
struct ArtworkPipelineTests {
    let scratch = ScratchDirectory()
    let fetcher = FakeFetcher()
    /// Shared so a test can wait for the pipeline's writes.
    let disk: ArtworkDiskCache

    init() {
        disk = ArtworkDiskCache(directory: scratch.url)
    }

    private func pipeline(catalog: Bool = true) -> ArtworkPipeline {
        ArtworkPipeline(
            disk: disk,
            fetcher: fetcher,
            catalog: catalog ? ITunesSearch(fetcher: fetcher, storefront: { "TR" }) : nil
        )
    }

    private func snapshot(_ track: Track, data: Data? = nil, kind: ContentKind = .music) -> NowPlayingSnapshot {
        NowPlayingSnapshot(track: track, elapsedTime: 0, playbackRate: 1, timestamp: Date(), contentKind: kind, artworkData: data)
    }

    private func catalogAnswer(title: String, artist: String, art: String, durationMillis: Int = 200_000) -> Data {
        let json = """
        {"resultCount":1,"results":[{"trackId":1,"trackName":"\(title)","artistName":"\(artist)","collectionName":"Invented Album","trackTimeMillis":\(durationMillis),"artworkUrl100":"\(art)/100x100bb.jpg"}]}
        """
        return Data(json.utf8)
    }

    @Test("Embedded bytes decode to a square cover with a palette, stored for later")
    func embedded() async throws {
        let teal = SRGBColor("#0E7C86")
        let data = TestImages.png(TestImages.solid(teal, width: 700, height: 700))
        let track = Track(id: "music:1", source: .appleMusic, title: "Glass Harbor", artist: "Nova Atlas", duration: 200)
        let artwork = try #require(await pipeline().artwork(for: snapshot(track, data: data), pixelSize: 300))
        #expect(artwork.pixelWidth == 300 && artwork.pixelHeight == 300)
        let palette = try #require(artwork.palette)
        #expect(palette.primary.okLab.distance(to: teal.okLab) < 0.05)
        #expect(fetcher.requests.isEmpty, "a large embedded cover needs no lookup")
        disk.flush()
        #expect(disk.contains(ArtworkPipeline.coverKey(for: track)))
        let stored = await pipeline().storedCover(for: track, pixelSize: 64)
        #expect(stored?.pixelWidth == 64)
    }

    @Test("Cover URLs are fetched once, then served from disk")
    func urlCaching() async throws {
        let url = "https://covers.invalid/a.png"
        fetcher.serve(url, TestImages.png(TestImages.solid(SRGBColor("#FF6F59"), width: 640, height: 640)))
        let track = Track(id: "spotify:track:x", source: .spotify, title: "Paper Satellites", artist: "The Quiet Ferns", artworkURL: URL(string: url))
        let first = await pipeline().artwork(for: snapshot(track), pixelSize: 600)
        #expect(first != nil)
        disk.flush()
        let second = await pipeline().artwork(for: snapshot(track), pixelSize: 600)
        #expect(second?.identifier == first?.identifier)
        #expect(fetcher.requests.filter { $0 == url }.count == 1, "the second pipeline found it on disk")
    }

    @Test("A small cover is upgraded from the catalog when it matches")
    func catalogUpgrade() async throws {
        fetcher.serve(prefix: "https://itunes.apple.com/search", catalogAnswer(title: "Glass Harbor", artist: "Nova Atlas", art: "https://catalog.invalid/glass"))
        fetcher.serve("https://catalog.invalid/glass/1000x1000bb.jpg", TestImages.png(TestImages.solid(SRGBColor("#2F6BFF"), width: 1000, height: 1000)))
        let tiny = TestImages.png(TestImages.solid(SRGBColor("#2F6BFF"), width: 120, height: 120))
        let track = Track(id: "mr:1", source: .youtubeMusic, title: "Glass Harbor (feat. Ida Vale)", artist: "Nova Atlas", duration: 201)
        let artwork = try #require(await pipeline().artwork(for: snapshot(track, data: tiny), pixelSize: 600))
        #expect(artwork.pixelWidth == 600, "the catalog copy is large enough")
        #expect(artwork.identifier.hasPrefix("url:https://catalog.invalid"))
        let search = try #require(fetcher.requests.first { $0.hasPrefix("https://itunes.apple.com/search") })
        #expect(search.contains("country=tr"))
        #expect(search.contains("entity=song"))
    }

    @Test("No lookups for videos, the demo or local files; misses are remembered")
    func lookupPolicy() async throws {
        fetcher.serve(prefix: "https://itunes.apple.com/search", Data(#"{"resultCount":0,"results":[]}"#.utf8))
        let tiny = TestImages.png(TestImages.solid(.white, width: 64, height: 64))
        let video = Track(id: "v", source: .youtube, title: "Folding a paper boat", artist: "Craft Corner")
        _ = await pipeline().artwork(for: snapshot(video, data: tiny, kind: .video), pixelSize: 600)
        let demo = Track(id: "demo:x", source: .demo, title: "Glass Harbor", artist: "Nova Atlas")
        _ = await pipeline().artwork(for: snapshot(demo), pixelSize: 600)
        #expect(fetcher.requests.isEmpty)

        let song = Track(id: "s", source: .tidal, title: "Unknown Song", artist: "Unknown Band")
        let shared = pipeline()
        #expect(await shared.artwork(for: snapshot(song), pixelSize: 300) == nil)
        #expect(await shared.artwork(for: snapshot(song), pixelSize: 400) == nil)
        #expect(fetcher.requests.count == 1, "the miss is remembered")
    }

    @Test("Network failures are not remembered as misses")
    func failuresRetry() async {
        let song = Track(id: "s", source: .tidal, title: "Offline Song", artist: "Unknown Band")
        let shared = pipeline()
        #expect(await shared.artwork(for: snapshot(song), pixelSize: 300) == nil)
        #expect(await shared.artwork(for: snapshot(song), pixelSize: 400) == nil)
        #expect(fetcher.requests.count == 2)
    }

    @Test("Spotify covers come from oEmbed by track ID, at 640 px")
    func spotifyOEmbed() async throws {
        let id = "0123456789abcdefABCDEF"
        fetcher.serve("https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(id)",
                      Data(#"{"thumbnail_url":"https://i.scdn.co/image/ab67616d00001e02invented"}"#.utf8))
        fetcher.serve("https://i.scdn.co/image/ab67616d0000b273invented", TestImages.png(TestImages.solid(SRGBColor("#5B3CC4"), width: 640, height: 640)))
        let track = Track(id: "spotify:track:\(id)", source: .spotify, title: "Paper Satellites", artist: "The Quiet Ferns")
        let artwork = try #require(await pipeline(catalog: false).artwork(for: snapshot(track), pixelSize: 600))
        #expect(artwork.pixelWidth == 600)
        #expect(artwork.identifier == "url:https://i.scdn.co/image/ab67616d0000b273invented")
    }

    @Test("Concurrent requests for one cover share one load")
    func inFlight() async {
        let url = "https://covers.invalid/shared.png"
        fetcher.serve(url, TestImages.png(TestImages.solid(.black, width: 300, height: 300)))
        let track = Track(id: "x", source: .spotify, title: "Copper", artist: "Lumen", artworkURL: URL(string: url))
        let shared = pipeline(catalog: false)
        let request = snapshot(track)
        async let a = shared.artwork(for: request, pixelSize: 300)
        async let b = shared.artwork(for: request, pixelSize: 300)
        let results = await [a, b]
        #expect(results.allSatisfy { $0 != nil })
        #expect(fetcher.requests.filter { $0 == url }.count == 1)
    }

    @Test("Video thumbnails lose their bars and become square")
    func letterbox() throws {
        let data = TestImages.png(TestImages.letterboxed(SRGBColor("#E0218A"), width: 160, height: 120, bar: 15))
        let decoded = try #require(ArtworkImageDecoder.decodeSquare(data, maxPixelSize: 512))
        #expect(decoded.image.width == decoded.image.height)
        #expect(decoded.image.width == 90, "the 90 px tall picture between the bars")
        #expect(decoded.sourcePixelSize == 160)
        let palette = PaletteExtractor.swatches(from: decoded.image)
        #expect(palette[0].population > 0.95, "no black left")
        #expect(ArtworkImageDecoder.aspectRatio(of: data).map { abs($0 - 4.0 / 3) < 0.01 } == true)
        #expect(ArtworkImageDecoder.decodeSquare(Data("not an image".utf8), maxPixelSize: 100) == nil)
    }

    @Test("The disk cache prunes old and excess files")
    func pruning() throws {
        let cache = ArtworkDiskCache(directory: scratch.url, maximumBytes: 2500, maximumAge: 100)
        for index in 0..<4 {
            cache.store(Data(repeating: UInt8(index), count: 1000), forKey: "k\(index)")
        }
        cache.flush()
        let old = cache.url(forKey: "k0")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: old.path)
        cache.prune()
        cache.flush()
        #expect(!cache.contains("k0"), "too old")
        let left = (0..<4).filter { cache.contains("k\($0)") }.count
        #expect(left == 2, "within 2500 bytes")
    }
}

@Suite("Catalog lookups")
struct CatalogTests {
    private func song(_ title: String, _ artist: String, millis: Int? = 200_000, album: String? = nil) -> ITunesSong {
        ITunesSong(trackName: title, artistName: artist, collectionName: album, trackTimeMillis: millis, artworkUrl100: "https://catalog.invalid/a/100x100bb.jpg")
    }

    @Test("Matches survive decorations and reject other songs")
    func matching() {
        let track = Track(id: "1", source: .spotify, title: "Glass Harbor - 2015 Remaster", artist: "Nova Atlas", album: "Low Tide Lights", duration: 200)
        let candidates = [
            song("Glass Harbor (Live)", "Nova Atlas", millis: 260_000),
            song("Glass Harbour", "Nova Atlas"),
            song("Glass Harbor", "Nova Atlas & Ida Vale", millis: 199_000),
            song("Glass Harbor", "Nova Atlas", millis: 201_000, album: "Low Tide Lights"),
        ]
        #expect(ITunesSearch.bestMatch(for: track, in: candidates) == candidates[3], "same album and length rank highest")
        #expect(ITunesSearch.bestMatch(for: track, in: [candidates[0]]) == nil, "a minute longer is another recording")
        #expect(ITunesSearch.bestMatch(for: track, in: [candidates[1]]) == nil, "another title")
        #expect(ITunesSearch.bestMatch(for: track, in: [candidates[2]]) == candidates[2], "the artist list contains ours")
        #expect(ITunesSearch.bestMatch(for: track, in: [song("Glass Harbor", "Someone Else")]) == nil)
        let unknownLength = Track(id: "2", source: .tidal, title: "Glass Harbor", artist: "nova atlas")
        #expect(ITunesSearch.bestMatch(for: unknownLength, in: [candidates[0]]) == candidates[0])
    }

    @Test("Parses results leniently and resizes artwork URLs")
    func parsing() throws {
        let json = #"{"resultCount":2,"results":[{"trackName":"A","artistName":"B","artworkUrl100":"https://x.invalid/y/100x100bb.jpg"},{"wrapperType":"artist"}]}"#
        let songs = try ITunesSearch.parse(Data(json.utf8))
        #expect(songs.count == 1)
        #expect(ITunesSearch.artworkURL(for: songs[0], pixelSize: 1000)?.absoluteString == "https://x.invalid/y/1000x1000bb.jpg")
        #expect(ITunesSearch.artworkURL(for: songs[0], pixelSize: 9000)?.absoluteString == "https://x.invalid/y/3000x3000bb.jpg")
        let url = try #require(ITunesSearch.searchURL(term: "Nova Atlas Glass Harbor", country: "TR"))
        #expect(url.absoluteString.contains("term=Nova%20Atlas%20Glass%20Harbor"))
        #expect(ITunesSearch.searchTerm(for: Track(id: "1", source: .spotify, title: "Glass Harbor (feat. Ida Vale)", artist: "Nova Atlas")) == "Nova Atlas Glass Harbor")
    }

    @Test("Spotify track IDs and cover sizes")
    func spotify() {
        #expect(SpotifyOEmbed.trackID(from: "spotify:track:0123456789abcdefABCDEF") == "0123456789abcdefABCDEF")
        #expect(SpotifyOEmbed.trackID(from: "https://open.spotify.com/track/0123456789abcdefABCDEF?si=abc") == "0123456789abcdefABCDEF")
        #expect(SpotifyOEmbed.trackID(from: "spotify:ad:0123456789abcdefABCDEF") == nil)
        #expect(SpotifyOEmbed.trackID(from: "spotify:track:short") == nil)
        let small = URL(string: "https://i.scdn.co/image/ab67616d00001e02abc")!
        #expect(SpotifyOEmbed.largeVariant(of: small).absoluteString == "https://i.scdn.co/image/ab67616d0000b273abc")
        #expect(SpotifyOEmbed.thumbnailURL(from: Data(#"{"thumbnail_url":"https://i.scdn.co/image/x"}"#.utf8))?.host == "i.scdn.co")
        #expect(SpotifyOEmbed.thumbnailURL(from: Data("{}".utf8)) == nil)
    }
}
