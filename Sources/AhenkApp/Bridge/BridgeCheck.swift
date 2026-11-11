import AhenkKit
import AppKit
import CryptoKit
import os

/// The browser bridge's smoke checks.
///
/// - `bridge` (every smoke run): a real server on a spare loopback port, a
///   stand-in extension (`BridgeLoopbackClient`) that says hello and reports
///   an invented song; the hub follows the tab and hides the system's guess
///   of the same song; a pause goes to the tab and back; the site's lyrics
///   and a "play this pick" request arrive; a web page's origin is refused;
///   a connection that never says hello is closed; the kernel's socket table
///   names the connecting process.
/// - `bridgeLive` (only with `--bridge-wait`): waits for a real browser with
///   the extension (Scripts/bridge-e2e.sh starts a headless test browser on
///   a mock music page) and drives it end to end.
@MainActor
enum BridgeCheck {
    private nonisolated static let smokeBrowser = "com.sinanmertsener.Ahenk.smoke-browser"

    static func run(settings: AppSettings, snapshots: URL?) async throws -> String {
        let packaged = try checkPackagedExtension()
        var drawn: Int?
        if let snapshots { drawn = try await snapshotInstaller(into: snapshots, settings: settings) }
        var timing = BridgeRegistry.Timing()
        timing.helloTimeout = 1.5
        timing.identifyTimeout = 1
        let base = 47_800 + Int.random(in: 0..<40) * 8
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let owner = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        let server = BrowserBridgeServer(configuration: .init(
            basePort: base, portCount: 8, appVersion: AppInfo.version, timing: timing, commandTimeout: 3
        )) { clientPort, serverPort, _ in
            let found = BrowserProcessLookup.socketOwner(clientPort: clientPort, serverPort: serverPort, includingSelf: true)
            owner.withLock { $0 = found }
            return BridgeBrowserProcess(processIdentifier: ownPID, bundleIdentifier: smokeBrowser)
        }
        server.start()
        defer { server.stop() }
        let port = try await listeningPort(of: server)

        // The system reader sees the same song in the same browser.
        let guess = NowPlayingSnapshot(
            track: Track(id: "meta:velvet", source: .otherApp, title: "Velvet Harbor Lights", artist: "Orchid Telemetry"),
            bundleIdentifier: smokeBrowser, elapsedTime: 12, playbackRate: 1, timestamp: Date(), capabilities: .transport, contentKind: .music
        )
        let system = HubInput(id: MediaRemoteProvider.providerID, priority: HubInput.systemPriority, reports: {
            AsyncStream { continuation in continuation.yield([guess]) }
        }, perform: { _, _ in false })
        let hub = NowPlayingHub(inputs: [BrowserProvider(bridge: server).hubInput, system])
        hub.start()
        defer { hub.stop() }
        let lyrics = BrowserLyricsProvider()
        let lyricsTask = Task.detached {
            for await (tabKey, sent) in server.lyricsUpdates() { lyrics.store(sent, tabKey: tabKey) }
        }
        defer { lyricsTask.cancel() }

        // A web page cannot connect.
        let web = BridgeLoopbackClient(port: port, origin: "https://example.com")
        if (try? await web.greet(profile: "web", timeout: 1.5)) != nil { throw SmokeFailure("a web page's origin was accepted") }
        web.close()

        // The extension can.
        let client = BridgeLoopbackClient(port: port, origin: BridgeLoopbackClient.extensionOrigin)
        defer { client.close() }
        guard case .welcome(let welcome) = try await client.greet(profile: "smoke"), welcome.protocolVersion == BridgeProtocol.version else {
            throw SmokeFailure("no welcome for the extension's origin")
        }
        let tab = BridgeTab(
            tabID: 7, site: BrowserSite.youtubeMusic.rawValue, url: "https://music.youtube.com/watch?v=smokeVideo1",
            title: "Velvet Harbor Lights", artist: "Orchid Telemetry", album: "Tidal Glass", duration: 214, position: 12,
            sampledAt: Date().timeIntervalSince1970 * 1000, state: .playing, liked: false, trackID: "smokeVideo1",
            kind: .music, capabilities: [.playPause, .next, .previous, .seek, .like, .unlike, .search]
        )
        try await client.send(.tabs([tab]))
        try await wait("the hub did not follow the tab") { hub.currentState.activeID?.instance == "smoke/7" }
        let state = hub.currentState
        guard state.players.count == 1, let snapshot = state.activeSnapshot else {
            throw SmokeFailure("the system's guess of the same song was not hidden (\(state.players.count) players)")
        }
        guard snapshot.track.source == .youtubeMusic, snapshot.bundleIdentifier == smokeBrowser,
              snapshot.track.id == "https://music.youtube.com/watch?v=smokeVideo1", snapshot.contentKind == .music
        else { throw SmokeFailure("the tab became \(snapshot.track.source.rawValue) \(snapshot.track.id)") }

        // A command goes to the tab and its answer comes back.
        async let paused = hub.perform(.pause)
        guard case .command(let command) = try await client.receive(), command.command == .pause, command.tabID == 7 else {
            throw SmokeFailure("the pause did not reach the tab")
        }
        try await client.send(.result(BridgeResult(id: command.id, ok: true)))
        var pausedTab = tab
        pausedTab.state = .paused
        pausedTab.sampledAt = Date().timeIntervalSince1970 * 1000
        try await client.send(.tab(pausedTab))
        guard await paused else { throw SmokeFailure("the tab's answer to the pause did not come back") }
        try await wait("the hub did not show the pause") { hub.currentState.activeSnapshot?.isPlaying == false }

        // The site's own lyrics.
        let lines = [
            BridgeLyricLine(start: 5, text: "Salt on the window, morning in the wires"),
            BridgeLyricLine(start: 9.5, text: "Every lantern hums a borrowed tune"),
            BridgeLyricLine(start: 14, text: "We row the harbor home"),
        ]
        try await client.send(.lyrics(BridgeSiteLyrics(
            tabID: 7, site: BrowserSite.youtubeMusic.rawValue,
            song: BridgeSong(title: "Velvet Harbor Lights", artist: "Orchid Telemetry", album: "Tidal Glass", duration: 214, trackID: "smokeVideo1"),
            lines: lines
        )))
        try await wait("the site's lyrics did not arrive") { lyrics.lookup(LyricsQuery(track: snapshot.track)) != nil }
        let response = try await lyrics.fetchResponse(LyricsQuery(track: snapshot.track))
        guard response.timingAuthority == .canonicalRecording, case .synced(let synced) = response.result, synced.lines.count == 3 else {
            throw SmokeFailure("the site's lyrics are not answered as the recording's own")
        }

        // Playing a pick on the site goes to the tab.
        let router = BridgePlaybackRouter(server: server)
        let pick = CatalogSong(id: "itunes:smoke", title: "Quiet Engines", artistName: "Nadia Ferro", albumTitle: "Low Orbit Letters", duration: 187)
        async let outcome = router.play(BrowserPlayRequest(site: .youtubeMusic, song: pick))
        guard case .request(let request) = try await client.receive(), request.kind == .play, request.tabID == 7,
              request.song?.title == "Quiet Engines"
        else { throw SmokeFailure("the pick did not reach the tab") }
        try await client.send(.result(BridgeResult(id: request.id, ok: true, outcome: .started, tabID: 7)))
        guard await outcome == .started else { throw SmokeFailure("the pick's answer was not \u{201C}started\u{201D}") }

        // The sound a tab's player holds ahead: asked for by seconds of the
        // song, answered in one large frame (ten seconds, a generated tone).
        let tone: [Int16] = (0..<160_000).map { Int16(12_000 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        var packed = Data(capacity: tone.count * 2)
        for value in tone { withUnsafeBytes(of: value.littleEndian) { packed.append(contentsOf: $0) } }
        async let held = server.heldSound(inTab: "smoke/7", from: 20, seconds: 10)
        guard case .request(let asked) = try await client.receive(), asked.kind == .sound, asked.tabID == 7,
              asked.song?.trackID == "smokeVideo1", asked.from == 20, asked.seconds == 10
        else { throw SmokeFailure("the request for the tab's held sound did not reach it") }
        let answer = BridgeResult(id: asked.id, ok: true, tabID: 7, sound: BridgeSound(heldFrom: 0, heldUntil: 39.8, start: 20, rate: 16_000, samples: packed.base64EncodedString()))
        let frame = try BridgeInbound.result(answer).encoded().count
        try await client.send(.result(answer))
        guard let sound = await held?.sound?.window, sound.start == 20, sound.samples.count == tone.count,
              zip(sound.samples, tone).allSatisfy({ abs($0 - Float($1) / 32_768) < 1e-6 })
        else { throw SmokeFailure("the tab's held sound did not come back whole") }

        // A connection that never says hello is told and closed.
        let silent = BridgeLoopbackClient(port: port, origin: BridgeLoopbackClient.extensionOrigin)
        guard case .error(let code, _) = try await silent.receive(timeout: 5), code == "noHello" else {
            throw SmokeFailure("a silent connection was not closed")
        }
        silent.close()

        // The kernel's socket table named the connecting process.
        guard owner.withLock({ $0 }) == ownPID else { throw SmokeFailure("the connecting process was not found from its socket") }

        // Leaving: the tab goes, the system's guess shows again.
        client.close()
        try await wait("the tab did not leave the hub") {
            !hub.currentState.players.contains { $0.id.source == .youtubeMusic } && hub.currentState.players.contains { $0.id.source == .otherApp }
        }
        return "127.0.0.1:\(port): web origin refused, extension welcomed (protocol \(welcome.protocolVersion)); the hub followed the tab "
            + "and hid the system's guess of the same song; pause round trip; site lyrics answered as the recording's own; "
            + "a pick reached the tab; ten seconds of the tab's held sound came back whole (a frame of \(frame / 1000) kB); a silent connection closed; socket owner found; the tab left with its connection; \(packaged)"
            + (drawn.map { ", install steps drawn in \($0) languages" } ?? "")
    }

    /// "Install Browser Extension…" as an image per language (`--snapshots`).
    private static func snapshotInstaller(into directory: URL, settings: AppSettings) async throws -> Int {
        let original = settings.general.language
        defer { settings.general.language = original }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var drawn = 0
        for language in AppLanguage.allCases {
            settings.general.language = language
            let alert = BrowserExtensionInstaller.stepsAlert()
            alert.layout()
            // Far off every screen and almost transparent, as the Settings
            // snapshots: an alert draws its text only in a window on screen.
            let window = alert.window
            // The alert's glass is not part of the bitmap: light text colours
            // keep the words readable on the transparent background.
            window.appearance = NSAppearance(named: .aqua)
            window.alphaValue = 0.01
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(200))
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: directory.appendingPathComponent("extension-installer-\(language.rawValue).png"))
            drawn += 1
        }
        return drawn
    }

    /// The app carries the extension for both browser families, and the
    /// Chromium folder's key gives the ID the server accepts.
    private static func checkPackagedExtension() throws -> String {
        guard AppInfo.isBundled else { return "extension: not packaged (development run)" }
        guard let chromium = BrowserExtensionInstaller.chromiumFolder, let firefox = BrowserExtensionInstaller.firefoxFolder else {
            throw SmokeFailure("the app carries no browser extension")
        }
        func manifest(_ folder: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SmokeFailure("\(folder.lastPathComponent): unreadable manifest") }
            return object
        }
        let chrome = try manifest(chromium)
        guard let key = chrome["key"] as? String, let der = Data(base64Encoded: key),
              BridgeOriginPolicy.chromiumID(fromPublicKeyDigest: SHA256.hash(data: der)) == BridgeOriginPolicy.extensionID
        else { throw SmokeFailure("the Chromium extension's key does not give \(BridgeOriginPolicy.extensionID)") }
        let gecko = (try manifest(firefox)["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any]
        guard gecko?["id"] is String else { throw SmokeFailure("the Firefox manifest has no add-on ID") }
        for folder in [chromium, firefox] {
            for file in ["background.js", "lib/protocol.js", "lib/sound.js", "page/engine.js", "content/relay.js", "popup/popup.html", "_locales/tr/messages.json"] {
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) else {
                    throw SmokeFailure("\(folder.lastPathComponent) lacks \(file)")
                }
            }
        }
        return "extension \(chrome["version"] as? String ?? "?") packaged for Chromium (ID \(BridgeOriginPolicy.extensionID)) and Firefox"
    }

    // MARK: Live, with a real browser

    /// What the mock music page (Tests/Extension/mock, served by Tests/Extension/e2e.mjs) plays; invented.
    private enum Mock {
        static let first = "Velvet Harbor Lights"
        static let second = "Quiet Engines"
        static let third = "Saffron Static"
        static let searched = CatalogSong(id: "itunes:mock5", title: "Lanterns Under Ice", artistName: "Mirela Stoica", albumTitle: "Northbound Postcards", duration: 223)
        static let playlist = "Night Shift Mix"
    }

    static func runLive(port: Int, wait seconds: Double) async throws -> String {
        let log = AhenkLogger(category: "smoke")
        let server = BrowserBridgeServer(configuration: .init(basePort: port, portCount: 1, appVersion: AppInfo.version)) { clientPort, serverPort, hello in
            BrowserProcessLookup.identify(clientPort: clientPort, serverPort: serverPort, hello: hello)
        }
        server.start()
        defer { server.stop() }
        _ = try await listeningPort(of: server)
        let hub = NowPlayingHub(inputs: [BrowserProvider(bridge: server).hubInput])
        hub.start()
        defer { hub.stop() }
        let lyrics = BrowserLyricsProvider()
        let lyricsTask = Task.detached {
            for await (tabKey, sent) in server.lyricsUpdates() { lyrics.store(sent, tabKey: tabKey) }
        }
        defer { lyricsTask.cancel() }
        let router = BridgePlaybackRouter(server: server)
        var steps: [String] = []
        func step(_ text: String) {
            steps.append(text)
            log.info("bridgeLive: \(text)")
        }
        func current() -> NowPlayingSnapshot? { hub.currentState.activeSnapshot }

        try await wait("no browser tab played the mock song within \(Int(seconds)) s", seconds: seconds) {
            current()?.track.title == Mock.first && current()?.isPlaying == true
        }
        guard let first = current(), let player = hub.currentState.activeID else { throw SmokeFailure("no player") }
        let browser = server.connectedBrowsers.first
        step("\u{201C}\(first.track.title)\u{201D} plays in \(browser?.browserName ?? "?") (\(first.bundleIdentifier ?? "no bundle"), pid \(first.processIdentifier.map(String.init) ?? "?")) as \(first.track.source.rawValue), \(first.contentKind.rawValue), id \(first.track.id)")
        // The mock page's player says its songs are art tracks (the cover as
        // a still): the live wallpaper must not take them for videos.
        guard first.songVideoKind == .artTrack else {
            throw SmokeFailure("the page's video type did not arrive (\(first.songVideoKind?.rawValue ?? "none"))")
        }
        step("video type: \(SongVideoKind.artTrack.rawValue)")

        func command(_ name: String, _ playback: PlaybackCommand, until: @escaping () -> Bool) async throws {
            guard await hub.perform(playback, on: player) else { throw SmokeFailure("\(name): the tab refused") }
            try await wait("\(name): the tab did not report it", seconds: 6, until)
            step(name)
        }
        try await command("pause", .pause) { current()?.isPlaying == false }
        try await command("play", .play) { current()?.isPlaying == true }
        try await command("seek to 1:00", .seek(to: 60)) {
            guard let now = current() else { return false }
            return abs(now.elapsed(at: Date()) - 60) < 4
        }
        try await command("like", .setLiked(true)) { current()?.isLiked == true }
        try await command("unlike", .setLiked(false)) { current()?.isLiked == false }
        try await command("shuffle on", .setShuffle(true)) { current()?.isShuffled == true }
        try await command("repeat one", .setRepeat(.one)) { current()?.repeatMode == .one }
        try await command("repeat off", .setRepeat(.off)) { current()?.repeatMode == .off }
        try await command("next", .next) { current()?.track.title == Mock.second }
        try await command("previous", .previous) { current()?.track.title == Mock.first }

        try await wait("the site's lyrics did not arrive", seconds: 8) {
            current().map { lyrics.lookup(LyricsQuery(track: $0.track)) != nil } ?? false
        }
        if let now = current(), let found = lyrics.lookup(LyricsQuery(track: now.track)) {
            step("the site's own synced lyrics arrived (\(found.lyrics.lines.count) lines, \(found.site.rawValue))")
        }

        guard let volume = await router.volume(on: .youtubeMusic) else { throw SmokeFailure("no volume") }
        await router.setVolume(0.35, on: .youtubeMusic)
        var changed = -1.0
        for _ in 0..<20 {
            changed = await router.volume(on: .youtubeMusic) ?? -1
            if abs(changed - 0.35) < 0.02 { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard abs(changed - 0.35) < 0.02 else { throw SmokeFailure("volume is \(changed) after setting 0.35") }
        step("volume read (\(String(format: "%.2f", volume))) and set to 0.35")

        guard let queue = await router.queue(on: .youtubeMusic), queue.items.count >= 4, queue.items.first(where: \.isCurrent)?.song.title == Mock.first else {
            throw SmokeFailure("the site's queue was not read")
        }
        guard await router.playQueueItem(2, on: .youtubeMusic) else { throw SmokeFailure("a queue item did not play") }
        try await wait("the queue item did not play", seconds: 6) { current()?.track.title == Mock.third }
        guard queue.canRemove, await router.removeQueueItem(3, on: .youtubeMusic) else { throw SmokeFailure("a queue item was not removed") }
        guard let shorter = await router.queue(on: .youtubeMusic), shorter.items.count == queue.items.count - 1,
              !shorter.items.contains(where: { $0.song.title == queue.items[3].song.title })
        else { throw SmokeFailure("the removed song is still in the queue") }
        step("queue of \(queue.items.count) read; item 3 played; item 4 removed")

        guard let lists = await router.playlists(on: .youtubeMusic), let list = lists.first(where: { $0.name == Mock.playlist }) else {
            throw SmokeFailure("the site's playlists were not read")
        }
        let songs = await router.songs(ofPlaylist: list.id, on: .youtubeMusic)
        guard songs.count == 3 else { throw SmokeFailure("the playlist has \(songs.count) songs, expected 3") }
        guard songs[1].title != current()?.track.title else { throw SmokeFailure("the playlist's second song plays already") }
        guard await router.playPlaylist(list.id, from: 1, on: .youtubeMusic) == .started else { throw SmokeFailure("the playlist did not start") }
        try await wait("the playlist's second song did not play", seconds: 6) { current()?.track.title == songs[1].title }
        step("\(lists.count) playlists; \u{201C}\(list.name)\u{201D} has \(songs.count) songs and played from its second")

        let outcome = await router.play(BrowserPlayRequest(site: .youtubeMusic, song: Mock.searched))
        guard outcome == .started else { throw SmokeFailure("search and play answered \(outcome)") }
        try await wait("the searched song did not play", seconds: 8) { current()?.track.title == Mock.searched.title && current()?.isPlaying == true }
        step("searched the site for \u{201C}\(Mock.searched.title)\u{201D} and played it")

        return steps.joined(separator: "; ")
    }

    // MARK: Helpers

    private static func listeningPort(of server: BrowserBridgeServer) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            switch server.currentStatus {
            case .listening(let port): return port
            case .failed(let reason): throw SmokeFailure("the bridge did not start: \(reason)")
            default: try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw SmokeFailure("the bridge did not start within 4 s")
    }

    private static func wait(_ what: String, seconds: Double = 4, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw SmokeFailure(what) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
