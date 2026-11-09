import Foundation
import Testing
@testable import AhenkKit

// Invented songs, IDs and browsers only.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let chrome = BridgeBrowserProcess(processIdentifier: 501, bundleIdentifier: "com.google.Chrome")
private let firefox = BridgeBrowserProcess(processIdentifier: 777, bundleIdentifier: "org.mozilla.firefox")

private func hello(_ profile: String, version: Int = 1, minimum: Int? = 1, browser: String = "Chrome") -> BridgeInbound {
    .hello(BridgeHello(protocolVersion: version, minimumProtocolVersion: minimum, extensionVersion: "1.0.0", browser: BridgeBrowser(name: browser), profile: profile))
}

private func tab(_ id: Int, _ title: String, site: String = "youtubeMusic", playing: Bool = true, url: String? = nil, at time: Date = t0) -> BridgeTab {
    BridgeTab(
        tabID: id, site: site, url: url, title: title, artist: "Orchid Telemetry", album: "Tidal Glass", duration: 214, position: 30,
        sampledAt: time.timeIntervalSince1970 * 1000, state: playing ? .playing : .paused, kind: .music,
        capabilities: [.playPause, .next, .previous, .seek, .like, .unlike]
    )
}

@Suite("Bridge registry")
struct BridgeRegistryTests {
    @Test("Hello is welcomed and the browser looked up; tabs wait for that")
    func greeting() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        #expect(registry.received(.tabs([tab(4, "Velvet Harbor Lights")]), from: 1, at: t0).isEmpty, "nothing counts before hello")
        let effects = registry.received(hello("p1"), from: 1, at: t0)
        #expect(effects == [.send(.welcome(BridgeWelcome(protocolVersion: 1, appVersion: "0.1.0")), to: 1), .identify(1)])
        #expect(registry.received(.tabs([tab(4, "Velvet Harbor Lights")]), from: 1, at: t0).isEmpty, "held until the browser is known")
        #expect(registry.reports(now: t0).isEmpty)
        #expect(registry.identified(1, as: chrome) == [.tabsChanged])
        let reports = registry.reports(now: t0)
        #expect(reports.map(\.tabID) == ["p1/4"])
        #expect(reports.first?.browserBundleIdentifier == "com.google.Chrome" && reports.first?.processIdentifier == 501)
        #expect(registry.locate(tabKey: "p1/4")! == (1, 4))
    }

    @Test("A version Ahenk does not speak is told and closed")
    func incompatible() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        let effects = registry.received(hello("p1", version: 4, minimum: 3), from: 1, at: t0)
        #expect(effects.count == 2)
        guard case .send(.error(let code, _), to: 1) = effects.first, case .close(1, _) = effects.last else {
            Issue.record("expected an error and a close, got \(effects)")
            return
        }
        #expect(code == "incompatible")
        #expect(registry.connections.isEmpty)
    }

    @Test("Silence closes: no hello in time, then no heartbeat in time")
    func timeouts() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        #expect(registry.nextDeadline == t0 + BridgeProtocol.helloTimeout)
        let effects = registry.tick(now: t0 + BridgeProtocol.helloTimeout)
        #expect(effects.contains(.close(1, reason: "no hello")))

        registry.opened(2, at: t0)
        _ = registry.received(hello("p2"), from: 2, at: t0)
        _ = registry.identified(2, as: chrome)
        _ = registry.received(.tabs([tab(1, "Quiet Engines")]), from: 2, at: t0)
        #expect(registry.received(.ping, from: 2, at: t0 + 20) == [.send(.pong, to: 2)])
        #expect(registry.tick(now: t0 + 60).isEmpty, "the ping kept it alive")
        let closed = registry.tick(now: t0 + 20 + BridgeProtocol.idleTimeout)
        #expect(closed.contains(.tabsChanged) && closed.contains { if case .close(2, _) = $0 { true } else { false } })
        #expect(registry.reports(now: t0).isEmpty)
    }

    @Test("A browser that cannot be looked up still reports, after a moment")
    func identifyTimeout() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        _ = registry.received(hello("p1"), from: 1, at: t0)
        _ = registry.received(.tabs([tab(4, "Velvet Harbor Lights")]), from: 1, at: t0)
        #expect(registry.tick(now: t0 + 2) == [.tabsChanged])
        #expect(registry.reports(now: t0).first?.browserBundleIdentifier == nil)
    }

    @Test("A reconnect from the same profile replaces the old connection and keeps its tabs")
    func reconnect() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        _ = registry.received(hello("same"), from: 1, at: t0)
        _ = registry.identified(1, as: chrome)
        _ = registry.received(.tabs([tab(4, "Velvet Harbor Lights")]), from: 1, at: t0)
        registry.opened(2, at: t0 + 5)
        let effects = registry.received(hello("same"), from: 2, at: t0 + 5)
        #expect(effects.contains { if case .close(1, _) = $0 { true } else { false } })
        #expect(effects.contains(.identify(2)), "looked up again (the browser may have restarted)")
        #expect(registry.reports(now: t0).map(\.tabID) == ["same/4"], "the same tab key: the hub sees the same player")
        #expect(registry.reports(now: t0).first?.processIdentifier == 501, "the old answer holds meanwhile")
        #expect(registry.identified(2, as: chrome).isEmpty, "the same answer changes nothing")
        let restarted = BridgeBrowserProcess(processIdentifier: 640, bundleIdentifier: "com.google.Chrome")
        #expect(registry.identified(2, as: restarted) == [.tabsChanged])
        #expect(registry.identified(2, as: nil).isEmpty, "no answer keeps the old one")
        #expect(registry.reports(now: t0).first?.processIdentifier == 640)
        _ = registry.received(.tabs([tab(4, "Velvet Harbor Lights"), tab(9, "Quiet Engines", playing: false)]), from: 2, at: t0 + 6)
        #expect(registry.reports(now: t0).map(\.tabID) == ["same/4", "same/9"])
        #expect(registry.locate(tabKey: "same/9")! == (2, 9))
    }

    @Test("Several browsers and tabs at once")
    func severalBrowsers() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        registry.opened(2, at: t0)
        _ = registry.received(hello("chrome-profile"), from: 1, at: t0)
        _ = registry.received(hello("firefox-profile", browser: "Firefox"), from: 2, at: t0)
        _ = registry.identified(1, as: chrome)
        _ = registry.identified(2, as: firefox)
        _ = registry.received(.tabs([tab(1, "Velvet Harbor Lights"), tab(2, "Harbor walk", site: "youtube", playing: false)]), from: 1, at: t0)
        _ = registry.received(.tab(tab(1, "Saffron Static", site: "soundCloud")), from: 2, at: t0)
        let reports = registry.reports(now: t0)
        #expect(reports.map(\.tabID) == ["chrome-profile/1", "chrome-profile/2", "firefox-profile/1"])
        #expect(reports.map(\.site) == [.youtubeMusic, .youtube, .soundCloud])
        #expect(Set(reports.map(\.playerID)).count == 3)
        #expect(registry.summaries(now: t0).map(\.tabs.count) == [2, 1])
        #expect(registry.received(.tabRemoved(tabID: 2), from: 1, at: t0) == [.tabsChanged])
        #expect(registry.closed(2) == [.tabsChanged])
        #expect(registry.reports(now: t0).map(\.tabID) == ["chrome-profile/1"])
    }

    @Test("An unchanged tab is no change; a result and lyrics pass through")
    func passThrough() {
        var registry = BridgeRegistry(appVersion: "0.1.0")
        registry.opened(1, at: t0)
        _ = registry.received(hello("p"), from: 1, at: t0)
        _ = registry.identified(1, as: chrome)
        #expect(registry.received(.tab(tab(1, "A")), from: 1, at: t0) == [.tabsChanged])
        #expect(registry.received(.tab(tab(1, "A")), from: 1, at: t0).isEmpty)
        let result = BridgeResult(id: "r1", ok: true)
        #expect(registry.received(.result(result), from: 1, at: t0) == [.result(result, from: 1)])
        let lyrics = BridgeSiteLyrics(tabID: 1, site: "spotify", song: BridgeSong(title: "A", artist: "B"), lines: [])
        #expect(registry.received(.lyrics(lyrics), from: 1, at: t0) == [.lyrics(lyrics, tabKey: "p/1")])
        #expect(registry.received(.unknown("future"), from: 1, at: t0).isEmpty)
    }
}

@Suite("Bridge tabs as players")
struct BridgeTabReportTests {
    private func report(_ tab: BridgeTab, now: Date = t0) -> BrowserTabReport? {
        var connection = BridgeRegistry.Connection(id: 3, openedAt: t0, lastMessageAt: t0)
        connection.hello = BridgeHello(extensionVersion: "1", browser: BridgeBrowser(name: "Chrome"), profile: "prof")
        connection.browser = chrome
        connection.isIdentified = true
        return BrowserTabReport(tab: tab, connection: connection, now: now)
    }

    @Test("Sites map onto sources; a page cannot claim another site")
    func siteMapping() {
        var claimed = tab(1, "A", site: "spotify", url: "https://music.youtube.com/watch?v=ahenkMockV1")
        #expect(report(claimed)?.site == .youtubeMusic, "the page's host wins")
        claimed.url = "https://example.com/"
        #expect(report(claimed)?.site == .spotifyWeb, "unknown host: the reported site")
        #expect(report(tab(1, "A", site: "napster")) == nil)
        for (site, source) in [("youtubeMusic", MusicSource.youtubeMusic), ("youtube", .youtube), ("spotify", .spotifyWeb), ("soundCloud", .soundCloud),
                               ("amazonMusic", .amazonMusic), ("deezer", .deezer), ("tidal", .tidal)] {
            #expect(report(tab(1, "A", site: site))?.site == source)
        }
    }

    @Test("Snapshots carry the browser, the tab, the song's own ID, time and commands")
    func snapshot() throws {
        var spotify = tab(8, "Lanterns Under Ice", site: "spotify", url: "https://open.spotify.com/album/AhenkMockAlbumSpotify1")
        spotify.trackID = "AhenkMockTrackSpotify1"
        spotify.capabilities = [.playPause, .previous, .shuffle, .repeat, .like]
        spotify.playbackRate = 1.25
        let snapshot = try #require(report(spotify)?.snapshot)
        #expect(snapshot.track.id == "spotify:track:AhenkMockTrackSpotify1")
        #expect(LyricsQuery(track: snapshot.track).spotifyTrackID == "AhenkMockTrackSpotify1", "the lyrics get the recording")
        #expect(snapshot.bundleIdentifier == "com.google.Chrome" && snapshot.processIdentifier == 501 && snapshot.instanceIdentifier == "prof/8")
        #expect(snapshot.capabilities == [.playPause, .skip, .shuffle, .repeatAll, .like])
        #expect(snapshot.playbackRate == 1.25 && snapshot.elapsedTime == 30 && snapshot.timestamp == t0)

        var video = tab(2, "Harbor walk", site: "youtube")
        video.trackURL = "https://www.youtube.com/watch?v=ahenkMockV1&list=PLx&t=40"
        video.kind = .video
        let youtube = try #require(report(video)?.snapshot)
        #expect(youtube.track.id == "https://www.youtube.com/watch?v=ahenkMockV1", "the watch URL, for the live wallpaper")
        #expect(youtube.contentKind == .video)
        #expect(youtube.songVideoKind == nil, "the page named no video type")

        // The page's musicVideoType reaches the hub: an art track (the cover
        // as a still) is not a video for the wallpaper; other sites never
        // carry one.
        var artTrack = tab(5, "Saffron Static")
        artTrack.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        #expect(try #require(report(artTrack)?.snapshot).songVideoKind == .artTrack)
        var official = tab(6, "Saffron Static")
        official.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        #expect(try #require(report(official)?.snapshot).songVideoKind == .officialVideo)
        var claimed = tab(7, "Lanterns Under Ice", site: "spotify")
        claimed.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        #expect(try #require(report(claimed)?.snapshot).songVideoKind == nil)

        var paused = tab(3, "A", playing: false)
        paused.position = nil
        let quiet = try #require(report(paused)?.snapshot)
        #expect(!quiet.isPlaying && !quiet.isPositionKnown)
    }

    @Test("A sample time from the future or long ago is replaced by now")
    func sampleTimes() {
        #expect(BrowserTabReport.sampleTime(0, now: t0) == t0)
        #expect(BrowserTabReport.sampleTime((t0 + 30).timeIntervalSince1970 * 1000, now: t0) == t0)
        #expect(BrowserTabReport.sampleTime((t0 - 7200).timeIntervalSince1970 * 1000, now: t0) == t0)
        let recent = t0 - 0.4
        #expect(abs(BrowserTabReport.sampleTime(recent.timeIntervalSince1970 * 1000, now: t0).timeIntervalSince(recent)) < 0.001)
    }
}

@Suite("Browser sites")
struct BrowserSiteTests {
    @Test("Host names")
    func hosts() {
        let cases: [(String, BrowserSite?)] = [
            ("music.youtube.com", .youtubeMusic), ("www.youtube.com", .youtube), ("m.youtube.com", .youtube), ("youtu.be", .youtube),
            ("open.spotify.com", .spotify), ("spotify.com", nil), ("soundcloud.com", .soundCloud), ("m.soundcloud.com", .soundCloud),
            ("music.amazon.com", .amazonMusic), ("music.amazon.co.uk", .amazonMusic), ("www.amazon.com", nil),
            ("www.deezer.com", .deezer), ("listen.tidal.com", .tidal), ("evil-youtube.com", nil), ("youtube.com.evil.example", nil),
            ("MUSIC.YOUTUBE.COM", .youtubeMusic),
        ]
        for (host, site) in cases {
            #expect(BrowserSite.site(forHost: host) == site, "\(host)")
        }
        #expect(BrowserSite.site(for: URL(string: "ftp://music.youtube.com/")!) == nil)
        for site in BrowserSite.allCases {
            #expect(BrowserSite(source: site.source) == site)
        }
        #expect(BrowserSite(source: .spotify) == nil, "the Spotify app is not a site")
    }

    @Test("Song IDs from links")
    func identifiers() {
        #expect(BrowserSite.youtubeVideoID("ahenkMockV1") == "ahenkMockV1")
        #expect(BrowserSite.youtubeVideoID("https://music.youtube.com/watch?v=ahenkMockV1&list=RDAMx") == "ahenkMockV1")
        #expect(BrowserSite.youtubeVideoID("https://youtu.be/ahenkMockV1?t=4") == "ahenkMockV1")
        #expect(BrowserSite.youtubeVideoID("https://www.youtube.com/shorts/ahenkMockV1") == "ahenkMockV1")
        #expect(BrowserSite.youtubeVideoID("https://example.com/watch?v=ahenkMockV1") == nil)
        #expect(BrowserSite.youtubeVideoID("too-short") == nil)
        #expect(BrowserSite.spotifyTrackID("spotify:track:AhenkMockTrackSpotify1") == "AhenkMockTrackSpotify1")
        #expect(BrowserSite.spotifyTrackID("https://open.spotify.com/track/AhenkMockTrackSpotify1?si=x") == "AhenkMockTrackSpotify1")
        #expect(BrowserSite.spotifyTrackID("/album/AhenkMockAlbumSpotify1?highlight=spotify:track:AhenkMockTrackSpotify1") == "AhenkMockTrackSpotify1")
        #expect(BrowserSite.spotifyTrackID("https://open.spotify.com/episode/AhenkMockTrackSpotify1") == nil)
        #expect(BrowserSite.tidal.trackIdentifier(trackID: "9", trackURL: "https://listen.tidal.com/track/9?play=true") == "https://listen.tidal.com/track/9")
        #expect(BrowserSite.deezer.trackIdentifier(trackID: "12", trackURL: nil) == "deezer:12")
        #expect(BrowserSite.soundCloud.trackIdentifier(trackID: nil, trackURL: nil) == nil)
    }
}

@Suite("Browser identity")
struct BrowserIdentityTests {
    @Test("A reported name narrows down the app")
    func candidates() {
        #expect(BrowserIdentity.bundleCandidates(for: BridgeBrowser(name: "Microsoft Edge")).first == "com.microsoft.edgemac")
        #expect(BrowserIdentity.bundleCandidates(for: BridgeBrowser(name: "Brave")).first == "com.brave.Browser")
        #expect(BrowserIdentity.bundleCandidates(for: BridgeBrowser(name: "Firefox")).first == "org.mozilla.firefox")
        #expect(BrowserIdentity.bundleCandidates(for: BridgeBrowser(name: "Google Chrome")).first == "com.google.Chrome")
        let chromium = BrowserIdentity.bundleCandidates(for: BridgeBrowser(name: "Chromium"))
        #expect(chromium.contains(KnownApps.search) && chromium.contains("company.thebrowser.Browser"))
        #expect(Set(chromium).count == chromium.count)
    }
}
