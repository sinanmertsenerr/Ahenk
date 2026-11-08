import AhenkKit
import AppKit
import SwiftUI

/// `--smoke`: initialise every subsystem with demo content, render a few
/// frames offscreen and report each result to `~/Library/Logs/Ahenk/smoke.json`.
///
/// Touches no permission-protected API and never writes the user's settings
/// (the environment holds an in-memory copy in this mode). Later steps add a
/// check per subsystem they introduce.
@MainActor
final class SmokeRunner {
    private let environment: AppEnvironment
    private let log = AhenkLogger(category: "smoke")

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func run() async -> SmokeReport {
        var report = SmokeReport(
            version: AppInfo.version, build: AppInfo.build, commit: AppInfo.commit,
            bundlePath: Bundle.main.bundlePath
        )
        await report.check("launch") { try self.checkLaunch() }
        await report.check("logging") { try self.checkLogging() }
        await report.check("settings") { try self.checkSettings() }
        await report.check("localization") { try self.checkLocalization() }
        await report.check("resources") { try self.checkResources() }
        await report.check("adapter") { try self.checkAdapter() }
        await report.check("adapterRun") { try await self.checkAdapterRun() }
        await report.check("sources") { try self.checkSources() }
        await report.check("demo") { try await self.checkDemo() }
        await report.check("hub") { try await self.checkHub() }
        await report.check("nowPlaying") { try await self.checkNowPlaying() }
        await report.check("artwork") { try await self.checkArtwork() }
        await report.check("recentlyPlayed") { try self.checkRecentlyPlayed() }
        await report.check("audio") { try self.checkAudio() }
        await report.check("metal") { try self.checkMetal() }
        await report.check("menus") { try self.checkMenus() }
        await report.check("settingsWindow") { try await self.checkSettingsWindow() }
        report.finish()
        for entry in report.subsystems {
            log.info("\(entry.name): \(entry.status.rawValue), \(entry.detail)")
        }
        return report
    }

    // MARK: Checks

    private func checkLaunch() throws -> String {
        guard environment.options.mode == .smoke, environment.demo != nil else {
            throw SmokeFailure("Not in smoke mode with demo content")
        }
        let where_ = AppInfo.isBundled ? "app bundle \(Bundle.main.bundlePath)" : "unbundled executable (swift run)"
        return "smoke mode with demo content, \(where_)"
    }

    private func checkLogging() throws -> String {
        guard let file = Log.file else { throw SmokeFailure("No log file configured") }
        log.info("Smoke test is writing to the log file")
        Log.flush()
        let size = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int ?? 0
        guard size > 0 else { throw SmokeFailure("\(file.url.path) is empty") }
        return "\(file.url.path) (\(size) bytes), rolls over at \(file.maxBytes / 1000) kB"
    }

    private func checkSettings() throws -> String {
        let settings = environment.settings
        let stored = UserDefaults.standard.object(forKey: AppSettings.defaultsKey) != nil
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        guard decoded.hasSameValues(as: settings) else { throw SmokeFailure("Encoding round trip changed values") }
        guard settings.origin == .memory else { throw SmokeFailure("Smoke settings are not an in-memory copy") }
        let source = stored ? "copy of the stored settings" : "defaults (nothing stored yet)"
        return "schema \(AppSettings.schemaVersion), \(source), \(data.count) bytes, language \(settings.general.language.rawValue)"
    }

    private func checkLocalization() throws -> String {
        guard let bundle = ResourceBundle.bundle else { throw SmokeFailure("\(ResourceBundle.name) not found") }
        guard L10n.turkish != nil else { throw SmokeFailure("tr.lproj is missing from \(bundle.bundlePath)") }
        let settings = environment.settings
        let original = settings.general.language
        defer { settings.general.language = original }

        settings.general.language = .turkish
        let samples = [
            "Settings…": "Ayarlar…",
            "Edge Light": "Kenar Işığı",
            "Quit Ahenk": "Ahenk'ten Çık",
            "Start every song at 0:15": "Her şarkıyı 0:15'ten başlat",
            "Ahenk Settings": "Ahenk Ayarları",
        ]
        for (key, expected) in samples where key.l10n != expected {
            throw SmokeFailure("\u{201C}\(key)\u{201D} is \u{201C}\(key.l10n)\u{201D} in Turkish, expected \u{201C}\(expected)\u{201D}")
        }
        settings.general.language = .english
        guard "Settings…".l10n == "Settings…" else { throw SmokeFailure("English is not the identity") }
        return "\(L10n.turkishEntryCount) Turkish strings, live switch works"
    }

    private func checkResources() throws -> String {
        guard MetalShaders.sourceURL(named: "EdgeLight") != nil else {
            throw SmokeFailure("Shaders/EdgeLight.metal missing from the resource bundle")
        }
        let symbols = Set(QuickMenu.symbolNames + SettingsPane.allCases.map(\.symbolName)
            + ["backward.fill", "forward.fill", "play.fill", "pause.fill", "plus", "minus", "waveform", "app.dashed"])
        let missing = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        guard missing.isEmpty else { throw SmokeFailure("Missing SF Symbols: \(missing.sorted().joined(separator: ", "))") }
        return "shader sources and \(symbols.count) SF Symbols present"
    }

    private func checkAdapter() throws -> String {
        guard let directory = AppInfo.adapterDirectory else {
            throw SmokeReport.Skip("not running from an app bundle")
        }
        let fm = FileManager.default
        let script = directory.appendingPathComponent("mediaremote-adapter.pl")
        let binary = directory.appendingPathComponent("MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter")
        guard fm.isReadableFile(atPath: script.path) else { throw SmokeFailure("\(script.path) missing") }
        guard fm.isReadableFile(atPath: binary.path) else { throw SmokeFailure("\(binary.path) missing") }
        let handle = try FileHandle(forReadingFrom: binary)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        let isMachO = [Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xCA, 0xFE, 0xBA, 0xBE])].contains(magic)
        guard isMachO else { throw SmokeFailure("\(binary.lastPathComponent) is not a Mach-O binary") }
        let license = fm.fileExists(atPath: directory.appendingPathComponent("LICENSE").path)
        return "script and framework bundled\(license ? " with LICENSE" : "") in \(directory.path)"
    }

    private func checkDemo() async throws -> String {
        guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
        let snapshot = demo.snapshot()
        guard let artwork = await demo.artwork(for: snapshot.track, pixelSize: NowPlayingModel.artworkPixelSize) else {
            throw SmokeFailure("No generated cover")
        }
        guard case .synced(let lyrics) = try await demo.fetch(LyricsQuery(track: snapshot.track)), !lyrics.isEmpty else {
            throw SmokeFailure("No invented lyrics")
        }
        let first = DemoBeat.features(at: 10)
        let next = DemoBeat.features(at: 10.5)
        guard first.bpm == 120, next.beatIndex == first.beatIndex + 1 else { throw SmokeFailure("Beat is not 120 BPM") }
        return "\(demo.songs.count) songs, \(artwork.pixelWidth)×\(artwork.pixelHeight) cover, \(lyrics.lines.count) lines, 120 BPM"
    }

    /// The bundled adapter answers once (`get`, no artwork). Reads the
    /// system's Now Playing like the app does (no permission involved) and
    /// reports only which kind of player plays, never the song.
    private func checkAdapterRun() async throws -> String {
        guard AppInfo.isBundled else { throw SmokeReport.Skip("not running from an app bundle") }
        guard let invocation = AdapterLocator.invocation() else { throw SmokeFailure("adapter files not found") }
        let adapter = MediaRemoteAdapter(invocation: invocation)
        guard let payload = await adapter.current(includeArtwork: false, timeout: 4) else {
            throw SmokeFailure("the adapter did not answer (MediaRemote may be blocked on this macOS)")
        }
        guard let snapshot = payload.snapshot(resolver: .standard, artworkAspectRatio: nil, now: Date()) else {
            return "answered: nothing is playing"
        }
        return "answered: source \(snapshot.track.source.rawValue), \(snapshot.isPlaying ? "playing" : "paused")"
    }

    private func checkSources() throws -> String {
        let resolver = SourceResolver.standard
        let expectations: [(String, AppKind)] = [
            (KnownApps.appleMusic, .musicApp(.appleMusic)),
            (KnownApps.spotify, .musicApp(.spotify)),
            (KnownApps.search, .browser),
            ("com.apple.Safari", .browser),
            ("org.videolan.vlc", .videoPlayer),
        ]
        for (bundle, kind) in expectations where resolver.kind(of: bundle) != kind {
            throw SmokeFailure("\(bundle) is not \(kind)")
        }
        let guess = WebSiteInference.guess(title: "Glass Harbor - YouTube Music", artist: "Nova Atlas", album: "", artworkAspectRatio: 1)
        guard guess.source == .youtubeMusic, guess.title == "Glass Harbor" else { throw SmokeFailure("site inference failed") }
        let browsers = BrowserRegistry.installedBrowsers()
        return "\(expectations.count) apps mapped, site inference works, \(browsers.count) browsers on this Mac"
    }

    /// The hub's rules on invented players: the newest start is followed,
    /// two playing together raise a question after the delay, an answer
    /// settles it.
    private func checkHub() async throws -> String {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func song(_ source: MusicSource, _ bundle: String, _ title: String) -> NowPlayingSnapshot {
            NowPlayingSnapshot(
                track: Track(id: title, source: source, title: title, artist: "Invented"),
                bundleIdentifier: bundle, elapsedTime: 0, playbackRate: 1, timestamp: start,
                capabilities: .transport, contentKind: .music
            )
        }
        var core = HubCore(configuration: HubConfiguration(conflictDelay: 3))
        core.ingest([song(.spotify, KnownApps.spotify, "One")], from: "spotify", now: start)
        core.ingest([song(.otherApp, KnownApps.search, "Two")], from: "mediaremote", now: start.addingTimeInterval(1))
        guard core.state.activeID?.source == .otherApp else { throw SmokeFailure("the newest start is not followed") }
        core.tick(now: start.addingTimeInterval(4.5))
        guard let conflict = core.state.conflict, conflict.players.count == 2 else { throw SmokeFailure("no question after the delay") }
        core.choose(conflict.players[1], now: start.addingTimeInterval(5))
        guard core.state.conflict == nil, core.state.activeID?.source == .spotify else { throw SmokeFailure("the answer was not followed") }
        return "automatic selection, conflict after 3 s and the answer work"
    }

    private func checkNowPlaying() async throws -> String {
        guard environment.demo != nil else { throw SmokeFailure("No demo provider") }
        let services = environment.services
        services.start(settings: environment.settings)
        let model = environment.nowPlaying
        model.attach(provider: services.hub, artwork: services.artwork, lyrics: services.lyrics, features: services.features)
        let deadline = Date().addingTimeInterval(5)
        while model.snapshot == nil || model.artwork == nil || model.lyrics == nil {
            guard Date() < deadline else { throw SmokeFailure("The model did not receive song, cover and lyrics within 5 s") }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The demo beat plays through the audio engine's analysis.
        environment.audio.start(hub: services.hub, settings: environment.settings)
        guard let source = model.featureSource, source === environment.audio.store else {
            throw SmokeFailure("the model does not read the audio engine's features")
        }
        let featureDeadline = Date().addingTimeInterval(3)
        while source.currentFeatures().isSilent {
            guard Date() < featureDeadline else { throw SmokeFailure("No audio features from the demo beat within 3 s") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let title = model.snapshot?.track.title ?? "?"
        guard services.state.activeID?.source == .demo else { throw SmokeFailure("the hub does not follow the demo") }
        return "\u{201C}\(title)\u{201D} through the hub, with cover, \(model.lyrics?.lines.count ?? 0) lyric lines and live features from the analyzed demo beat"
    }

    /// Decodes, crops and colours generated covers through the real
    /// pipeline, offline, with a throwaway disk cache.
    private func checkArtwork() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ArtworkPipeline(disk: ArtworkDiskCache(directory: directory), fetcher: OfflineFetcher(), catalog: nil)
        let palette = Palette(colors: [SRGBColor("#0E5E6F"), SRGBColor("#FF7A6B"), SRGBColor("#FFD9A0")])
        guard let cover = DemoArtwork.makeImage(palette: palette, seed: 7, pixelSize: 800),
              let data = ArtworkImageDecoder.pngData(cover)
        else { throw SmokeFailure("could not draw a cover") }
        let snapshot = NowPlayingSnapshot(
            track: Track(id: "smoke", source: .local, title: "Generated", artist: "Ahenk"),
            elapsedTime: 0, playbackRate: 0, timestamp: Date(), contentKind: .music, artworkData: data
        )
        let started = ContinuousClock.now
        guard let artwork = await pipeline.artwork(for: snapshot, pixelSize: 600) else { throw SmokeFailure("the pipeline returned nothing") }
        let elapsed = started.duration(to: .now)
        guard artwork.pixelWidth == 600, artwork.pixelHeight == 600 else { throw SmokeFailure("cover is \(artwork.pixelWidth)×\(artwork.pixelHeight)") }
        guard let extracted = artwork.palette, extracted.colors.count >= 3 else { throw SmokeFailure("fewer than three colours") }
        guard extracted.onDark.allSatisfy({ $0.contrastRatio(with: Palette.darkBackdrop) >= 4.5 }) else {
            throw SmokeFailure("a text colour is not readable on dark")
        }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        return "600 px cover with \(extracted.colors.count) colours in \(String(format: "%.0f", milliseconds)) ms; text variants pass 4.5:1"
    }

    private func checkRecentlyPlayed() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-smoke-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentlyPlayedStore(fileURL: url)
        for title in ["One", "Two", "One"] {
            store.record(Track(id: title, source: .local, title: title, artist: "Invented"), bundleIdentifier: nil, at: Date())
        }
        store.flush()
        let reloaded = RecentlyPlayedStore(fileURL: url).items.map(\.track.title)
        guard reloaded == ["One", "Two"] else { throw SmokeFailure("reloaded \(reloaded)") }
        let live = environment.services.recentlyPlayed.fileURL == nil ? "in memory for the demo" : "on disk"
        return "deduplicated, newest first, survives a reload; the running list is \(live)"
    }

    /// The analysis on generated audio: a 120 BPM kick train must read as
    /// 120 BPM with every settled beat within 50 ms, silence must gate, a
    /// high sine must light the high band, and samples written to the ring
    /// must reach the store. Reads the system audio permission silently
    /// (no prompt, no tap).
    private func checkAudio() throws -> String {
        let rate = 48_000.0
        let seconds = 10.0
        let (kicks, truth) = SyntheticSignal.kickTrain(bpm: 120, seconds: seconds, sampleRate: rate)
        let analyzer = AudioAnalyzer(sampleRate: rate)
        var beats: [BeatEvent] = []
        analyzer.onBeat = { beats.append($0) }
        let started = ContinuousClock.now
        kicks.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(512, buffer.count - offset)
                analyzer.process(buffer.baseAddress! + offset, count: count)
                offset += count
            }
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let bpm = analyzer.frame.features.bpm
        guard abs(bpm - 120) <= 2 else { throw SmokeFailure("a 120 BPM kick train read as \(bpm) BPM") }
        let settled = beats.filter { $0.time >= 6 }
        let worst = settled.map { beat in truth.map { abs($0 - beat.time) }.min() ?? 1 }.max() ?? 1
        guard settled.count >= 7, worst <= 0.05 else {
            throw SmokeFailure("\(settled.count) settled beats, worst off by \(Int(worst * 1000)) ms")
        }
        analyzer.process(SyntheticSignal.silence(seconds: 1, sampleRate: rate))
        guard analyzer.frame.features.isSilent, analyzer.frame.features.energy == 0 else { throw SmokeFailure("silence was not gated") }

        let tone = AudioAnalyzer(sampleRate: rate)
        tone.process(SyntheticSignal.sine(frequency: 8_000, seconds: 1, sampleRate: rate))
        let bands = tone.frame.features.bands
        guard bands.high > 0.9, bands.bass < 0.05 else { throw SmokeFailure("an 8 kHz sine gave bands \(bands)") }

        // Ring → analyzer → store, on the host clock.
        let store = AudioFeatureStore()
        let pipeline = AudioAnalysisPipeline(store: store, ringCapacity: 1 << 15)
        pipeline.configure(sampleRate: rate)
        var now = AudioClock.now()
        pipeline.setGate(open: true, at: now)
        let music = DemoAudioSynth(sampleRate: rate).render(seconds: 1)
        music.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(480, buffer.count - offset)
                pipeline.ring.writer.write(buffer.baseAddress! + offset, count: count)
                offset += count
                now += Double(count) / rate
                pipeline.pump(now: now)
            }
        }
        guard !store.features(at: now).isSilent else { throw SmokeFailure("samples in the ring did not reach the store") }

        let permission = SystemAudioPermission.status()
        let speed = Int((seconds * 1000 / max(milliseconds, 0.001)).rounded())
        return "120 BPM kick train read as \(String(format: "%.1f", bpm)) BPM, beats within \(Int((worst * 1000).rounded())) ms, "
            + "\(Int(seconds)) s analysed in \(Int(milliseconds.rounded())) ms (\(speed)× real time); silence gated, bands sane, "
            + "ring to store works; system audio access \(permission.rawValue) (read without a prompt)"
    }

    private func checkMetal() throws -> String {
        let palette = environment.demo?.songs.first?.palette ?? .neutral
        let frames = (0..<3).map { DemoBeat.features(at: Double($0) * 0.25) }
        let result = try MetalProbe.run(frames: frames, palette: palette, light: LightSettings())
        let compile = String(format: "%.0f", result.compileMilliseconds)
        return "\(result.deviceName): compiled EdgeLight.metal in \(compile) ms, rendered \(result.frames) frames (edge alpha \(result.edgeAlpha), centre \(result.centerAlpha))"
    }

    private func checkMenus() throws -> String {
        let settings = environment.settings
        let original = settings.general.language
        defer { settings.general.language = original }
        var itemCount = 0
        for language in AppLanguage.allCases {
            settings.general.language = language
            let menu = NSMenu()
            QuickMenu.populate(menu, environment: environment, placement: .menuBar)
            for toggle in QuickToggle.allCases {
                guard let item = menu.items.first(where: { $0.title == toggle.title }) else {
                    throw SmokeFailure("\(toggle.rawValue) is missing from the \(language.rawValue) menu")
                }
                guard item.state == (settings.isOn(toggle) ? .on : .off) else {
                    throw SmokeFailure("\(toggle.rawValue) shows the wrong state")
                }
            }
            guard menu.items.contains(where: { $0.title == "Clear Desk".l10n }),
                  menu.items.contains(where: { $0.title == "Settings…".l10n }),
                  menu.items.contains(where: { $0.title == "Quit Ahenk".l10n })
            else { throw SmokeFailure("Clear Desk, Settings… or Quit is missing") }
            itemCount = menu.items.count
            let dock = NSMenu()
            QuickMenu.populate(dock, environment: environment, placement: .dock)
            guard QuickToggle.allCases.allSatisfy({ toggle in dock.items.contains { $0.title == toggle.title } }),
                  !dock.items.contains(where: { $0.title == "Quit Ahenk".l10n })
            else { throw SmokeFailure("Dock menu should hold the toggles and leave Quit to the system") }
            guard MainMenu.build(environment: environment).items.count == 3 else {
                throw SmokeFailure("Main menu should have the app, Edit and Window menus")
            }
            // The question asked while two sources play.
            let players = [PlayerID(source: .demo), PlayerID(source: .demo, bundleIdentifier: "com.sinanmertsener.Ahenk.demo-b")]
            let question = QuickMenu.conflictItems(PlaybackConflict(players: players, since: Date()), services: environment.services)
            guard question.count == 3, question[0].title == "Which one should Ahenk follow?".l10n,
                  question[1].title == "Demo".l10n, question[2].action != nil
            else { throw SmokeFailure("the conflict question is incomplete in \(language.rawValue)") }
        }
        // The toggles are wired to the settings (an in-memory copy here).
        settings.general.language = .english
        let menu = NSMenu()
        QuickMenu.populate(menu, environment: environment, placement: .menuBar)
        let before = settings.isOn(.edgeLight)
        guard let item = menu.items.first(where: { $0.title == QuickToggle.edgeLight.title }), let action = item.action else {
            throw SmokeFailure("Edge Light item has no action")
        }
        NSApp.sendAction(action, to: item.target, from: item)
        guard settings.isOn(.edgeLight) != before else { throw SmokeFailure("Edge Light item did not flip the setting") }
        settings.flip(.edgeLight)
        return "menu bar menu (\(itemCount) items), Dock menu and main menu in \(AppLanguage.allCases.count) languages; toggles flip settings"
    }

    private func checkSettingsWindow() async throws -> String {
        let settings = environment.settings
        let original = settings.general.language
        defer { settings.general.language = original }
        let directory = snapshotDirectory()
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var rendered = 0
        for language in AppLanguage.allCases {
            settings.general.language = language
            for pane in SettingsPane.allCases {
                let bitmap = try await render(pane)
                rendered += 1
                if let directory, let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("settings-\(pane.rawValue)-\(language.rawValue).png"))
                }
            }
        }
        if let directory {
            // The menu bar glyph, plain and with the "Ahenk asks" dot.
            for (name, icon) in [("menubar-icon", MenuBarIcon.image), ("menubar-icon-attention", MenuBarIcon.attention)] {
                if let png = Self.png(of: icon, scale: 8) {
                    try png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
        }
        let saved = directory.map { ", snapshots in \($0.path)" } ?? ""
        return "\(rendered) panes rendered offscreen (\(SettingsPane.allCases.count) panes × \(AppLanguage.allCases.count) languages)\(saved)"
    }

    // MARK: Helpers

    /// `image` drawn black on white at `scale` (template images are masks).
    private static func png(of image: NSImage, scale: CGFloat) -> Data? {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func snapshotDirectory() -> URL? {
        guard let raw = environment.options.snapshotDirectory else { return nil }
        if raw.isEmpty { return Log.directory.appendingPathComponent("snapshots", isDirectory: true) }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shows the Settings content in a borderless, almost transparent window
    /// far outside every screen (so nobody sees it, but AppKit really draws
    /// it) and copies it into a bitmap. The glass sidebar cannot be captured
    /// this way and comes out blank; the panes render in full.
    private func render(_ pane: SettingsPane) async throws -> NSBitmapImageRep {
        let navigation = SettingsNavigation()
        navigation.selection = pane
        let hosting = NSHostingView(rootView: SettingsRootView(environment: environment, navigation: navigation))
        let size = SettingsWindowController.defaultSize
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentView = hosting
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.orderFrontRegardless()
        // Let SwiftUI finish its first update and display passes.
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SmokeFailure("Could not allocate a bitmap for \(pane.rawValue)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}

/// The smoke run never touches the network.
private struct OfflineFetcher: HTTPFetching {
    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        throw URLError(.notConnectedToInternet)
    }
}
