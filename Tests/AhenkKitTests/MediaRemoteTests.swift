import Foundation
import Testing
@testable import AhenkKit

// Fixtures are invented: titles, artists and "artwork" bytes are made up.

@Suite("MediaRemote adapter payloads")
struct AdapterPayloadTests {
    @Test("Reads the adapter's fields leniently")
    func lenientFields() {
        let fields: [String: Any] = [
            "processIdentifier": 4242,
            "bundleIdentifier": "com.spotify.client",
            "title": "Paper Satellites",
            "artist": "The Quiet Ferns",
            "album": "Signal & Bloom",
            "durationMicros": 84_500_000,
            "elapsedTimeMicros": "12500000",
            "timestampEpochMicros": 1_782_323_000_123_456.0,
            "playing": true,
            "uniqueIdentifier": 98765,
            "shuffleMode": 3,
            "repeatMode": "2",
            "supportsIsLiked": 1,
            "isLiked": false,
        ]
        let payload = AdapterPayload(fields: fields, artworkData: Data([1, 2, 3]))
        #expect(payload.processIdentifier == 4242)
        #expect(payload.title == "Paper Satellites")
        #expect(abs((payload.duration ?? 0) - 84.5) < 1e-9)
        #expect(abs((payload.elapsedTime ?? 0) - 12.5) < 1e-9, "a number sent as text")
        #expect(abs((payload.timestamp ?? 0) - 1_782_323_000.123456) < 1e-6)
        #expect(payload.trackIdentifier == "98765", "a numeric identifier becomes text instead of failing")
        #expect(payload.shuffleMode == 3 && payload.repeatMode == 2)
        #expect(payload.supportsIsLiked == true && payload.isLiked == false)
        #expect(payload.isPlaying)
    }

    @Test("Timestamps in seconds, milliseconds, microseconds or ISO 8601")
    func timestamps() {
        #expect(AdapterPayload(fields: ["title": "x", "timestamp": 1_782_323_000], artworkData: nil).timestamp == 1_782_323_000)
        #expect(AdapterPayload(fields: ["title": "x", "timestamp": 1_782_323_000_000.0], artworkData: nil).timestamp == 1_782_323_000)
        #expect(abs((AdapterPayload(fields: ["title": "x", "timestamp": 1_782_323_000_000_000.0], artworkData: nil).timestamp ?? 0) - 1_782_323_000) < 1e-3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 20))!.timeIntervalSince1970 + 0.25
        let iso = AdapterPayload(fields: ["title": "x", "timestamp": "2026-11-08T20:00:00.250Z"], artworkData: nil).timestamp
        #expect(iso.map { abs($0 - expected) < 1e-3 } == true)
        let whole = AdapterPayload(fields: ["title": "x", "timestamp": "2026-11-08T20:00:00Z"], artworkData: nil).timestamp
        #expect(whole.map { abs($0 - (expected - 0.25)) < 1e-3 } == true)
    }

    @Test("Play state: the playing flag wins over the rate")
    func playState() {
        #expect(!AdapterPayload(fields: ["title": "x", "playing": false, "playbackRate": 1], artworkData: nil).isPlaying)
        #expect(AdapterPayload(fields: ["title": "x", "playbackRate": 1], artworkData: nil).isPlaying)
        #expect(!AdapterPayload(fields: ["title": "x"], artworkData: nil).isPlaying)
    }

    @Test("Base64 and data URL artwork")
    func artwork() {
        #expect(AdapterPayload.decodeArtwork("AQID") == Data([1, 2, 3]))
        #expect(AdapterPayload.decodeArtwork("data:image/png;base64,AQID") == Data([1, 2, 3]))
        #expect(AdapterPayload.decodeArtwork("") == nil)
        #expect(AdapterPayload.decodeArtwork(nil) == nil)
    }

    @Test("A music app maps to its own source with full metadata")
    func musicApp() throws {
        let payload = AdapterPayload(
            processIdentifier: 77, bundleIdentifier: "com.apple.Music", title: "Glass Harbor", artist: "Nova Atlas",
            album: "Low Tide Lights", duration: 92, elapsedTime: 30, playbackRate: 1, timestamp: 1000, playing: true,
            artworkData: Data([9, 9]), trackIdentifier: "abc", supportsIsLiked: true, shuffleMode: 1, repeatMode: 3
        )
        let snapshot = try #require(payload.snapshot(resolver: .standard, artworkAspectRatio: 1, now: Date()))
        #expect(snapshot.track.source == .appleMusic)
        #expect(snapshot.track.id == "mr:abc")
        #expect(snapshot.bundleIdentifier == "com.apple.Music")
        #expect(snapshot.processIdentifier == 77)
        #expect(snapshot.contentKind == .music)
        #expect(snapshot.timestamp == Date(timeIntervalSince1970: 1000))
        #expect(snapshot.isShuffled == false)
        #expect(snapshot.repeatMode == .all)
        #expect(snapshot.capabilities.contains([.playPause, .skip, .seek, .shuffle, .repeatAll, .like]))
        #expect(!snapshot.capabilities.contains(.unlike), "MediaRemote has no unlike")
        #expect(snapshot.artworkData == Data([9, 9]))
        #expect(snapshot.artworkIdentifier == ArtworkDigest.hex(of: Data([9, 9])))
    }

    @Test("WebKit helpers report for their browser")
    func webKitParent() throws {
        let payload = AdapterPayload(
            bundleIdentifier: "com.apple.WebKit.GPU", parentBundleIdentifier: "com.apple.Safari",
            title: "Copper Moon Drive - YouTube Music", artist: "Lumen Vale", playing: true
        )
        let snapshot = try #require(payload.snapshot(resolver: .standard, artworkAspectRatio: nil, now: Date()))
        #expect(snapshot.bundleIdentifier == "com.apple.Safari")
        #expect(snapshot.track.source == .youtubeMusic)
        #expect(snapshot.track.title == "Copper Moon Drive", "the site suffix is removed")
        #expect(snapshot.contentKind == .music)
    }

    @Test("The Search browser is a browser; unknown sites stay generic")
    func searchBrowser() throws {
        let payload = AdapterPayload(bundleIdentifier: KnownApps.search, title: "Paper Satellites", artist: "The Quiet Ferns", album: "Signal & Bloom", playing: true)
        let snapshot = try #require(payload.snapshot(resolver: .standard, artworkAspectRatio: 1, now: Date()))
        #expect(snapshot.track.source == .otherApp, "no hint names the site")
        #expect(snapshot.bundleIdentifier == "com.officecommun.search")
        #expect(snapshot.contentKind == .music, "artist and album look like a song")
        #expect(snapshot.track.id.hasPrefix("meta:"))
    }

    @Test("Wide thumbnails in a browser are video; adverts are adverts")
    func contentKinds() throws {
        let video = AdapterPayload(bundleIdentifier: "com.google.Chrome", title: "How to fold a paper boat", artist: "Craft Corner", playing: true)
        #expect(video.snapshot(resolver: .standard, artworkAspectRatio: 16.0 / 9, now: Date())?.contentKind == .video)
        let ad = AdapterPayload(bundleIdentifier: "com.spotify.client", title: "A word from a sponsor", artist: "Spotify", playing: true, isAdvertisement: true)
        #expect(ad.snapshot(resolver: .standard, artworkAspectRatio: nil, now: Date())?.contentKind == .advertisement)
        let tv = AdapterPayload(bundleIdentifier: "org.videolan.vlc", title: "holiday.mov", playing: true)
        #expect(tv.snapshot(resolver: .standard, artworkAspectRatio: nil, now: Date())?.contentKind == .video)
        let podcast = AdapterPayload(bundleIdentifier: "com.example.player", title: "Episode 12", artist: "Two Hosts", playing: true, mediaType: "MRMediaRemoteMediaTypePodcast")
        #expect(podcast.snapshot(resolver: .standard, artworkAspectRatio: nil, now: Date())?.contentKind == .podcast)
    }

    @Test("Nothing playing maps to no snapshot")
    func empty() {
        #expect(AdapterPayload().snapshot(resolver: .standard, artworkAspectRatio: nil, now: Date()) == nil)
        #expect(AdapterPayload(fields: [:], artworkData: nil).isEmpty)
    }

    @Test("Commands map onto adapter arguments")
    func requests() {
        #expect(MediaRemoteRequest(.play)?.arguments == ["send", "0"])
        #expect(MediaRemoteRequest(.pause)?.arguments == ["send", "1"])
        #expect(MediaRemoteRequest(.togglePlayPause)?.arguments == ["send", "2"])
        #expect(MediaRemoteRequest(.next)?.arguments == ["send", "4"])
        #expect(MediaRemoteRequest(.previous)?.arguments == ["send", "5"])
        #expect(MediaRemoteRequest(.seek(to: 12.25))?.arguments == ["seek", "12250000"])
        #expect(MediaRemoteRequest(.seek(to: -3))?.arguments == ["seek", "0"])
        #expect(MediaRemoteRequest(.seek(to: .nan)) == nil)
        #expect(MediaRemoteRequest(.setShuffle(true))?.arguments == ["shuffle", "3"])
        #expect(MediaRemoteRequest(.setShuffle(false))?.arguments == ["shuffle", "1"])
        #expect(MediaRemoteRequest(.setRepeat(.one))?.arguments == ["repeat", "2"])
        #expect(MediaRemoteRequest(.setRepeat(.all))?.arguments == ["repeat", "3"])
        #expect(MediaRemoteRequest(.setRepeat(.off))?.arguments == ["repeat", "1"])
        #expect(MediaRemoteRequest(.setLiked(true))?.arguments == ["send", "106"])
        #expect(MediaRemoteRequest(.setLiked(false)) == nil)
    }
}

@Suite("MediaRemote stream decoding")
struct StreamDecoderTests {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test("Diffs merge onto the state; null removes a key")
    func diffs() {
        let decoder = NowPlayingStreamDecoder(now: { 2000 })
        let first = decoder.decode(line: line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Glass Harbor","artist":"Nova Atlas","playing":true,"elapsedTime":10,"timestamp":1000}}"#))
        #expect(first?.title == "Glass Harbor")
        let second = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"elapsedTime":40,"timestamp":1030}}"#))
        #expect(second?.elapsedTime == 40 && second?.title == "Glass Harbor" && second?.timestamp == 1030)
        let third = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"artist":null}}"#))
        #expect(third?.artist == nil && third?.title == "Glass Harbor")
        let replaced = decoder.decode(line: line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","title":"Other"}}"#))
        #expect(replaced?.artist == nil && replaced?.bundleIdentifier == "com.spotify.client" && replaced?.elapsedTime == nil)
    }

    @Test("A seek or resume without a fresh timestamp is anchored to now")
    func reanchoring() {
        let decoder = NowPlayingStreamDecoder(now: { 5000.5 })
        _ = decoder.decode(line: line(#"{"type":"data","diff":false,"payload":{"title":"A","elapsedTimeMicros":10000000,"timestampEpochMicros":1000000000,"playbackRate":0}}"#))
        let seek = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":60000000}}"#))
        #expect(seek?.elapsedTime == 60)
        #expect(seek?.timestamp == 5000.5)
        let resume = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"playbackRate":1}}"#))
        #expect(resume?.timestamp == 5000.5)
        let fresh = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":1000000,"timestampEpochMicros":4000000000}}"#))
        #expect(fresh?.timestamp == 4000, "an explicit timestamp is kept")
    }

    @Test("Artwork is decoded when its key changes and kept across diffs")
    func artworkCaching() {
        let decoder = NowPlayingStreamDecoder()
        let first = decoder.decode(line: line(#"{"type":"data","diff":false,"payload":{"title":"A","artworkData":"AQID"}}"#))
        #expect(first?.artworkData == Data([1, 2, 3]))
        let diff = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"elapsedTime":3}}"#))
        #expect(diff?.artworkData == Data([1, 2, 3]))
        let removed = decoder.decode(line: line(#"{"type":"data","diff":true,"payload":{"artworkData":null}}"#))
        #expect(removed?.artworkData == nil)
        let new = decoder.decode(line: line(#"{"type":"data","diff":false,"payload":{"title":"B"}}"#))
        #expect(new?.artworkData == nil, "a full replace without artwork clears it")
    }

    @Test("Other lines are ignored; an empty payload means nothing plays")
    func otherLines() {
        let decoder = NowPlayingStreamDecoder()
        #expect(decoder.decode(line: line(#"{"type":"hello"}"#)) == nil)
        #expect(decoder.decode(line: line("not json")) == nil)
        #expect(decoder.decode(line: line(#"{"type":"data","diff":false,"payload":{}}"#))?.isEmpty == true)
    }

    @Test("Lines split across chunks")
    func lineSplitting() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = splitter.append(Data("1}\n\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
        #expect(splitter.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"c\":3}"])
    }
}

@Suite("Sources and sites")
struct SourceResolutionTests {
    @Test("Bundle identifiers map to kinds")
    func kinds() {
        let resolver = SourceResolver.standard
        #expect(resolver.kind(of: "com.apple.Music") == .musicApp(.appleMusic))
        #expect(resolver.kind(of: "com.spotify.client") == .musicApp(.spotify))
        #expect(resolver.kind(of: "com.tidal.desktop") == .musicApp(.tidal))
        #expect(resolver.kind(of: "com.officecommun.search") == .browser)
        #expect(resolver.kind(of: "com.google.Chrome") == .browser)
        #expect(resolver.kind(of: "company.thebrowser.Browser") == .browser)
        #expect(resolver.kind(of: "com.google.Chrome.app.abcdefghijklmnop") == .browser, "installed web apps")
        #expect(resolver.kind(of: "com.apple.Safari.WebApp.1234") == .browser)
        #expect(resolver.kind(of: "org.videolan.vlc") == .videoPlayer)
        #expect(resolver.kind(of: "com.apple.podcasts") == .spokenWordPlayer)
        #expect(resolver.kind(of: "com.example.unknown") == .other)
        #expect(resolver.kind(of: nil) == .other)
        let extended = SourceResolver(additionalBrowsers: ["com.example.browser"])
        #expect(extended.kind(of: "com.example.browser") == .browser)
    }

    @Test("Site suffixes and host names name the site")
    func siteMarkers() {
        func guess(_ title: String, _ artist: String = "Nova Atlas", _ album: String = "") -> WebPlaybackGuess {
            WebSiteInference.guess(title: title, artist: artist, album: album, artworkAspectRatio: nil)
        }
        #expect(guess("Glass Harbor - YouTube Music").source == .youtubeMusic)
        #expect(guess("Glass Harbor - YouTube").source == .youtube)
        #expect(guess("Glass Harbor | Spotify").source == .spotifyWeb)
        #expect(guess("Glass Harbor • Spotify").source == .spotifyWeb)
        #expect(guess("Stream Glass Harbor by Nova Atlas | Listen online for free on SoundCloud").source == .soundCloud)
        #expect(guess("Glass Harbor by Nova Atlas on TIDAL").source == .tidal)
        #expect(guess("Glass Harbor | Deezer").source == .deezer)
        #expect(guess("Glass Harbor - Amazon Music").source == .amazonMusic)
        #expect(guess("Glass Harbor", "music.youtube.com").source == .youtubeMusic)
        #expect(guess("Glass Harbor", "SoundCloud").source == .soundCloud, "the brand as the artist")
        #expect(guess("Glass Harbor", "SoundCloud").artist == "", "and it is not shown as the artist")
        #expect(guess("Spotify Dreams").source == .otherApp, "a brand inside the title is not a suffix")
        #expect(guess("Glass Harbor - YouTube Music").title == "Glass Harbor")
    }

    @Test("Plain YouTube is video unless it is clearly music")
    func youtubeKinds() {
        let video = WebSiteInference.guess(title: "Building a kite - YouTube", artist: "Craft Corner", album: "", artworkAspectRatio: 4.0 / 3)
        #expect(video.source == .youtube && video.contentKind == .video)
        let topic = WebSiteInference.guess(title: "Glass Harbor - YouTube", artist: "Nova Atlas - Topic", album: "", artworkAspectRatio: 16.0 / 9)
        #expect(topic.contentKind == .music)
        #expect(topic.artist == "Nova Atlas", "the Topic suffix goes")
        let official = WebSiteInference.guess(title: "Nova Atlas - Glass Harbor (Official Audio) - YouTube", artist: "NovaAtlasVEVO", album: "", artworkAspectRatio: 16.0 / 9)
        #expect(official.contentKind == .music)
        #expect(official.artist == "NovaAtlas")
    }

    @Test("Without a site, shape decides the kind")
    func unknownSites() {
        #expect(WebSiteInference.guess(title: "A", artist: "B", album: "C", artworkAspectRatio: 1).contentKind == .music)
        #expect(WebSiteInference.guess(title: "A", artist: "B", album: "", artworkAspectRatio: 1).contentKind == .unknown)
        #expect(WebSiteInference.guess(title: "A", artist: "B", album: "C", artworkAspectRatio: 1.78).contentKind == .video)
    }
}
