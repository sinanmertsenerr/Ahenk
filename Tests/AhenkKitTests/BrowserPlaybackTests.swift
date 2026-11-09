import Foundation
import Testing
@testable import AhenkKit

// Invented songs, playlists and lines only.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func report(
    _ key: String, site: MusicSource, connection: Int, tabID: Int, playing: Bool = false, active: Bool = false,
    lastActive: Date? = nil, sampled: Date = t0, capabilities: Set<BridgeCapability> = [.playPause, .queue]
) -> BrowserTabReport {
    var report = BrowserTabReport(
        tabID: key, browserBundleIdentifier: "com.google.Chrome", site: site, title: "Song \(tabID)", artist: "Nadia Ferro",
        isPlaying: playing, sampledAt: sampled
    )
    report.connectionID = connection
    report.browserTabID = tabID
    report.isActiveTab = active
    report.lastActive = lastActive
    report.bridgeCapabilities = capabilities
    return report
}

@Suite("Playing on music sites: decisions")
struct BrowserPlaybackPolicyTests {
    @Test("The site's playing tab takes requests, else the one looked at last")
    func tabChoice() {
        let idle = report("a/1", site: .youtubeMusic, connection: 1, tabID: 1, lastActive: t0 + 50)
        let selected = report("a/2", site: .youtubeMusic, connection: 1, tabID: 2, active: true, lastActive: t0 + 10)
        let playing = report("b/3", site: .youtubeMusic, connection: 2, tabID: 3, playing: true)
        let other = report("a/4", site: .spotifyWeb, connection: 1, tabID: 4, playing: true)
        #expect(BrowserPlaybackPolicy.tab(for: .youtubeMusic, among: [idle, selected, playing, other])?.tabID == "b/3")
        #expect(BrowserPlaybackPolicy.tab(for: .youtubeMusic, among: [idle, selected, other])?.tabID == "a/2", "the selected tab")
        #expect(BrowserPlaybackPolicy.tab(for: .youtubeMusic, among: [idle, other])?.tabID == "a/1")
        #expect(BrowserPlaybackPolicy.tab(for: .deezer, among: [idle, other]) == nil)
    }

    @Test("Routes: no extension, a tab, or a new tab in the browser used last")
    func routes() {
        let tabs = [
            report("a/1", site: .spotifyWeb, connection: 1, tabID: 1, lastActive: t0 + 5),
            report("b/7", site: .soundCloud, connection: 2, tabID: 7, lastActive: t0 + 90),
        ]
        #expect(BrowserPlaybackPolicy.route(for: .spotifyWeb, tabs: [], connections: []) == .noExtension)
        #expect(BrowserPlaybackPolicy.route(for: .spotifyWeb, tabs: tabs, connections: [1, 2]) == .tab(connection: 1, tabID: 1))
        #expect(BrowserPlaybackPolicy.route(for: .tidal, tabs: tabs, connections: [1, 2]) == .newTab(connection: 2))
        #expect(BrowserPlaybackPolicy.route(for: .tidal, tabs: [], connections: [3, 4]) == .newTab(connection: 4))
    }

    @Test("What the extension's answer means")
    func outcomes() {
        #expect(BrowserPlaybackPolicy.outcome(of: nil) == .failed("no answer from the browser"))
        #expect(BrowserPlaybackPolicy.outcome(of: BridgeResult(id: "1", ok: true, outcome: .started)) == .started)
        #expect(BrowserPlaybackPolicy.outcome(of: BridgeResult(id: "1", ok: true)) == .started)
        #expect(BrowserPlaybackPolicy.outcome(of: BridgeResult(id: "1", ok: true, outcome: .opened)) == .opened)
        #expect(BrowserPlaybackPolicy.outcome(of: BridgeResult(id: "1", ok: false, outcome: .notFound)) == .notFound)
        #expect(BrowserPlaybackPolicy.outcome(of: BridgeResult(id: "1", ok: false, outcome: .noTab)) == .noTab)
        #expect(BrowserPlaybackPolicy.outcome(of: BridgeResult(id: "1", ok: false, error: "x")) == .failed("x"))
    }

    @Test("A pick is searched by its metadata, or played by the site's own ID")
    func picks() {
        let catalog = CatalogSong(id: "itunes:1", title: "Quiet Engines", artistName: "Nadia Ferro", albumTitle: "Low Orbit Letters", duration: 187)
        let plain = BrowserPlaybackPolicy.bridgeSong(catalog, on: .youtubeMusic, spotifyTrackID: nil)
        #expect(plain == BridgeSong(title: "Quiet Engines", artist: "Nadia Ferro", album: "Low Orbit Letters", duration: 187))
        #expect(BrowserPlaybackPolicy.bridgeSong(catalog, on: .spotifyWeb, spotifyTrackID: "AhenkMockTrackSpotify1").trackID == "AhenkMockTrackSpotify1")
        var played = catalog
        played.origin = Track(id: "https://music.youtube.com/watch?v=ahenkMock02", source: .youtubeMusic, title: "Quiet Engines", artist: "Nadia Ferro")
        let again = BrowserPlaybackPolicy.bridgeSong(played, on: .youtubeMusic, spotifyTrackID: nil)
        #expect(again.trackID == "ahenkMock02" && again.url == "https://music.youtube.com/watch?v=ahenkMock02")
        #expect(BrowserPlaybackPolicy.bridgeSong(played, on: .soundCloud, spotifyTrackID: nil).trackID == nil, "an ID of another source is no use")
    }

    @Test("Site playlists and songs as the player lists them")
    func catalogForms() throws {
        let id = BrowserPlaybackPolicy.playlistID("PLahenkMock1", on: .youtubeMusic)
        #expect(id == "site:youtubeMusic:PLahenkMock1")
        let parsed = try #require(BrowserPlaybackPolicy.parsePlaylistID(id))
        #expect(parsed.site == .youtubeMusic && parsed.id == "PLahenkMock1")
        #expect(BrowserPlaybackPolicy.parsePlaylistID("site:spotify:with:colons")?.id == "with:colons")
        #expect(BrowserPlaybackPolicy.parsePlaylistID("music:playlist:1") == nil)
        #expect(BrowserPlaybackPolicy.parsePlaylistID("site:napster:x") == nil)
        #expect(BrowserPlaybackPolicy.catalogPlaylist(BridgePlaylist(id: "x", name: "  "), on: .tidal) == nil)

        let song = BrowserPlaybackPolicy.catalogSong(BridgeSong(title: "Saffron Static", artist: "Kestrel & Vale", duration: 236, trackID: "ahenkMock03"), on: .youtubeMusic)
        #expect(song.origin?.source == .youtubeMusic && song.origin?.id == "https://music.youtube.com/watch?v=ahenkMock03")
        #expect(song.id == "site:youtubeMusic:https://music.youtube.com/watch?v=ahenkMock03" && song.duration == 236)
        let unnamed = BrowserPlaybackPolicy.catalogSong(BridgeSong(title: "Marmara Neon", artist: "Deniz Ulaş Trio"), on: .soundCloud)
        #expect(unnamed.origin?.id == TrackMatching.metadataKey(title: "Marmara Neon", artist: "Deniz Ulaş Trio", album: ""))
    }

    @Test("The site's queue: what comes after the song that plays")
    func queue() {
        let items = (0..<4).map { BrowserQueue.Item(index: $0, song: CatalogSong(id: "\($0)", title: "S\($0)", artistName: "A"), isCurrent: $0 == 1) }
        #expect(BrowserQueue(site: .youtubeMusic, items: items, canRemove: true).upNext.map(\.index) == [2, 3])
        #expect(BrowserQueue(site: .youtubeMusic, items: items.map { var i = $0; i.isCurrent = false; return i }, canRemove: false).upNext.count == 4)
    }
}

@Suite("Site lyrics")
struct BrowserLyricsProviderTests {
    private let song = BridgeSong(title: "Lanterns Under Ice", artist: "Mirela Stoica", album: "Northbound Postcards", duration: 223, trackID: "AhenkMockTrackSpotify1")
    private let lines = [
        BridgeLyricLine(start: 4.2, text: "Frost on the ferry rails"),
        BridgeLyricLine(start: 8.9, end: 12.5, text: "We counted every light"),
        BridgeLyricLine(start: 13, text: ""),
        BridgeLyricLine(start: 17.75, text: "Northbound, northbound"),
    ]

    @Test("The song's own lyrics answer as the recording's, others not at all")
    func answers() async throws {
        let provider = BrowserLyricsProvider()
        provider.store(BridgeSiteLyrics(tabID: 1, site: "spotify", song: song, lines: lines), tabKey: "p/1")
        let byID = LyricsQuery(title: "Lanterns under ice (2019 mix)", artist: "Someone Else", spotifyTrackID: "AhenkMockTrackSpotify1")
        let response = try await provider.fetchResponse(byID)
        #expect(response.timingAuthority == .canonicalRecording && response.source == "site:spotify")
        guard case .synced(let synced) = response.result else { Issue.record("not synced"); return }
        #expect(synced.lines.map(\.start) == [4.2, 8.9, 13, 17.75] && synced.lines[1].end == 12.5)
        let byMetadata = LyricsQuery(title: "Lanterns Under Ice", artist: "Mirela Stoica", duration: 224)
        #expect(try await provider.fetch(byMetadata) != .notFound)
        #expect(try await provider.fetch(LyricsQuery(title: "Lanterns Under Ice", artist: "Mirela Stoica", duration: 300)) == .notFound, "another edit")
        #expect(try await provider.fetch(LyricsQuery(title: "Quiet Engines", artist: "Nadia Ferro")) == .notFound)
        #expect(try await provider.fetch(LyricsQuery(title: "x", artist: "y", spotifyTrackID: "AhenkMockTrackSpotify2")) == .notFound)
        #expect(BrowserLyricsProvider.site(ofSource: response.source) == .spotify)
        #expect(BrowserLyricsProvider.site(ofSource: "LRCLIB") == nil)
    }

    @Test("Untimed or empty lists are ignored; a newer copy replaces the older; arrivals are announced")
    func storing() async throws {
        let provider = BrowserLyricsProvider()
        let changes = provider.changes()
        provider.store(BridgeSiteLyrics(tabID: 1, site: "spotify", song: song, lines: [BridgeLyricLine(start: 1, text: "  ")]), tabKey: "p/1")
        provider.store(BridgeSiteLyrics(tabID: 1, site: "napster", song: song, lines: lines), tabKey: "p/1")
        #expect(provider.lookup(LyricsQuery(title: song.title, artist: song.artist)) == nil)
        provider.store(BridgeSiteLyrics(tabID: 1, site: "tidal", song: song, lines: lines), tabKey: "p/1")
        provider.store(BridgeSiteLyrics(tabID: 1, site: "tidal", song: song, lines: Array(lines.prefix(2))), tabKey: "p/1")
        #expect(provider.lookup(LyricsQuery(title: song.title, artist: song.artist))?.lyrics.lines.count == 2)
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        for index in 0..<(BrowserLyricsProvider.capacity + 5) {
            provider.store(BridgeSiteLyrics(tabID: index, site: "deezer", song: BridgeSong(title: "Song \(index)", artist: "A"), lines: lines), tabKey: "p/\(index)")
        }
        #expect(provider.lookup(LyricsQuery(title: "Song 0", artist: "A")) == nil, "the oldest are dropped")
        #expect(provider.lookup(LyricsQuery(title: "Song \(BrowserLyricsProvider.capacity + 4)", artist: "A")) != nil)
    }

    @Test("The finder asks the site before its cache, after the user's own pick")
    func finderOrder() async throws {
        let directory = ScratchDirectory()
        let site = BrowserLyricsProvider()
        let cache = LyricsCache(directory: directory.url)
        let query = LyricsQuery(title: song.title, artist: song.artist, duration: 223)
        await cache.store(LyricsResponse(result: .plain("cached words"), source: "LRCLIB"), for: query.cacheKey)
        let finder = LyricsFinder(chain: LyricsChain(providers: [site]), cache: cache, songs: LyricsSongStore(fileURL: nil))
        #expect(await finder.find(query).origin == .cache)
        site.store(BridgeSiteLyrics(tabID: 1, site: "spotify", song: song, lines: lines), tabKey: "p/1")
        let found = await finder.find(query)
        #expect(found.origin == .playingSource && found.response.timingAuthority == .canonicalRecording)
        #expect(await cache.load("choice\u{1}" + query.cacheKey) == nil, "site lyrics are never cached")

        // Picking the site's version in Other Lyrics is the automatic pick.
        let own = try #require(await finder.versions(for: query).first { $0.provider == BrowserLyricsProvider.providerName })
        let picked = try await finder.choose(own, for: query)
        #expect(picked.timingAuthority == .canonicalRecording && picked.source == "site:spotify")
        #expect(finder.songs.entry(for: query.cacheKey)?.choice == nil, "no choice is kept")
        #expect(await cache.load("choice\u{1}" + query.cacheKey) == nil, "nor cached")
    }
}
