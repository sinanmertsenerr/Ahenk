import CryptoKit
import Foundation
import Testing
@testable import AhenkKit

// Invented songs, IDs and lines only.

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/bridge/\(name).json"))
}

private func json(_ text: String) -> Data { Data(text.utf8) }

@Suite("Bridge wire protocol")
struct BridgeProtocolTests {
    @Test("The extension's messages (shared fixtures) decode")
    func fixturesDecode() throws {
        guard case .hello(let hello) = try BridgeInbound.decode(fixture("hello")) else { Issue.record("not a hello"); return }
        #expect(hello.protocolVersion == 1 && hello.minimumProtocolVersion == 1)
        #expect(hello.browser.name == "Microsoft Edge" && hello.browser.brands == ["Microsoft Edge", "Chromium"])
        #expect(hello.profile == "0f3a9c1e5b7d2a4c6e8f0a1b" && hello.extensionVersion == "1.0.0")

        guard case .tabs(let tabs) = try BridgeInbound.decode(fixture("tabs")) else { Issue.record("not tabs"); return }
        #expect(tabs.count == 2)
        let spotify = tabs[0]
        #expect(spotify.tabID == 412 && spotify.site == "spotify" && spotify.state == .playing)
        #expect(spotify.title == "Lanterns Under Ice" && spotify.duration == 223.4 && spotify.position == 61.25)
        #expect(spotify.liked == true && spotify.shuffle == false && spotify.repeatMode == .all && spotify.volume == 0.8)
        #expect(spotify.capabilities.contains(.repeatOne) && spotify.capabilities.contains(.playlists) && spotify.capabilities.count == 12)
        #expect(spotify.trackID == "AhenkMockTrackSpotify1" && spotify.isActive == true)
        #expect(tabs[1].kind == .video && tabs[1].liked == nil && tabs[1].repeatMode == nil)

        guard case .tab(let tab) = try BridgeInbound.decode(fixture("tab")) else { Issue.record("not a tab"); return }
        #expect(tab.state == .paused && tab.position == 75.5 && tab.sampledAt == 1_762_700_014_000)
        #expect(try BridgeInbound.decode(fixture("tab-removed")) == .tabRemoved(tabID: 77))
        #expect(try BridgeInbound.decode(fixture("ping")) == .ping)

        guard case .result(let lists) = try BridgeInbound.decode(fixture("result-playlists")) else { Issue.record("not a result"); return }
        #expect(lists.id == "r7" && lists.ok && lists.tabID == 412)
        #expect(lists.playlists?.map(\.name) == ["Night Shift Mix", "Kıyıdan Sesler"] && lists.playlists?.first?.songCount == 3)
        guard case .result(let queue) = try BridgeInbound.decode(fixture("result-queue")) else { Issue.record("not a result"); return }
        #expect(queue.queue?.count == 2 && queue.queue?.first?.isCurrent == true && queue.queue?.last?.song.trackID == "ahenkMock02")
        guard case .result(let play) = try BridgeInbound.decode(fixture("result-play")) else { Issue.record("not a result"); return }
        #expect(play.outcome == .started && play.ok)

        guard case .lyrics(let lyrics) = try BridgeInbound.decode(fixture("lyrics")) else { Issue.record("not lyrics"); return }
        #expect(lyrics.tabID == 412 && lyrics.site == "spotify" && lyrics.lines.count == 4)
        #expect(lyrics.lines[1].end == 12.5 && lyrics.lines[2].text.isEmpty && lyrics.song.trackID == "AhenkMockTrackSpotify1")
    }

    @Test("Every message survives encoding and decoding")
    func roundTrips() throws {
        let tab = BridgeTab(
            tabID: 3, site: "deezer", url: "https://www.deezer.com/track/123", title: "Saffron Static", artist: "Kestrel & Vale",
            album: "Paper Comets", artworkURL: "https://cdn.example/c.jpg", duration: 236, position: 10, sampledAt: 1_000,
            playbackRate: 1, state: .playing, liked: false, shuffle: true, repeatMode: .one, trackID: "123",
            trackURL: "https://www.deezer.com/track/123", kind: .music, capabilities: [.playPause, .seek], volume: 0.5, isActive: false, lastActive: 900
        )
        let inbound: [BridgeInbound] = [
            .hello(BridgeHello(extensionVersion: "1.0.0", extensionOrigin: "moz-extension://x", browser: BridgeBrowser(name: "Firefox", version: "140"), profile: "p")),
            .tabs([tab]), .tab(tab), .tabRemoved(tabID: 3), .ping, .pong,
            .result(BridgeResult(id: "r1", ok: false, outcome: .notFound, error: "none", songs: [BridgeSong(title: "a", artist: "b")])),
            .lyrics(BridgeSiteLyrics(tabID: 3, site: "deezer", song: BridgeSong(title: "a", artist: "b"), lines: [BridgeLyricLine(start: 1, text: "x", words: [BridgeLyricWord(start: 1, end: 1.4, text: "x")])])),
        ]
        for message in inbound {
            #expect(try BridgeInbound.decode(message.encoded()) == message)
        }
        let outbound: [BridgeOutbound] = [
            .welcome(BridgeWelcome(protocolVersion: 1, appVersion: "0.1.0")),
            .command(BridgeCommand(id: "c1", tabID: 3, playback: .seek(to: 42.5))),
            .request(BridgeRequest(id: "r2", kind: .playPlaylist, site: "spotify", tabID: 3, playlistID: "pl", playlistURL: "https://open.spotify.com/playlist/pl", index: 2)),
            .ping, .pong, .error(code: "incompatible", message: "update"),
        ]
        for message in outbound {
            #expect(try BridgeOutbound.decode(message.encoded()) == message)
        }
    }

    @Test("The app's frames use the names the extension reads")
    func outboundShape() throws {
        let command = try BridgeOutbound.command(BridgeCommand(id: "c9", tabID: 5, playback: .setRepeat(.one))).encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: command) as? [String: Any])
        #expect(object["type"] as? String == "command" && object["tabId"] as? Int == 5 && object["command"] as? String == "repeat")
        #expect(object["mode"] as? String == "one" && object["id"] as? String == "c9")
        let welcome = try #require(try JSONSerialization.jsonObject(with: BridgeOutbound.welcome(BridgeWelcome(protocolVersion: 1, appVersion: "2")).encoded()) as? [String: Any])
        #expect(welcome["type"] as? String == "welcome" && welcome["protocol"] as? Int == 1 && welcome["app"] as? String == "Ahenk" && welcome["heartbeat"] as? Double == 20)
        let request = try #require(try JSONSerialization.jsonObject(with: BridgeOutbound.request(BridgeRequest(id: "r", kind: .play, site: "tidal", song: BridgeSong(title: "t", artist: "a"))).encoded()) as? [String: Any])
        #expect(request["request"] as? String == "play" && (request["song"] as? [String: Any])?["title"] as? String == "t")
    }

    @Test("Every hub command has a wire form")
    func commandMapping() {
        let cases: [(PlaybackCommand, BridgeCommand.Name)] = [
            (.play, .play), (.pause, .pause), (.togglePlayPause, .toggle), (.next, .next), (.previous, .previous),
            (.seek(to: 3), .seek), (.setShuffle(true), .shuffle), (.setRepeat(.all), .repeat), (.setLiked(false), .like),
        ]
        for (playback, name) in cases {
            #expect(BridgeCommand(id: "x", tabID: 1, playback: playback).command == name)
        }
        #expect(BridgeCommand(id: "x", tabID: 1, playback: .seek(to: -.infinity)).position == 0)
        #expect(BridgeCommand(id: "x", tabID: 1, playback: .setLiked(false)).on == false)
    }

    @Test("Unknown types and fields are ignored; wrong values drop only themselves")
    func lenience() throws {
        #expect(try BridgeInbound.decode(json(#"{"type":"teleport","x":1}"#)) == .unknown("teleport"))
        let tab = try BridgeInbound.decode(json(#"""
        {"type":"tab","future":true,"tab":{"tabId":9,"site":"youtube","title":"T","artist":"A","duration":"long",
         "position":-4,"state":"dancing","can":["playPause","teleport"],"repeat":"sometimes","volume":7,"sampledAt":5,"kind":"hologram"}}
        """#))
        guard case .tab(let decoded) = tab else { Issue.record("not a tab"); return }
        #expect(decoded.duration == nil && decoded.position == 0 && decoded.state == .paused)
        #expect(decoded.capabilities == [.playPause] && decoded.repeatMode == nil && decoded.volume == 1 && decoded.kind == .unknown)
        #expect(throws: (any Error).self) { try BridgeInbound.decode(json(#"{"type":"tab","tab":{"site":"x"}}"#)) }
        #expect(throws: (any Error).self) { try BridgeInbound.decode(json(#"[1,2]"#)) }
        #expect(throws: (any Error).self) { try BridgeInbound.decode(json(#"{"kind":"hello"}"#)) }
        let huge = Data(repeating: 0x20, count: BridgeProtocol.maximumMessageSize + 1)
        #expect(throws: BridgeProtocolError.tooLarge) { try BridgeInbound.decode(huge) }
        // A tab list keeps its readable tabs.
        guard case .tabs(let tabs) = try BridgeInbound.decode(json(#"{"type":"tabs","tabs":[{"tabId":1,"title":"a"},{"nope":1},{"tabId":2}]}"#)) else {
            Issue.record("not tabs")
            return
        }
        #expect(tabs.map(\.tabID) == [1, 2])
    }

    @Test("Versions: the newest both speak, or none")
    func versionNegotiation() {
        #expect(BridgeProtocol.negotiate(theirs: 1, theirMinimum: 1) == 1)
        #expect(BridgeProtocol.negotiate(theirs: 3, theirMinimum: 1) == 1, "a newer extension that still speaks 1")
        #expect(BridgeProtocol.negotiate(theirs: 3, theirMinimum: 2) == nil, "a newer extension that dropped 1")
        #expect(BridgeProtocol.negotiate(theirs: 0, theirMinimum: nil) == nil, "an older extension than Ahenk speaks")
        #expect(BridgeProtocol.negotiate(theirs: 4, theirMinimum: 2, ours: 5, ourMinimum: 3) == 4)
        #expect(BridgeProtocol.negotiate(theirs: 2, theirMinimum: 1, ours: 5, ourMinimum: 3) == nil)
    }

    @Test("The port range both sides try")
    func ports() {
        #expect(BridgeProtocol.ports(base: 42_617) == [42_617, 42_618, 42_619, 42_620])
        #expect(BridgeProtocol.ports(base: 65_534) == [65_534, 65_535])
        #expect(BridgeProtocol.ports(base: 5000, count: 1) == [5000])
    }
}

@Suite("Bridge origins")
struct BridgeOriginPolicyTests {
    let policy = BridgeOriginPolicy.standard
    let id = BridgeOriginPolicy.extensionID

    @Test("Only the extension's origins on the loopback host are accepted")
    func origins() {
        let host = "127.0.0.1:42617"
        #expect(policy.evaluate(origin: "chrome-extension://\(id)", host: host) == .accept(.chromium(extensionID: id)))
        #expect(policy.evaluate(origin: "chrome-extension://\(id)/", host: "localhost:42617").isAccepted)
        #expect(policy.evaluate(origin: "extension://\(id)", host: host).isAccepted, "Edge's form")
        let uuid = "8f5c2a6e-3b1d-4c7a-9e0f-1a2b3c4d5e6f"
        #expect(policy.evaluate(origin: "moz-extension://\(uuid)", host: "[::1]:42617") == .accept(.firefox(uuid: uuid)))
        #expect(policy.evaluate(origin: "webkit-extension://\(uuid.uppercased())", host: host) == .accept(.webKit(uuid: uuid)))
        #expect(policy.evaluate(origin: "chrome-extension://local-1a2b3c4d", host: host) == .accept(.unpacked(id: "local-1a2b3c4d")),
                "the Search browser's unpacked form")

        let refused = [
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop", // another extension
            "chrome-extension://\(id.uppercased())",
            "chrome-extension://short",
            "chrome-extension://local-1a2b3c4", // seven digits
            "chrome-extension://local-1A2B3C4D",
            "chrome-extension://local-1a2b3c4dz",
            "moz-extension://not-a-uuid",
            "webkit-extension://local-1a2b3c4d",
            "https://music.youtube.com",
            "https://local-1a2b3c4d",
            "http://localhost:42617",
            "http://127.0.0.1",
            "null",
            "file://",
            "",
        ]
        for origin in refused {
            #expect(!policy.evaluate(origin: origin, host: host).isAccepted, "\(origin) must be refused")
        }
        #expect(!policy.evaluate(origin: nil, host: host).isAccepted)
        let strict = BridgeOriginPolicy(acceptsRandomIDs: false)
        for origin in ["moz-extension://\(uuid)", "webkit-extension://\(uuid)", "chrome-extension://local-1a2b3c4d"] {
            #expect(!strict.evaluate(origin: origin, host: host).isAccepted)
        }
        #expect(strict.evaluate(origin: "chrome-extension://\(id)", host: host).isAccepted)
    }

    @Test("A host name pointed at 127.0.0.1 is refused")
    func dnsRebinding() {
        let origin = "chrome-extension://\(id)"
        for host in ["evil.example:42617", "127.0.0.1.evil.example", "localhost.evil.example:42617", "[::2]:42617", "127.0.0.1:port", nil] as [String?] {
            #expect(!policy.evaluate(origin: origin, host: host).isAccepted, "\(host ?? "no host") must be refused")
        }
        #expect(policy.evaluate(origin: origin, host: "127.0.0.1").isAccepted)
        #expect(policy.evaluate(headers: [("origin", origin), ("HOST", "localhost:1")]).isAccepted, "header names fold case")
    }

    @Test("The manifest's key gives the extension ID Ahenk accepts")
    func manifestKey() throws {
        let data = try Data(contentsOf: repository.appendingPathComponent("Extension/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let key = try #require(manifest["key"] as? String)
        let der = try #require(Data(base64Encoded: key))
        #expect(BridgeOriginPolicy.chromiumID(fromPublicKeyDigest: SHA256.hash(data: der)) == BridgeOriginPolicy.extensionID)
        // The Firefox variant carries no key (Firefox ignores it) but the same scripts.
        let firefox = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Extension/firefox/manifest.json"))) as? [String: Any])
        #expect(firefox["key"] == nil)
        let scripts = { (m: [String: Any]) in (m["content_scripts"] as? [[String: Any]])?.compactMap { $0["js"] as? [String] } }
        #expect(scripts(firefox) == scripts(manifest))
    }
}
