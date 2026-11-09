import Foundation
import Testing
@testable import AhenkKit

// Real sockets on 127.0.0.1 with a stand-in extension. Invented songs only.

private func makeServer(base: Int, count: Int = 4, helloTimeout: TimeInterval = 10, identify: BrowserBridgeServer.BrowserIdentifier? = nil) -> BrowserBridgeServer {
    var timing = BridgeRegistry.Timing()
    timing.helloTimeout = helloTimeout
    timing.identifyTimeout = 0.5
    return BrowserBridgeServer(
        configuration: .init(basePort: base, portCount: count, appVersion: "test", timing: timing, commandTimeout: 2),
        identifier: identify ?? { _, _, _ in BridgeBrowserProcess(processIdentifier: 501, bundleIdentifier: "com.google.Chrome") }
    )
}

private func port(of server: BrowserBridgeServer) async throws -> UInt16 {
    for _ in 0..<200 {
        if case .listening(let port) = server.currentStatus { return port }
        if case .failed(let reason) = server.currentStatus { throw SmokeFailure(reason) }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SmokeFailure("not listening")
}

private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}

/// A spare range per test, so tests can run side by side.
private func base() -> Int { 46_000 + Int.random(in: 0..<900) * 4 }

@Suite("Bridge server", .serialized)
struct BridgeServerTests {
    @Test("The extension connects, reports a tab and takes a command")
    func roundTrip() async throws {
        let server = makeServer(base: base())
        server.start()
        defer { server.stop() }
        let port = try await port(of: server)
        let client = BridgeLoopbackClient(port: port, origin: BridgeLoopbackClient.extensionOrigin)
        defer { client.close() }
        guard case .welcome(let welcome) = try await client.greet(profile: "prof") else { Issue.record("no welcome"); return }
        #expect(welcome.protocolVersion == 1 && welcome.app == "Ahenk")

        let tab = BridgeTab(tabID: 5, site: "soundCloud", url: "https://soundcloud.com/kestrel-vale/saffron-static", title: "Saffron Static",
                            artist: "Kestrel & Vale", sampledAt: Date().timeIntervalSince1970 * 1000, state: .playing, capabilities: [.playPause, .like, .rate])
        try await client.send(.tabs([tab]))
        try await waitFor { server.currentTabs.count == 1 }
        let report = try #require(server.currentTabs.first)
        #expect(report.tabID == "prof/5" && report.site == .soundCloud && report.browserBundleIdentifier == "com.google.Chrome")
        #expect(report.bridgeCapabilities.contains(.rate))

        async let sent = server.send(.setLiked(true), toTab: "prof/5")
        guard case .command(let command) = try await client.receive() else { Issue.record("no command"); return }
        #expect(command.command == .like && command.on == true && command.tabID == 5)
        try await client.send(.result(BridgeResult(id: command.id, ok: true)))
        #expect(await sent)

        async let faster = server.setRate(1.25, forTab: "prof/5")
        guard case .command(let rate) = try await client.receive() else { Issue.record("no rate command"); return }
        #expect(rate.command == .rate && rate.rate == 1.25 && rate.tabID == 5)
        try await client.send(.result(BridgeResult(id: rate.id, ok: true)))
        #expect(await faster)
        #expect(await server.setRate(1.25, forTab: "prof/404") == false, "an unknown tab")

        async let unanswered = server.send(.next, toTab: "prof/5")
        _ = try await client.receive()
        #expect(await unanswered == false, "no answer in time is a failure")
        #expect(await server.send(.next, toTab: "prof/404") == false, "an unknown tab")

        try await client.send(.tabRemoved(tabID: 5))
        try await waitFor { server.currentTabs.isEmpty }
    }

    @Test("A web page's origin is refused")
    func refusesWebOrigins() async throws {
        let server = makeServer(base: base())
        server.start()
        defer { server.stop() }
        let port = try await port(of: server)
        for origin in ["https://music.youtube.com", "chrome-extension://abcdefghijklmnopabcdefghijklmnop", nil] as [String?] {
            let client = BridgeLoopbackClient(port: port, origin: origin)
            await #expect(throws: (any Error).self) { _ = try await client.greet(profile: "x", timeout: 1.5) }
            client.close()
        }
        #expect(server.connectedBrowsers.isEmpty)
    }

    @Test("Several browsers at once; a closed connection takes its tabs along")
    func severalBrowsers() async throws {
        let server = makeServer(base: base())
        server.start()
        defer { server.stop() }
        let port = try await port(of: server)
        let a = BridgeLoopbackClient(port: port, origin: BridgeLoopbackClient.extensionOrigin)
        let b = BridgeLoopbackClient(port: port, origin: "moz-extension://8f5c2a6e-3b1d-4c7a-9e0f-1a2b3c4d5e6f")
        _ = try await a.greet(profile: "chrome")
        _ = try await b.greet(profile: "firefox", browser: "Firefox")
        let now = Date().timeIntervalSince1970 * 1000
        try await a.send(.tabs([BridgeTab(tabID: 1, site: "youtubeMusic", title: "Velvet Harbor Lights", artist: "Orchid Telemetry", sampledAt: now, state: .playing)]))
        try await b.send(.tabs([BridgeTab(tabID: 1, site: "deezer", title: "Marmara Neon", artist: "Deniz Ulaş Trio", sampledAt: now, state: .paused)]))
        try await waitFor { server.currentTabs.count == 2 }
        #expect(Set(server.currentTabs.map(\.tabID)) == ["chrome/1", "firefox/1"])
        #expect(server.connectedBrowsers.count == 2)
        a.close()
        try await waitFor { server.currentTabs.count == 1 }
        #expect(server.currentTabs.first?.tabID == "firefox/1")
        b.close()
    }

    @Test("A connection that never says hello is closed")
    func helloTimeout() async throws {
        let server = makeServer(base: base(), helloTimeout: 0.4)
        server.start()
        defer { server.stop() }
        let client = BridgeLoopbackClient(port: try await port(of: server), origin: BridgeLoopbackClient.extensionOrigin)
        guard case .error(let code, _) = try await client.receive(timeout: 3) else { Issue.record("no error"); return }
        #expect(code == "noHello")
    }

    @Test("A taken port moves the server to the next one in the range")
    func portFallback() async throws {
        let first = base()
        let a = makeServer(base: first)
        a.start()
        defer { a.stop() }
        #expect(try await port(of: a) == UInt16(first))
        let b = makeServer(base: first)
        b.start()
        defer { b.stop() }
        #expect(try await port(of: b) == UInt16(first + 1))
        let c = makeServer(base: first, count: 1)
        c.start()
        defer { c.stop() }
        try await waitFor { if case .failed = c.currentStatus { true } else { false } }
    }

    @Test("Requests reach the tab and their answers come back")
    func requests() async throws {
        let server = makeServer(base: base())
        server.start()
        defer { server.stop() }
        let client = BridgeLoopbackClient(port: try await port(of: server), origin: BridgeLoopbackClient.extensionOrigin)
        defer { client.close() }
        _ = try await client.greet(profile: "p")
        try await client.send(.tabs([BridgeTab(tabID: 2, site: "spotify", title: "Lanterns Under Ice", artist: "Mirela Stoica",
                                               sampledAt: Date().timeIntervalSince1970 * 1000, state: .paused, capabilities: [.playlists, .queue, .volume])]))
        try await waitFor { server.currentTabs.count == 1 }
        let router = BridgePlaybackRouter(server: server)
        #expect(router.isConnected && router.hasVolume(on: .spotifyWeb) && !router.hasVolume(on: .tidal))

        async let lists = router.playlists(on: .spotifyWeb)
        guard case .request(let request) = try await client.receive() else { Issue.record("no request"); return }
        #expect(request.kind == .playlists && request.tabID == 2 && request.site == "spotify")
        try await client.send(.result(BridgeResult(id: request.id, ok: true, playlists: [
            BridgePlaylist(id: "37i9mockPlaylist01", name: "Night Shift Mix", url: "https://open.spotify.com/playlist/37i9mockPlaylist01", songCount: 3),
        ])))
        let playlists = try #require(await lists)
        #expect(playlists.map(\.id) == ["site:spotify:37i9mockPlaylist01"] && playlists.first?.songCount == 3)

        async let played = router.playPlaylist(playlists[0].id, from: 1, on: .spotifyWeb)
        guard case .request(let play) = try await client.receive() else { Issue.record("no request"); return }
        #expect(play.kind == .playPlaylist && play.playlistID == "37i9mockPlaylist01" && play.index == 1)
        #expect(play.playlistURL == "https://open.spotify.com/playlist/37i9mockPlaylist01", "the URL read with the list goes along")
        try await client.send(.result(BridgeResult(id: play.id, ok: true, outcome: .opened)))
        #expect(await played == .opened)

        async let queue = router.queue(on: .spotifyWeb)
        guard case .request(let read) = try await client.receive() else { Issue.record("no request"); return }
        try await client.send(.result(BridgeResult(id: read.id, ok: true, queue: [
            BridgeQueueItem(index: 0, song: BridgeSong(title: "Lanterns Under Ice", artist: "Mirela Stoica"), isCurrent: true),
            BridgeQueueItem(index: 1, song: BridgeSong(title: "Quiet Engines", artist: "Nadia Ferro", trackID: "AhenkMockTrackSpotify2")),
        ])))
        let items = try #require(await queue)
        #expect(items.upNext.map(\.song.title) == ["Quiet Engines"] && items.canRemove == false)
        #expect(items.items[1].song.origin?.id == "spotify:track:AhenkMockTrackSpotify2")
    }
}
