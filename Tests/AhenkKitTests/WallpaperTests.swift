import Foundation
import os
import Testing
@testable import AhenkKit

// Every artist, song, channel, video ID and address here is invented.

/// YouTube's search answers in the shape the web client gets them, built
/// from invented videos.
private enum SearchFixtures {
    static func renderer(
        _ id: String, _ title: String, channel: String, length: String? = "3:41", artistBadge: Bool = false, verified: Bool = false,
        snippet: String? = nil, views: String? = "1,204,330 views", live: Bool = false
    ) -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": id,
            "title": ["runs": [["text": title]]],
            "ownerText": ["runs": [["text": channel, "navigationEndpoint": ["browseEndpoint": ["browseId": "UC-\(channel.count)"]]]]],
        ]
        if let length { renderer["lengthText"] = ["simpleText": length] }
        var badges: [[String: Any]] = []
        if artistBadge { badges.append(["metadataBadgeRenderer": ["style": "BADGE_STYLE_TYPE_VERIFIED_ARTIST"]]) }
        if verified { badges.append(["metadataBadgeRenderer": ["style": "BADGE_STYLE_TYPE_VERIFIED"]]) }
        if !badges.isEmpty { renderer["ownerBadges"] = badges }
        if let snippet { renderer["detailedMetadataSnippets"] = [["snippetText": ["runs": [["text": snippet]]]]] }
        if let views { renderer["viewCountText"] = ["simpleText": views] }
        if live { renderer["badges"] = [["metadataBadgeRenderer": ["style": "BADGE_STYLE_TYPE_LIVE_NOW"]]] }
        return renderer
    }

    /// Renderers nested the way the web client nests them (a section, a
    /// shelf inside it), plus things that are not videos.
    static func response(_ renderers: [[String: Any]]) -> Data {
        let items = renderers.prefix(2).map { ["videoRenderer": $0] }
            + [["shelfRenderer": ["content": ["verticalListRenderer": ["items": renderers.dropFirst(2).map { ["videoRenderer": $0] }]]]]]
            + [["channelRenderer": ["channelId": "UC-x", "title": ["simpleText": "Not a video"]]]]
        let tree: [String: Any] = [
            "contents": ["twoColumnSearchResultsRenderer": ["primaryContents": ["sectionListRenderer": ["contents": [
                ["itemSectionRenderer": ["contents": items]],
                ["continuationItemRenderer": ["trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN"]],
            ]]]]],
        ]
        return try! JSONSerialization.data(withJSONObject: tree)
    }

    static func video(
        _ id: String, _ title: String, channel: String, duration: TimeInterval? = 221, artistChannel: Bool = false,
        verified: Bool = false, artTrack: Bool = false, live: Bool = false, views: Int? = 1_000_000
    ) -> YouTubeVideo {
        YouTubeVideo(
            id: id, title: title, channel: channel, duration: duration, isOfficialArtistChannel: artistChannel,
            isVerifiedChannel: verified || artistChannel, isArtTrack: artTrack, isLive: live, viewCount: views
        )
    }
}

@Suite("Wallpaper: YouTube search answers")
struct YouTubeSearchDecodingTests {
    @Test("Videos are found wherever they sit, each once, with their channel, length, badges and the art-track hint")
    func decodesWebClientAnswer() throws {
        let data = SearchFixtures.response([
            SearchFixtures.renderer("ahenkVid001", "Nova Atlas - Glass Harbor (Official Video)", channel: "Nova Atlas", length: "4:05", artistBadge: true),
            SearchFixtures.renderer("ahenkVid002", "Glass Harbor", channel: "Nova Atlas", snippet: "Provided to YouTube by Invented Label Glass Harbor"),
            SearchFixtures.renderer("ahenkVid003", "Harbor Lights Live", channel: "Some Stream", length: nil, live: true),
            SearchFixtures.renderer("ahenkVid004", "Glass Harbor (cover)", channel: "Kestrel Covers", length: "1:02:45", verified: true, views: nil),
            SearchFixtures.renderer("ahenkVid001", "Duplicate of the first", channel: "Nova Atlas"),
            SearchFixtures.renderer("bad", "A broken ID", channel: "Nobody"),
        ])
        let videos = try YouTubeSearchDecoder.videos(fromJSON: data)
        #expect(videos.map(\.id) == ["ahenkVid001", "ahenkVid002", "ahenkVid003", "ahenkVid004"])
        #expect(videos[0].title == "Nova Atlas - Glass Harbor (Official Video)" && videos[0].channel == "Nova Atlas")
        #expect(videos[0].duration == 245 && videos[0].isOfficialArtistChannel && videos[0].isVerifiedChannel && videos[0].viewCount == 1_204_330)
        #expect(videos[0].channelID == "UC-10")
        #expect(videos[1].isArtTrack && !videos[0].isArtTrack)
        #expect(videos[2].isLive && videos[2].duration == nil)
        #expect(videos[3].duration == 3_765 && videos[3].isVerifiedChannel && !videos[3].isOfficialArtistChannel && videos[3].viewCount == nil)
    }

    @Test("The results page's embedded data reads the same; anything else is refused")
    func decodesResultsPage() throws {
        let json = String(decoding: SearchFixtures.response([
            SearchFixtures.renderer("ahenkVid007", "Lumen Vale - Copper Moon Drive (Music Video)", channel: "LumenValeVEVO"),
        ]), as: UTF8.self)
        let page = "<html><head><script>var ytInitialData = \(json);</script></head><body></body></html>"
        let videos = try YouTubeSearchDecoder.videos(fromHTML: Data(page.utf8))
        #expect(videos.map(\.id) == ["ahenkVid007"])
        #expect(throws: YouTubeSearchDecoder.Failure.malformed) { try YouTubeSearchDecoder.videos(fromHTML: Data("<html>consent</html>".utf8)) }
        #expect(throws: YouTubeSearchDecoder.Failure.malformed) { try YouTubeSearchDecoder.videos(fromJSON: Data("not json".utf8)) }
    }

    @Test("Clock labels and view counts")
    func numbers() {
        #expect(YouTubeSearchDecoder.seconds(fromClock: "4:51") == 291)
        #expect(YouTubeSearchDecoder.seconds(fromClock: "1:02:45") == 3_765)
        #expect(YouTubeSearchDecoder.seconds(fromClock: "LIVE") == nil)
        #expect(YouTubeSearchDecoder.seconds(fromClock: "12") == nil)
        #expect(YouTubeSearchDecoder.count(from: "169,258,652 views") == 169_258_652)
        #expect(YouTubeSearchDecoder.count(from: "No views") == nil)
    }

    @Test("The search asks the web client for videos only, caches the answer and backs off when told to slow down")
    func searchClient() async throws {
        let fetcher = TableFetcher(["youtubei/v1/search": (String(decoding: SearchFixtures.response([
            SearchFixtures.renderer("ahenkVid001", "Nova Atlas - Glass Harbor (Official Video)", channel: "Nova Atlas"),
        ]), as: UTF8.self), 200)])
        let search = YouTubeVideoSearch(fetcher: fetcher, region: { "tr" })
        #expect(try await search.search("Nova Atlas Glass Harbor").map(\.id) == ["ahenkVid001"])
        #expect(try await search.search("nova atlas  glass harbor").map(\.id) == ["ahenkVid001"], "the same words hit the cache")
        #expect(fetcher.posts.count == 1)
        let body = try #require(try JSONSerialization.jsonObject(with: fetcher.posts[0]) as? [String: Any])
        #expect(body["params"] as? String == YouTubeVideoSearch.videosOnly && body["query"] as? String == "Nova Atlas Glass Harbor")
        let client = try #require((body["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(client["clientName"] as? String == "WEB" && client["gl"] as? String == "TR")

        let busy = TableFetcher(["youtubei/v1/search": ("{}", 429)])
        let slowed = YouTubeVideoSearch(fetcher: busy, region: { "us" })
        await #expect(throws: CatalogError.rateLimited) { try await slowed.search("Lumen Vale") }
        await #expect(throws: CatalogError.rateLimited) { try await slowed.search("Another query") }
        #expect(busy.posts.count == 1, "nothing goes out while backing off")
    }

    @Test("A broken endpoint answer falls back to the results page")
    func fallback() async throws {
        let json = String(decoding: SearchFixtures.response([
            SearchFixtures.renderer("ahenkVid008", "Orchid Telemetry - Saffron Static (Official Video)", channel: "Orchid Telemetry"),
        ]), as: UTF8.self)
        let fetcher = TableFetcher([
            "youtubei/v1/search": ("<html>not json</html>", 200),
            "youtube.com/results": ("<script>var ytInitialData = \(json);</script>", 200),
        ])
        let search = YouTubeVideoSearch(fetcher: fetcher, region: { "us" })
        #expect(try await search.search("Orchid Telemetry Saffron Static").map(\.id) == ["ahenkVid008"])
    }

    @Test("oEmbed says whether a video may be embedded, and is cached")
    func embedInfo() async {
        let fetcher = TableFetcher([
            "v%3DahenkVid001": (#"{"title":"Glass Harbor (Official Video)","author_name":"Nova Atlas"}"#, 200),
            "v%3DahenkVid002": ("Unauthorized", 401),
            "v%3DahenkVid003": ("Not Found", 404),
        ])
        let search = YouTubeVideoSearch(fetcher: fetcher, region: { "us" })
        #expect(await search.embedInfo(of: "ahenkVid001") == YouTubeEmbedInfo(status: .embeddable, title: "Glass Harbor (Official Video)", channel: "Nova Atlas"))
        #expect(await search.embedInfo(of: "ahenkVid002")?.status == .disabled)
        #expect(await search.embedInfo(of: "ahenkVid003")?.status == .missing)
        #expect(await search.embedInfo(of: "ahenkVid009") == nil, "no answer: unknown, not disabled")
        #expect(await search.embedInfo(of: "not an id") == nil)
        let asked = fetcher.requests.count
        _ = await search.embedInfo(of: "ahenkVid002")
        #expect(fetcher.requests.count == asked, "answers are cached")
    }
}

@Suite("Wallpaper: ranking video candidates")
struct VideoRankingTests {
    fileprivate typealias F = SearchFixtures

    @Test("The artist's official video of the song wins; art tracks, audio, lyrics and unrelated videos are left out")
    func songVideo() {
        let results = [
            F.video("ahenkVid010", "Mirela Stoica - Lanterns Under Ice (Official Audio)", channel: "Mirela Stoica", duration: 224, artistChannel: true, views: 90_000_000),
            F.video("ahenkVid011", "Lanterns Under Ice", channel: "Mirela Stoica", duration: 223, artistChannel: true),
            F.video("ahenkVid012", "Mirela Stoica - Lanterns Under Ice (Lyrics)", channel: "Lyric Corner", duration: 223, views: 50_000_000),
            F.video("ahenkVid013", "Lanterns Under Ice", channel: "Mirela Stoica - Topic", duration: 223),
            F.video("ahenkVid014", "Mirela Stoica - Lanterns Under Ice (Official Video)", channel: "Mirela Stoica", duration: 236, artistChannel: true),
            F.video("ahenkVid015", "Mirela Stoica - Lanterns Under Ice (Official Video)", channel: "Reupload Hub", duration: 230, views: 40_000_000),
            F.video("ahenkVid016", "Paper Comets - Neon Weather (Official Video)", channel: "Paper Comets", duration: 223, artistChannel: true),
            F.video("ahenkVid017", "Mirela Stoica - Lanterns Under Ice (Live at the Harbor)", channel: "Mirela Stoica", duration: 260, artistChannel: true),
            F.video("ahenkVid018", "Mirela Stoica - Lanterns Under Ice [Official Music Video]", channel: "Mirela Stoica", duration: 223, artTrack: true),
            F.video("ahenkVid019", "Lanterns Under Ice (Mirela Stoica) - slowed + reverb", channel: "Night Edits", duration: 290),
            F.video("ahenkVid020", "Mirela Stoica - Lanterns Under Ice (Official Video)", channel: "Live Now", duration: nil, live: true),
        ]
        let ranked = VideoRanking.songVideos(results, title: "Lanterns Under Ice", artist: "Mirela Stoica", duration: 223)
        #expect(ranked.map(\.video.id) == ["ahenkVid014", "ahenkVid015", "ahenkVid017"])
        #expect(ranked[0].score > ranked[1].score && ranked[1].score > ranked[2].score)
    }

    @Test("Featured artists, VEVO channels, decorations and Turkish letters still match")
    func names() {
        #expect(VideoRanking.artistNames("Kestrel & Vale feat. Orchid Telemetry") == ["kestrel and vale feat orchid telemetry", "kestrel", "vale", "orchid telemetry"])
        let results = [
            F.video("ahenkVid021", "KESTREL & VALE - PAPER COMETS (Official Music Video)", channel: "KestrelValeVEVO", duration: 200),
            F.video("ahenkVid022", "Işıklı Sokak - Rıhtımda Dans (Resmi Video)", channel: "Işıklı Sokak", duration: 195),
        ]
        let kestrel = VideoRanking.songVideos(results, title: "Paper Comets (feat. Orchid Telemetry) [2024 Remaster]", artist: "Kestrel & Vale", duration: 198)
        #expect(kestrel.map(\.video.id) == ["ahenkVid021"])
        let turkish = VideoRanking.songVideos(results, title: "RIHTIMDA DANS", artist: "ISIKLI SOKAK", duration: 195)
        #expect(turkish.map(\.video.id) == ["ahenkVid022"], "ı and I fold together; a Turkish marker counts")
        #expect(VideoRanking.channelMatch("KestrelValeVEVO", names: VideoRanking.artistNames("Kestrel Vale")).isVEVO)
        #expect(VideoRanking.channelMatch("Kestrel Vale - Topic", names: VideoRanking.artistNames("Kestrel Vale")).isTopic)
        #expect(VideoRanking.channelMatch("Kestrel Vale Official", names: VideoRanking.artistNames("Kestrel Vale")).isArtist)
        #expect(!VideoRanking.channelMatch("Kestrel Vale Fans", names: VideoRanking.artistNames("Kestrel Vale")).isArtist)
    }

    @Test("A length close to the song's ranks up; a much longer cut ranks down")
    func lengths() {
        #expect(VideoRanking.durationScore(video: 225, song: 223) == 2)
        #expect(VideoRanking.durationScore(video: 238, song: 223) == 1.2)
        #expect(VideoRanking.durationScore(video: 290, song: 223) == 0.4, "an intro or outro")
        #expect(VideoRanking.durationScore(video: 190, song: 223) == 0.3)
        #expect(VideoRanking.durationScore(video: 600, song: 223) == -3)
        #expect(VideoRanking.durationScore(video: nil, song: 223) == 0)
        let shortCut = [
            F.video("ahenkVid023", "Nova Atlas - Glass Harbor (Official Video)", channel: "Nova Atlas", duration: 40, artistChannel: true),
        ]
        #expect(VideoRanking.songVideos(shortCut, title: "Glass Harbor", artist: "Nova Atlas", duration: 92).isEmpty, "a teaser is not the video")
    }

    @Test("Other videos come from the artist, never the song itself, each title once, within sensible lengths")
    func artistVideos() {
        let results = [
            F.video("ahenkVid030", "Nova Atlas - Glass Harbor (Official Video)", channel: "Nova Atlas", artistChannel: true),
            F.video("ahenkVid031", "Nova Atlas - Low Tide (Official Video)", channel: "Nova Atlas", artistChannel: true, views: 5_000_000),
            F.video("ahenkVid032", "Nova Atlas - Neon Weather (Official Music Video)", channel: "NovaAtlasVEVO", views: 80_000_000),
            F.video("ahenkVid033", "Nova Atlas - Low Tide (Official Video)", channel: "Nova Atlas Fans", views: 10_000),
            F.video("ahenkVid034", "Signal Bloom", channel: "Nova Atlas", artistChannel: true),
            F.video("ahenkVid035", "Nova Atlas - Neon Weather (Official Audio)", channel: "Nova Atlas", artistChannel: true),
            F.video("ahenkVid036", "Nova Atlas - Full Concert (Official Video)", channel: "Nova Atlas", duration: 5_400, artistChannel: true),
            F.video("ahenkVid037", "Quiet Ferns - Paper Satellites (Official Video)", channel: "Quiet Ferns", artistChannel: true),
            F.video("ahenkVid038", "Nova Atlas - Moonwake (Official Video)", channel: "Nova Atlas", artistChannel: true),
        ]
        let ranked = VideoRanking.artistVideos(results, artist: "Nova Atlas", excluding: ["ahenkVid038"], songTitle: "Glass Harbor")
        #expect(ranked.map(\.video.id) == ["ahenkVid032", "ahenkVid031"])
        #expect(VideoRanking.artistVideos(results, artist: "Nova Atlas", limit: 1).count == 1)
        #expect(VideoRanking.artistVideos(results, artist: "").isEmpty)
    }
}

@Suite("Wallpaper: motion artwork")
struct MotionArtworkTests {
    static let album = """
    {"data":[{"id":"9900123","type":"albums","attributes":{"name":"Low Tide Lights","editorialVideo":{
      "motionDetailSquare":{"previewFrame":{"width":3840,"height":3840},"video":"https://motion.example/square/master.m3u8"},
      "motionDetailTall":{"previewFrame":{"width":2048,"height":2732},"video":"https://motion.example/tall/master.m3u8"},
      "motionSquareVideo1x1":{"video":"https://motion.example/other-square/master.m3u8"}}}}]}
    """
    static let plainAlbum = #"{"data":[{"id":"9900124","type":"albums","attributes":{"name":"Signal & Bloom"}}]}"#
    /// A token with an invented payload: {"iss":"Invented","exp":1893456000}.
    static let token = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJJbnZlbnRlZCIsImV4cCI6MTg5MzQ1NjAwMH0.c2lnbmF0dXJl"
    static let page = #"<html><head><script type="module" src="/assets/index~abc123.js"></script></head></html>"#
    static let script = "var a=1;const config={token:\"\(token)\"};"

    @Test("The album's editorial video gives the square and the tall cut; an album without one says so")
    func decoding() throws {
        let artwork = try #require(try MotionArtworkDecoder.artwork(albumID: "9900123", from: Data(Self.album.utf8)))
        #expect(artwork.square?.absoluteString == "https://motion.example/square/master.m3u8")
        #expect(artwork.tall?.absoluteString == "https://motion.example/tall/master.m3u8")
        #expect(artwork.url(forAspectRatio: 1512.0 / 982) == artwork.square, "a landscape screen takes the square cut")
        #expect(artwork.url(forAspectRatio: 1080.0 / 1920) == artwork.tall, "a portrait screen takes the tall cut")
        #expect(try MotionArtworkDecoder.artwork(albumID: "9900124", from: Data(Self.plainAlbum.utf8)) == nil)
        #expect(throws: MotionArtworkDecoder.Failure.malformed) { try MotionArtworkDecoder.artwork(albumID: "1", from: Data("<html>".utf8)) }
    }

    @Test("The web player's page names its script, the script holds the token, the token says when it expires")
    func token() {
        #expect(MotionArtworkDecoder.scriptPath(inPage: Self.page) == "/assets/index~abc123.js")
        #expect(MotionArtworkDecoder.token(inScript: Self.script) == Self.token)
        #expect(MotionArtworkDecoder.expiry(ofToken: Self.token) == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(MotionArtworkDecoder.expiry(ofToken: "not.a.token") == nil)
        #expect(MotionArtworkDecoder.token(inScript: "no token here") == nil)
    }

    @Test("Lookups read the token once, cache answers, and fetch a refused token again")
    func finder() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetcher = TableFetcher([
            "music.apple.com/us/new": (Self.page, 200),
            "assets/index~abc123.js": (Self.script, 200),
            "albums/9900123": (Self.album, 200),
            "albums/9900124": (Self.plainAlbum, 200),
            "albums/9900125": ("{}", 404),
        ])
        let finder = MotionArtworkFinder(fetcher: fetcher, storefront: { "TR" }, clock: clock.function)
        guard case .found(let artwork) = await finder.artwork(albumID: "9900123") else { Issue.record("no motion artwork"); return }
        #expect(artwork.albumID == "9900123")
        #expect(fetcher.requests.contains { $0.contains("/v1/catalog/tr/albums/9900123?extend=editorialVideo") }, "the store country, lower case")
        #expect(await finder.artwork(albumID: "9900124") == .none)
        #expect(await finder.artwork(albumID: "9900125") == .none, "not in this store")
        #expect(fetcher.requests.filter { $0.contains("index~abc123.js") }.count == 1, "one token for every lookup")
        let asked = fetcher.requests.count
        #expect(await finder.artwork(albumID: "9900123") == .found(artwork))
        #expect(await finder.artwork(albumID: "9900124") == .none)
        #expect(fetcher.requests.count == asked, "answers are cached")
        #expect(await finder.artwork(albumID: "not-a-number") == .none)

        // A refused token is read again once; offline is a failure, not "none".
        let refusing = TableFetcher([
            "music.apple.com/us/new": (Self.page, 200),
            "assets/index~abc123.js": (Self.script, 200),
            "albums/9900126": ("{}", 401),
        ])
        let refused = MotionArtworkFinder(fetcher: refusing, storefront: { "us" }, clock: clock.function)
        #expect(await refused.artwork(albumID: "9900126") == .failed)
        #expect(refusing.requests.filter { $0.contains("index~abc123.js") }.count == 2)
        let offline = MotionArtworkFinder(fetcher: TableFetcher(), storefront: { "us" }, clock: clock.function)
        #expect(await offline.artwork(albumID: "9900123") == .failed)
    }
}

@Suite("Wallpaper: following the song")
struct VideoSyncTests {
    @Test("Only the song's own video of about the same length follows the song")
    func modes() {
        #expect(VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: 223, videoDuration: 230) == .followsSong)
        #expect(VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: 300, videoDuration: 317) == .followsSong, "6 % of a long song")
        #expect(VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: 223, videoDuration: 290) == .loops, "another cut")
        #expect(VideoSync.mode(isSongVideo: true, syncEnabled: false, songDuration: 223, videoDuration: 223) == .loops)
        #expect(VideoSync.mode(isSongVideo: false, syncEnabled: true, songDuration: 223, videoDuration: 223) == .loops)
        #expect(VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: 0, videoDuration: 223) == .loops)
        #expect(VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: 223, videoDuration: nil) == .loops)
    }

    @Test("It starts a little ahead and is corrected only beyond the tolerance")
    func corrections() {
        #expect(VideoSync.startPosition(songPosition: 61, lead: 1.5, videoDuration: 230) == 62.5)
        #expect(VideoSync.startPosition(songPosition: 229.5, lead: 1.5, videoDuration: 230) == 229)
        #expect(VideoSync.correction(songPosition: 80, videoPosition: 79.5, videoDuration: 230) == nil)
        #expect(VideoSync.correction(songPosition: 80, videoPosition: 70, videoDuration: 230) == 80)
        #expect(VideoSync.correction(songPosition: 229.8, videoPosition: 200, videoDuration: 230) == nil, "past the video's end it holds")
        #expect(VideoSync.correction(songPosition: 80, videoPosition: .nan, videoDuration: 230) == nil)
    }
}

@Suite("Wallpaper: crossfades and visibility")
struct WallpaperStageTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("It waits for frames, fades in, crossfades to the next pick and melts back after a pause")
    func lifecycle() {
        var stage = WallpaperStage()
        var inputs = WallpaperStage.Inputs(music: .playing, wanted: "a", crossfade: 1.2)

        var plan = stage.update(inputs, now: t0)
        #expect(plan.isUp && plan.opacity == 0 && plan.front == nil && plan.keep == ["a"], "loading under a clear layer")
        #expect(plan.playback == .play)

        inputs.ready = ["a"]
        plan = stage.update(inputs, now: t0 + 1)
        #expect(plan.opacity == 1 && plan.front == "a" && plan.back == nil && plan.keep == ["a"])

        inputs.wanted = "b"
        plan = stage.update(inputs, now: t0 + 5)
        #expect(plan.front == "a" && plan.keep == ["a", "b"], "the next one loads under the one showing")
        inputs.ready = ["a", "b"]
        plan = stage.update(inputs, now: t0 + 6)
        #expect(plan.front == "b" && plan.back == "a" && plan.wakeAt == t0 + 7.2)
        plan = stage.update(inputs, now: t0 + 7.2)
        #expect(plan.front == "b" && plan.back == nil && plan.keep == ["b"], "the old one goes after the crossfade")

        inputs.music = .paused(since: t0 + 10)
        plan = stage.update(inputs, now: t0 + 10)
        #expect(plan.opacity == 1 && plan.playback == .pause && plan.wakeAt == t0 + 13, "a short pause keeps the frame")
        plan = stage.update(inputs, now: t0 + 13)
        #expect(plan.isUp && plan.opacity == 0 && plan.keep == ["b"] && plan.wakeAt == t0 + 14.2, "melting back")
        plan = stage.update(inputs, now: t0 + 14.2)
        #expect(!plan.isUp && plan.keep.isEmpty && plan.front == nil, "the user's wallpaper again, nothing kept")
    }

    @Test("Resuming during the melt brings the same picture back")
    func resumeWhileMelting() {
        var stage = WallpaperStage()
        var inputs = WallpaperStage.Inputs(music: .playing, wanted: "a", ready: ["a"])
        _ = stage.update(inputs, now: t0)
        inputs.music = .paused(since: t0 + 1)
        _ = stage.update(inputs, now: t0 + 4.5)
        inputs.music = .playing
        let plan = stage.update(inputs, now: t0 + 5)
        #expect(plan.opacity == 1 && plan.front == "a" && plan.playback == .play)
    }

    @Test("With 'keep while paused', a pause only pauses")
    func keepWhilePaused() {
        var stage = WallpaperStage()
        var inputs = WallpaperStage.Inputs(music: .playing, returnsOnPause: false, wanted: "a", ready: ["a"])
        _ = stage.update(inputs, now: t0)
        inputs.music = .paused(since: t0 + 1)
        let plan = stage.update(inputs, now: t0 + 60)
        #expect(plan.opacity == 1 && plan.front == "a" && plan.playback == .pause && plan.wakeAt == nil)
        inputs.music = .stopped(since: t0 + 61)
        #expect(stage.update(inputs, now: t0 + 64.5).opacity == 0, "nothing playing at all still melts back")
    }

    @Test("Hidden pauses at once, lets go after a while, and fades in again when seen")
    func hidden() {
        var stage = WallpaperStage()
        var inputs = WallpaperStage.Inputs(music: .playing, wanted: "a", ready: ["a"])
        _ = stage.update(inputs, now: t0)
        inputs.isVisible = false
        var plan = stage.update(inputs, now: t0 + 1)
        #expect(plan.playback == .pause && plan.opacity == 1 && plan.wakeAt == t0 + 21)
        inputs.wanted = "b"
        #expect(stage.update(inputs, now: t0 + 2).keep == ["a"], "nothing new loads while hidden")
        plan = stage.update(inputs, now: t0 + 21)
        #expect(!plan.isUp && plan.keep.isEmpty, "let go")
        inputs.isVisible = true
        inputs.ready = []
        plan = stage.update(inputs, now: t0 + 30)
        #expect(plan.isUp && plan.opacity == 0 && plan.keep == ["b"], "loads again under a clear layer")
        inputs.ready = ["b"]
        #expect(stage.update(inputs, now: t0 + 31).opacity == 1)
    }

    @Test("Turning it off melts back; nothing wanted keeps what shows")
    func switches() {
        var stage = WallpaperStage()
        var inputs = WallpaperStage.Inputs(music: .playing, wanted: "a", ready: ["a"])
        _ = stage.update(inputs, now: t0)
        inputs.wanted = nil
        #expect(stage.update(inputs, now: t0 + 1).front == "a", "a new song's lookup is still running")
        inputs.isEnabled = false
        let plan = stage.update(inputs, now: t0 + 2)
        #expect(plan.opacity == 0 && plan.isUp && plan.playback == .pause)
        #expect(!stage.update(inputs, now: t0 + 3.3).isUp)
    }
}

@Suite("Wallpaper: a desktop covered by windows")
struct WallpaperCoverageTests {
    let desktop = CGRect(x: 0, y: 25, width: 1512, height: 880)

    @Test("Windows covering the desktop hide the wallpaper; a gap or a small window does not")
    func coverage() {
        #expect(WallpaperCoverage.coveredShare(of: desktop, by: []) == 0)
        #expect(WallpaperCoverage.isHidden(desktop, by: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), "a maximized window")
        let halves = [CGRect(x: 0, y: 25, width: 760, height: 880), CGRect(x: 752, y: 25, width: 760, height: 880)]
        #expect(WallpaperCoverage.isHidden(desktop, by: halves), "two windows side by side")
        let gap = [CGRect(x: 0, y: 25, width: 700, height: 880), CGRect(x: 812, y: 25, width: 700, height: 880)]
        #expect(!WallpaperCoverage.isHidden(desktop, by: gap), "the desktop shows between them")
        #expect(abs(WallpaperCoverage.coveredShare(of: desktop, by: [CGRect(x: 0, y: 25, width: 756, height: 880)]) - 0.5) < 0.04)
        #expect(!WallpaperCoverage.isHidden(desktop, by: [CGRect(x: 2000, y: 0, width: 800, height: 600)]), "another display's window")
    }
}

@Suite("Wallpaper: choosing what shows")
struct WallpaperSelectionTests {
    let motion = WallpaperCandidate(id: "motion:1", kind: .motionArtwork, media: .stream(URL(string: "https://motion.example/a.m3u8")!))
    let song = WallpaperCandidate(id: "youtube:ahenkVid001", kind: .songVideo, media: .youtube(videoID: "ahenkVid001"))
    let other = WallpaperCandidate(id: "youtube:ahenkVid002", kind: .artistVideo, media: .youtube(videoID: "ahenkVid002"))
    let cover = WallpaperCandidate.artwork

    @Test("The dots follow the preferred source; the cover comes last")
    func order() {
        let all = [cover, other, song, motion, song]
        #expect(WallpaperSelection.ordered(all, preference: .motionArtwork).map(\.id) == [motion.id, song.id, other.id, cover.id])
        #expect(WallpaperSelection.ordered(all, preference: .musicVideo).map(\.id) == [song.id, other.id, motion.id, cover.id])
    }

    @Test("Pinned, then picked, then the best that has not failed; waiting for a better source until patience runs out")
    func choice() {
        let ordered = WallpaperSelection.ordered([motion, song, other, cover], preference: .motionArtwork)
        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork)?.id == motion.id)
        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork, pick: other.id)?.id == other.id)
        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork, pinned: cover.id, pick: other.id)?.id == cover.id)
        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork, pick: "gone")?.id == motion.id)
        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork, failed: [motion.id])?.id == song.id)

        let early = [cover]
        #expect(WallpaperSelection.choose(early, preference: .motionArtwork, pending: [.motionArtwork], waited: false) == nil)
        #expect(WallpaperSelection.choose(early, preference: .motionArtwork, pending: [.motionArtwork], waited: true)?.id == cover.id)
        #expect(WallpaperSelection.choose([song, cover], preference: .musicVideo, pending: [.motionArtwork], waited: false)?.id == song.id,
                "a slower source that ranks lower is not waited for")

        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork, allowsVideo: false)?.id == cover.id, "Low Power Mode")
        #expect(WallpaperSelection.choose(ordered, preference: .motionArtwork, pick: song.id, allowsVideo: false)?.id == song.id,
                "the user's own pick still plays")
    }

    @Test("Power: lighter on battery and in Optimized Mode, the cover only in Low Power Mode or when hot")
    func power() {
        #expect(WallpaperPowerPolicy.plan(LightFrameInputs()).quality == .full)
        #expect(WallpaperPowerPolicy.plan(LightFrameInputs(isOnBattery: true)).quality == .reduced)
        #expect(WallpaperPowerPolicy.plan(LightFrameInputs(lighterOnBattery: false, isOnBattery: true)).quality == .full)
        #expect(WallpaperPowerPolicy.plan(LightFrameInputs(optimizedMode: true)).maximumVideoSide == 1280)
        let lowPower = WallpaperPowerPolicy.plan(LightFrameInputs(isLowPowerMode: true))
        #expect(lowPower.quality == .minimal && !lowPower.allowsVideo && lowPower.reason == .lowPowerMode)
        #expect(WallpaperPowerPolicy.plan(LightFrameInputs(isThermallyConstrained: true)).reason == .thermal)
    }
}

@Suite("Wallpaper: the song, its tab and art tracks")
struct WallpaperRequestTests {
    func snapshot(_ source: MusicSource, id: String, kind: SongVideoKind?, content: ContentKind = .music) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: Track(id: id, source: source, title: "Saffron Static (feat. Kestrel)", artist: "Orchid Telemetry", album: "Tidal Glass", duration: 214),
            elapsedTime: 0, playbackRate: 1, timestamp: Date(), contentKind: content, songVideoKind: kind
        )
    }

    @Test("A YouTube Music art track is not the song's video; an official one is")
    func artTracks() {
        let watch = "https://music.youtube.com/watch?v=ahenkMockV2"
        #expect(WallpaperRequest(snapshot: snapshot(.youtubeMusic, id: watch, kind: .artTrack)).tabVideo == nil)
        #expect(WallpaperRequest(snapshot: snapshot(.youtubeMusic, id: watch, kind: nil)).tabVideo == nil, "unknown on YouTube Music: probably a song")
        let official = WallpaperRequest(snapshot: snapshot(.youtubeMusic, id: watch, kind: .officialVideo))
        #expect(official.tabVideo?.media == .youtube(videoID: "ahenkMockV2") && official.tabVideo?.kind == .songVideo)
        #expect(official.tabVideo?.duration == 214)
        let youtube = "https://www.youtube.com/watch?v=ahenkMockV1"
        #expect(WallpaperRequest(snapshot: snapshot(.youtube, id: youtube, kind: nil)).tabVideo != nil, "a YouTube page is a video")
        #expect(WallpaperRequest(snapshot: snapshot(.youtube, id: youtube, kind: .artTrack)).tabVideo == nil)
        #expect(WallpaperRequest(snapshot: snapshot(.spotifyWeb, id: "spotify:track:x", kind: nil)).tabVideo == nil)
        #expect(WallpaperRequest(snapshot: snapshot(.youtubeMusic, id: watch, kind: .artTrack)).tabVideoID == "ahenkMockV2")
        #expect(SongVideoKind(youTubeType: "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK") == .artTrack)
        #expect(SongVideoKind(youTubeType: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE") == .other)
        #expect(SongVideoKind(youTubeType: "") == nil)
    }

    @Test("Searches use the typed artist name and a plain title; videos and podcasts are not followed")
    func searches() {
        let request = WallpaperRequest(snapshot: snapshot(.spotify, id: "spotify:track:x", kind: nil), artistOverride: "  Orchid T.  ")
        #expect(request.artist == "Orchid T." && request.reportedArtist == "Orchid Telemetry")
        #expect(request.songQuery == "Orchid T. Saffron Static official video")
        #expect(request.artistQuery == "Orchid T. official music video")
        #expect(request.songKey == WallpaperSongStore.songKey(title: "Saffron Static", artist: "Orchid Telemetry"))
        #expect(WallpaperRequest.follows(snapshot(.spotify, id: "x", kind: nil)))
        #expect(!WallpaperRequest.follows(snapshot(.youtube, id: "x", kind: nil, content: .video)))
        #expect(!WallpaperRequest.follows(snapshot(.spotify, id: "x", kind: nil, content: .podcast)))
    }
}

@Suite("Wallpaper: video IDs")
struct WallpaperVideoIDTests {
    @Test("Every form of a YouTube address gives the 11-character ID; anything else none")
    func parsing() {
        let forms = [
            "ahenkVid001",
            "https://www.youtube.com/watch?v=ahenkVid001",
            "https://www.youtube.com/watch?feature=share&v=ahenkVid001&t=42s",
            "https://m.youtube.com/watch?v=ahenkVid001",
            "https://music.youtube.com/watch?v=ahenkVid001&list=RDAMVM",
            "https://youtu.be/ahenkVid001?si=invented",
            "https://www.youtube.com/embed/ahenkVid001?start=10",
            "https://www.youtube-nocookie.com/embed/ahenkVid001",
            "https://www.youtube.com/live/ahenkVid001",
            "https://www.youtube.com/shorts/ahenkVid001",
            "  https://www.youtube.com/watch?v=ahenkVid001  ",
        ]
        for form in forms {
            #expect(BrowserSite.youtubeVideoID(form) == "ahenkVid001", "\(form)")
        }
        for bad in ["ahenkVid00", "ahenkVid0011", "ahenk Vid01", "ahenk/id001", "https://vimeo.com/ahenkVid001",
                    "https://www.youtube.com/channel/ahenkVid001", "https://www.youtube.com/watch?v=short", ""] {
            #expect(BrowserSite.youtubeVideoID(bad) == nil, "\(bad)")
        }
        // The tab's watch URL, as the hub carries it.
        let request = WallpaperRequest(snapshot: NowPlayingSnapshot(
            track: Track(id: "https://www.youtube.com/watch?v=ahenkVid001", source: .youtube, title: "Glass Harbor", artist: "Nova Atlas"),
            elapsedTime: 0, playbackRate: 1, timestamp: Date(), contentKind: .music
        ))
        #expect(request.tabVideoID == "ahenkVid001" && request.tabVideo?.id == "youtube:ahenkVid001")
    }
}

@Suite("Wallpaper: the user's videos")
struct WallpaperVideoListTests {
    @Test("Links, addresses and files become list entries; other text does not")
    func parsing() {
        let youtube = WallpaperVideoInput.savedVideo(from: " https://youtu.be/ahenkVid001?t=4 ")
        #expect(youtube?.kind == .youtube && youtube?.reference == "ahenkVid001")
        #expect(WallpaperVideoInput.savedVideo(from: "https://www.youtube-nocookie.com/embed/ahenkVid002")?.reference == "ahenkVid002")
        #expect(WallpaperVideoInput.savedVideo(from: "ahenkVid003", title: "Harbor loop")?.title == "Harbor loop")
        let stream = WallpaperVideoInput.savedVideo(from: "https://media.example/loops/harbor%20night.mp4")
        #expect(stream?.kind == .url && stream?.title == "harbor night" && stream?.reference == "https://media.example/loops/harbor%20night.mp4")
        let file = WallpaperVideoInput.savedVideo(from: "/Users/someone/Movies/Rain Window.mov")
        #expect(file?.kind == .file && file?.title == "Rain Window" && file?.reference == "/Users/someone/Movies/Rain Window.mov")
        #expect(WallpaperVideoInput.savedVideo(from: "file:///Users/someone/Movies/clip.m4v")?.reference == "/Users/someone/Movies/clip.m4v")
        #expect(WallpaperVideoInput.savedVideo(from: "/Users/someone/notes.txt") == nil)
        #expect(WallpaperVideoInput.savedVideo(from: "just some words") == nil)
        #expect(WallpaperVideoInput.savedVideo(from: "ftp://media.example/a.mp4") == nil)
    }

    @Test("Adding, choosing, renaming and removing; the list survives a relaunch")
    func listPersists() throws {
        let scratch = ScratchDefaults()
        let settings = AppSettings(defaults: scratch.defaults)
        let first = try #require(WallpaperVideoInput.savedVideo(from: "https://youtu.be/ahenkVid001"))
        let second = try #require(WallpaperVideoInput.savedVideo(from: "/Users/someone/Movies/Rain Window.mov"))
        settings.wallpaper.addVideo(first)
        settings.wallpaper.addVideo(second)
        #expect(settings.wallpaper.addVideo(SavedVideo(title: "Again", kind: .youtube, reference: "ahenkVid001")).id == first.id, "no duplicates")
        settings.wallpaper.selectVideo(id: second.id)
        settings.wallpaper.selectVideo(id: "unknown")
        settings.wallpaper.renameVideo(id: first.id, to: "  Harbor at dusk ")

        let reloaded = AppSettings(defaults: scratch.defaults)
        #expect(reloaded.wallpaper.savedVideos.map(\.title) == ["Harbor at dusk", "Rain Window"])
        #expect(reloaded.wallpaper.selectedVideo?.id == second.id)
        #expect(reloaded.wallpaper.savedVideos.map(\.kind) == [.youtube, .file])

        reloaded.wallpaper.removeVideo(id: second.id)
        #expect(reloaded.wallpaper.selectedVideoID == nil, "a removed video stops showing")
        #expect(AppSettings(defaults: scratch.defaults).wallpaper.savedVideos.map(\.id) == [first.id])
        #expect(WallpaperCandidate.user(first)?.media == .youtube(videoID: "ahenkVid001"))
        #expect(WallpaperCandidate.user(SavedVideo(title: "x", kind: .url, reference: "https://media.example/a.mp4"))?.playsWithAVPlayer == true)
        #expect(WallpaperCandidate.user(SavedVideo(title: "x", kind: .file, reference: "relative/path.mov")) == nil)
    }

    @Test("The list keeps its newest videos")
    func capacity() {
        var settings = WallpaperSettings()
        for index in 0..<(WallpaperSettings.maximumSavedVideos + 3) {
            settings.addVideo(SavedVideo(id: "v\(index)", title: "Clip \(index)", kind: .url, reference: "https://media.example/\(index).mp4"))
        }
        #expect(settings.savedVideos.count == WallpaperSettings.maximumSavedVideos)
        #expect(settings.savedVideos.first?.id == "v3")
    }

    @Test("Dot picks and typed artist names are kept per song and per artist")
    func songStore() throws {
        let scratch = ScratchDirectory()
        let url = scratch.url.appendingPathComponent(WallpaperSongStore.fileName)
        let store = WallpaperSongStore(fileURL: url)
        let key = WallpaperSongStore.songKey(title: "Glass Harbor (Radio Edit)", artist: "Nova Atlas")
        #expect(key == WallpaperSongStore.songKey(title: "glass harbor", artist: "NOVA ATLAS"))
        store.setPick("youtube:ahenkVid002", forSong: key)
        store.setArtistName("Nova Atlas Band", for: "N. Atlas")
        store.setArtistName("  ", for: "Somebody")
        store.flush()
        let reloaded = WallpaperSongStore(fileURL: url)
        #expect(reloaded.pick(forSong: key) == "youtube:ahenkVid002")
        #expect(reloaded.artistName(for: "n. atlas") == "Nova Atlas Band")
        #expect(reloaded.artistName(for: "Somebody") == nil)
        reloaded.setPick(nil, forSong: key)
        reloaded.flush()
        #expect(WallpaperSongStore(fileURL: url).pick(forSong: key) == nil)

        let small = WallpaperSongStore(fileURL: nil, capacity: 2)
        for (index, song) in ["a", "b", "c"].enumerated() {
            small.setPick("artwork", forSong: song, at: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        #expect(small.pick(forSong: "a") == nil && small.pick(forSong: "c") == "artwork")

        try Data("{\"picks\":{\"x\":{\"value\":5}},\"artists\":7}".utf8).write(to: url)
        #expect(WallpaperSongStore(fileURL: url).pick(forSong: "x") == nil, "unreadable entries are dropped")
    }
}

@Suite("Wallpaper: the embedded player's page")
struct YouTubeEmbedTests {
    @Test("Privacy-enhanced, muted, no controls, the app's origin, the start and the loop")
    func page() throws {
        let origin = YouTubeEmbed.origin(bundleIdentifier: "com.sinanmertsener.Ahenk")
        #expect(origin.absoluteString == "https://com.sinanmertsener.ahenk")
        let html = try #require(YouTubeEmbed.page(videoID: "ahenkVid001", start: 61.8, loops: false, origin: origin))
        for fragment in [
            "host: 'https://www.youtube-nocookie.com'", "videoId: 'ahenkVid001'", "mute: 1", "controls: 0", "disablekb: 1", "fs: 0",
            "start: 61", "origin: 'https://com.sinanmertsener.ahenk'", "var loops = false", "https://www.youtube.com/iframe_api",
            "messageHandlers.\(YouTubeEmbed.messageHandler)", "strict-origin-when-cross-origin",
        ] {
            #expect(html.contains(fragment), "missing \(fragment)")
        }
        #expect(YouTubeEmbed.page(videoID: "ahenkVid001", start: 0, loops: true, origin: origin)?.contains("var loops = true") == true)
        #expect(YouTubeEmbed.page(videoID: "x');alert(1);//", start: 0, loops: true, origin: origin) == nil, "only real video IDs")
        #expect(YouTubeEmbed.page(videoID: "ahenkVid001", start: 0, loops: true, origin: URL(string: "https://a.b/'x")!) == nil)
    }

    @Test("The page's messages and the player's error codes")
    func events() {
        #expect(YouTubeEmbed.event(from: ["type": "ready", "duration": 214.5]) == .ready(duration: 214.5))
        #expect(YouTubeEmbed.event(from: ["type": "state", "state": 1, "time": 12.5, "duration": 214, "muted": true])
                == .state(.playing, time: 12.5, duration: 214, muted: true))
        #expect(YouTubeEmbed.event(from: ["type": "error", "code": 150]) == .error(.embeddingDisabled))
        #expect(YouTubeEmbed.event(from: ["type": "state", "state": 9]) == nil)
        #expect(YouTubeEmbed.event(from: "nonsense") == nil)
        #expect(YouTubeEmbed.Failure(code: 101) == .embeddingDisabled && YouTubeEmbed.Failure(code: 100) == .unavailable)
        #expect(YouTubeEmbed.Failure(code: 153) == .playerConfiguration && !YouTubeEmbed.Failure(code: 153).isAboutThisVideo)
        #expect(YouTubeEmbed.Failure(code: -1) == .offline && YouTubeEmbed.Failure(code: 5).isAboutThisVideo)
    }
}

@Suite("Wallpaper: demo")
struct WallpaperDemoTests {
    @Test("Every demo song offers its own generated video, two more looks and the cover")
    func candidates() {
        for song in DemoCatalog.songs {
            let candidates = WallpaperDemo.candidates(for: song)
            #expect(candidates.map(\.kind) == [.songVideo, .artistVideo, .artistVideo, .artwork])
            #expect(candidates[0].duration == song.track.duration, "as long as the song, so it follows it")
            #expect(Set(candidates.map(\.id)).count == 4)
            #expect(VideoSync.mode(isSongVideo: true, syncEnabled: true, songDuration: song.track.duration, videoDuration: candidates[0].duration) == .followsSong)
        }
        let ids = DemoCatalog.songs.flatMap { WallpaperDemo.candidates(for: $0).filter { $0.kind != .artwork }.map(\.id) }
        #expect(Set(ids).count == ids.count, "every song's pictures are its own, so a new song crossfades")
        let colors = WallpaperDemo.colors(look: 1, palette: DemoCatalog.songs[0].palette)
        #expect(colors.count == DemoCatalog.songs[0].palette.colors.count + 1)
        #expect(colors.first == DemoCatalog.songs[0].palette.colors[1])
    }
}
