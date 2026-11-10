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
    private var edgeLightRenderer: EdgeLightRenderer?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func run() async -> SmokeReport {
        var report = SmokeReport(
            version: AppInfo.version, build: AppInfo.build, commit: AppInfo.commit,
            bundlePath: Bundle.main.bundlePath
        )
        let only = environment.options.smokeChecks
        func selected(_ name: String) -> Bool { only?.contains(name) ?? true }
        await report.check("launch") { try self.checkLaunch() }
        if selected("logging") { await report.check("logging") { try self.checkLogging() } }
        if selected("settings") { await report.check("settings") { try self.checkSettings() } }
        if selected("localization") { await report.check("localization") { try self.checkLocalization() } }
        if selected("resources") { await report.check("resources") { try self.checkResources() } }
        if selected("adapter") { await report.check("adapter") { try self.checkAdapter() } }
        if selected("adapterRun") { await report.check("adapterRun") { try await self.checkAdapterRun() } }
        if selected("sources") { await report.check("sources") { try self.checkSources() } }
        if selected("demo") { await report.check("demo") { try await self.checkDemo() } }
        if selected("hub") { await report.check("hub") { try await self.checkHub() } }
        if selected("nowPlaying") { await report.check("nowPlaying") { try await self.checkNowPlaying() } }
        if selected("artwork") { await report.check("artwork") { try await self.checkArtwork() } }
        if selected("recentlyPlayed") { await report.check("recentlyPlayed") { try self.checkRecentlyPlayed() } }
        if selected("audio") { await report.check("audio") { try self.checkAudio() } }
        if selected("metal") { await report.check("metal") { try self.checkMetal() } }
        if selected("edgeLight") { await report.check("edgeLight") { try self.checkEdgeLight() } }
        if selected("lightSwitch") { await report.check("lightSwitch") { try await self.checkLightSwitch() } }
        if selected("desktopPlayer") { await report.check("desktopPlayer") { try await self.checkDesktopPlayer() } }
        if selected("menus") { await report.check("menus") { try self.checkMenus() } }
        if selected("lyrics") { await report.check("lyrics") { try await self.checkLyrics() } }
        if selected("wallpaper") { await report.check("wallpaper") { try await self.checkWallpaper() } }
        if selected("wallpaperSwitch") {
            await report.check("wallpaperSwitch") { try await WallpaperCheck.runSwitch(environment: self.environment, snapshots: self.snapshotDirectory()) }
        }
        if selected("clearDesk") {
            await report.check("clearDesk") { try await ClearDeskCheck.run(environment: self.environment) }
        }
        if selected("dockArt") {
            await report.check("dockArt") {
                try DockArtCheck.run(palette: self.environment.demo?.songs.first?.palette ?? .neutral, snapshots: self.snapshotDirectory())
            }
        }
        if selected("stickers") {
            await report.check("stickers") { try await StickerCheck.run(snapshots: self.snapshotDirectory()) }
        }
        if selected("localPlayback") {
            await report.check("localPlayback") { try await LocalCheck.run() }
        }
        if selected("lyricAlignment") {
            await report.check("lyricAlignment") { try await LyricsAlignmentCheck.run(environment: self.environment) }
        }
        if selected("soundEffects") {
            await report.check("soundEffects") { try await EffectsCheck.run(environment: self.environment) }
        }
        if selected("settingsWindow") { await report.check("settingsWindow") { try await self.checkSettingsWindow() } }
        if selected("onboarding") {
            await report.check("onboarding") { try await OnboardingCheck.run(environment: self.environment, snapshots: self.snapshotDirectory()) }
        }
        if selected("bridge") {
            await report.check("bridge") { try await BridgeCheck.run(settings: self.environment.settings, snapshots: self.snapshotDirectory()) }
        }
        if let wait = environment.options.bridgeWait, let port = environment.options.bridgePort, selected("bridgeLive") {
            await report.check("bridgeLive") { try await BridgeCheck.runLive(port: port, wait: wait) }
        }
        // Last: it reuses the snapshots the checks above wrote.
        if let gallery = environment.options.galleryDirectory, selected("gallery") {
            let output = URL(fileURLWithPath: (gallery as NSString).expandingTildeInPath, isDirectory: true)
            await report.check("gallery") {
                try await ReadmeGallery.run(environment: self.environment, snapshots: self.snapshotDirectory(), output: output)
            }
        }
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
        let symbols = Set(QuickMenu.symbolNames + SettingsPane.allCases.map(\.symbolName) + DesktopSymbols.all
            + [BrowserExtensionInstaller.symbolName] + WallpaperSymbols.all + OnboardingView.symbols
            + ["backward.fill", "forward.fill", "play.fill", "pause.fill", "plus", "minus", "waveform", "app.dashed", "globe"])
        let missing = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        guard missing.isEmpty else { throw SmokeFailure("Missing SF Symbols: \(missing.sorted().joined(separator: ", "))") }
        var icon = "no app icon outside the app bundle"
        if AppInfo.isBundled {
            guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                  let image = NSImage(contentsOf: url), image.representations.count >= 5
            else { throw SmokeFailure("AppIcon.icns is missing from the app or has too few sizes") }
            icon = "AppIcon.icns with \(image.representations.count) sizes"
        }
        return "shader sources, \(symbols.count) SF Symbols and \(icon) present"
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
        model.attach(provider: services.hub, artwork: services.artwork, features: services.features)
        let deadline = Date().addingTimeInterval(5)
        while model.snapshot == nil || model.artwork == nil {
            guard Date() < deadline else { throw SmokeFailure("The model did not receive song and cover within 5 s") }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The lyrics come through the finder (the demo's invented lines).
        guard let track = model.snapshot?.track,
              case .synced(let lyrics) = await services.lyricsFinder.find(LyricsQuery(track: track)).response.result, !lyrics.isEmpty
        else { throw SmokeFailure("No lyrics for the playing demo song") }
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
        return "\u{201C}\(title)\u{201D} through the hub, with cover, \(lyrics.lines.count) lyric lines and live features from the analyzed demo beat"
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

    /// Compiles the bundled shader and checks the uniform layout against
    /// the shader's reflection.
    private func checkMetal() throws -> String {
        let (renderer, detail) = try EdgeLightCheck.compileAndCompare()
        edgeLightRenderer = renderer
        return detail
    }

    /// Every style rendered offscreen (finite, lit, only in the band), the
    /// position settings, and a frame drawn into a hidden window's strips.
    /// With `--snapshots`, a PNG per style.
    private func checkEdgeLight() throws -> String {
        guard let renderer = edgeLightRenderer else { throw SmokeFailure("the shader did not compile (see metal)") }
        let palette = environment.demo?.songs.first?.palette ?? .neutral
        let directory = snapshotDirectory()
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return try EdgeLightCheck.run(renderer: renderer, palette: palette, snapshots: directory)
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

    /// The lyrics, offscreen, with the demo's invented songs: every style
    /// at four moments of a song (the scene, the line and the countdown
    /// checked against the timeline; the Turkish song in the Turkish pass),
    /// the states without lines, the widget with its bar and both panels in
    /// both languages; the controller finds, lists, picks and times lyrics;
    /// one automatic-sync window of the demo beat changes nothing.
    private func checkLyrics() async throws -> String {
        guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
        let settings = environment.settings
        let originalLanguage = settings.general.language
        let originalLyrics = settings.lyrics
        let controller = environment.lyrics
        defer {
            settings.general.language = originalLanguage
            settings.lyrics = originalLyrics
            controller.stop()
        }
        let fonts = try LyricsCheck.checkFonts()
        let directory = snapshotDirectory()
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        // The controller follows the playing demo song.
        settings.lyrics.enabled = true
        controller.start()
        func wait(_ what: String, seconds: Double = 4, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("\(what) within \(Int(seconds)) s") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait("no lyrics for the playing demo song") { controller.phase == .synced }
        guard let original = controller.lyrics else { throw SmokeFailure("no lines") }
        controller.panel = .versions
        try await wait("no other versions") { controller.versions.value?.count == 3 }
        guard let late = controller.versions.value?[1] else { throw SmokeFailure("no late version") }
        controller.choose(late)
        try await wait("the picked version was not shown") { controller.choice?.id == late.id && controller.panel == nil }
        guard controller.lyrics?.lines.first?.start == (original.lines.first?.start ?? 0) + 0.7 else {
            throw SmokeFailure("the picked version's timing is not the one shown")
        }
        controller.useAutomatic()
        try await wait("the automatic pick did not come back") { controller.choice == nil && controller.lyrics == original }
        controller.nudge(by: LyricsController.nudgeStep)
        guard abs(controller.songOffset - LyricsController.nudgeStep) < 1e-9 else { throw SmokeFailure("the nudge did not move the timing") }
        controller.resetOffset()
        controller.panel = .search
        controller.searchTitle = "harbor"
        controller.searchArtist = ""
        controller.search()
        try await wait("search found nothing") { controller.results.value?.isEmpty == false }

        // Every style, the states and the widget, in both languages.
        var frames = 0
        var states = 0
        var widgets = 0
        for language in AppLanguage.allCases {
            settings.general.language = language
            let song = language == .turkish ? demo.songs[3] : demo.songs[0]
            let cover = await demo.artwork(for: song.track, pixelSize: 360)?.image
            frames += try LyricsCheck.renderStyles(song: song, cover: cover, language: language, directory: directory).frames
            states += try LyricsCheck.renderStates(song: song, cover: cover, language: language, directory: directory)
            let size = LyricsLayout.widgetSize(textScale: 1, showsCover: true)
            let model = environment.desktopPlayer.model
            let panels: [(String, LyricsController.Panel?)] = [
                ("bar", nil), ("versions", .versions), ("search", .search), ("effects", .effects), ("align", .align), ("align-working", .align),
            ]
            for (name, panel) in panels {
                controller.panel = panel
                if panel == .versions { try await wait("no versions to show") { controller.versions.value != nil } }
                if panel == .search {
                    controller.search()
                    try await wait("no search results to show") { controller.results.value != nil }
                }
                if panel == .effects {
                    // As a listener would have it: a preset chosen, switched
                    // on, and the controller following the (demo) player.
                    environment.effects.start()
                    settings.effects.select(.slowedReverb)
                    settings.effects.enabled = true
                    try await wait("the effects did not follow the demo player") { environment.effects.route == .demo }
                }
                if panel == .align {
                    environment.aligner.prepare()
                    environment.aligner.show(name == "align-working" ? .recognizing(0.4) : .idle)
                }
                let widget = LyricsWidget(
                    lyrics: controller, player: model, power: environment.power, settings: settings,
                    effects: environment.effects, audio: environment.audio, aligner: environment.aligner, showsBar: true
                )
                let bitmap = try await renderWidget(widget, size: size, model: model, language: language)
                try saveWidget(bitmap, name: "lyrics-\(name)", language: language, in: directory)
                widgets += 1
            }
            controller.panel = nil
            environment.aligner.show(.idle)
            environment.effects.stop()
            settings.effects = SoundEffectSettings()
        }

        // Automatic sync: one window of the bare demo beat is measured and
        // changes nothing (a single window never does).
        let window = DemoAudioSynth(sampleRate: LyricsSyncCapture.analysisRate).render(seconds: 32, from: 2)
        let started = ContinuousClock.now
        let measured = LyricsSyncSession.measure(window, sampleRate: LyricsSyncCapture.analysisRate, starts: original.lines.map(\.start), position: 2, beatPeriod: 0.5)
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        var session = LyricsSyncSession(key: "smoke", fingerprint: original.timingFingerprint)
        session.beginWindow()
        guard session.add(measured) == nil else { throw SmokeFailure("a single sync window changed the timing") }

        let saved = directory.map { ", snapshots in \($0.path)" } ?? ""
        return "\(frames) style frames (8 styles × 4 moments × 2 languages) with the right line and countdown, \(states) states, "
            + "\(widgets) widget renders; found, listed, picked, nudged and searched lyrics; a 32 s sync window measured in \(milliseconds) ms "
            + "(\(measured.stage.rawValue)); fonts \(fonts.joined(separator: ", "))\(saved)"
    }

    /// The live wallpaper offscreen: a window per display, a crossfade,
    /// frames of the generated motion and the moving cover, the states.
    private func checkWallpaper() async throws -> String {
        guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
        return try await WallpaperCheck.run(demo: demo, snapshots: snapshotDirectory())
    }

    private func checkSettingsWindow() async throws -> String {
        let settings = environment.settings
        let original = settings.general.language
        let originalWallpaper = settings.wallpaper
        defer {
            settings.general.language = original
            settings.wallpaper = originalWallpaper
        }
        // The user's video list with invented entries, so the snapshot shows
        // its rows (in-memory settings only).
        if snapshotDirectory() != nil, settings.wallpaper.savedVideos.isEmpty {
            let shown = SavedVideo(title: "Harbor at Dusk", kind: .youtube, reference: "ahenkDemo01")
            settings.wallpaper.addVideo(shown)
            settings.wallpaper.addVideo(SavedVideo(title: "Rain Window", kind: .file, reference: "/Users/you/Movies/Rain Window.mov"))
            settings.wallpaper.addVideo(SavedVideo(title: "Neon Tide", kind: .url, reference: "https://media.example/loops/neon-tide.mp4"))
            settings.wallpaper.selectVideo(id: shown.id)
        }
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
                // Sources, Live Wallpaper, Lyrics and Sound are taller than
                // the window: their lower sections (the browser extension,
                // the user's videos, lyric alignment, the sound effects and
                // the equalizer) in a tall copy.
                if let directory, [.sources, .wallpaper, .lyrics, .sound].contains(pane), let png = try await render(pane, height: 2_000).representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("settings-\(pane.rawValue)-full-\(language.rawValue).png"))
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

    /// The menu bar's Edge Light switch drives the running light: the real
    /// controller starts with every display switched off in the in-memory
    /// settings (so nothing can appear on a screen), then the menu item turns
    /// the light off and on again and the controller's status follows.
    private func checkLightSwitch() async throws -> String {
        let settings = environment.settings
        let original = settings.light
        let controller = environment.light
        defer {
            controller.stop()
            settings.light = original
        }
        settings.light.disabledDisplays = Set(LightScreen.current().map(\.0.id))
        settings.light.enabled = true
        controller.start()
        func wait(for description: String, _ condition: @escaping () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(4)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("the light did not become \(description) (status \(controller.status))") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let running: () -> Bool = { controller.status != .off && controller.status != .starting }
        try await wait(for: "ready", running)
        let first = controller.status
        func flip() throws {
            let menu = NSMenu()
            QuickMenu.populate(menu, environment: environment, placement: .menuBar)
            guard let item = menu.items.first(where: { $0.title == QuickToggle.edgeLight.title }), let action = item.action else {
                throw SmokeFailure("no Edge Light item in the menu")
            }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        try flip()
        try await wait(for: "off") { controller.status == .off }
        try flip()
        try await wait(for: "ready again", running)
        return "the menu's Edge Light item turns the running light off and on (\(first) → off → \(controller.status)); "
            + "every display was switched off, nothing was shown"
    }

    /// The desktop player in demo mode, without putting anything on screen:
    /// the widget window sits just above the desktop icons on every Space and
    /// never activates Ahenk; the playing artist's albums and a search come
    /// from the demo catalog; a pick plays through Ahenk's queue until the
    /// demo source confirms it; every widget and page is built and drawn
    /// offscreen in both languages (PNGs with `--snapshots`).
    private func checkDesktopPlayer() async throws -> String {
        guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
        let settings = environment.settings
        let originalLanguage = settings.general.language
        let originalPlayer = settings.player
        let model = DesktopPlayerModel(settings: settings, nowPlaying: environment.nowPlaying, services: environment.services, demo: demo)
        let clock = ClockModel(settings: settings)
        defer {
            model.stop()
            settings.general.language = originalLanguage
            settings.player = originalPlayer
        }
        model.start()
        model.setPresented(true)

        // The window: desktop level, every Space, never active.
        let window = DesktopWidgetWindow(widget: .player, frame: CGRect(x: -30_000, y: -30_000, width: 100, height: 100))
        window.allowsKeyboard = true
        defer { window.close() }
        let desktopIcons = Int(CGWindowLevelForKey(.desktopIconWindow))
        guard window.level.rawValue == desktopIcons + 1, window.level < .normal else {
            throw SmokeFailure("widget window level \(window.level.rawValue), expected \(desktopIcons + 1)")
        }
        guard window.collectionBehavior.contains(.canJoinAllSpaces), window.collectionBehavior.contains(.stationary),
              window.styleMask.contains(.nonactivatingPanel), !window.canBecomeMain, window.becomesKeyOnlyIfNeeded
        else { throw SmokeFailure("the widget window could activate Ahenk or leave its Space") }

        // The catalog: the playing artist's albums, then a search.
        func wait(_ what: String, seconds: Double = 4, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("\(what) within \(Int(seconds)) s") }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        try await wait("no albums for the playing artist") { model.albums.value?.isEmpty == false }
        guard let album = model.playingAlbum, let artist = model.artist else { throw SmokeFailure("the playing album is not known") }
        model.query = "nova"
        try await wait("no search results") { model.search.value?.songs.isEmpty == false }
        let found = model.search.value?.songs.count ?? 0
        model.query = ""
        guard let songs = await model.loadAlbumSongs(album), songs.count > 2 else { throw SmokeFailure("the album has no songs") }

        // A pick plays through Ahenk's queue and the demo source confirms it.
        model.play(songs, at: 1, context: .album(id: album.id, title: album.title))
        try await wait("the picked song did not start", seconds: 5) {
            model.conductor.attempt?.isConfirmed == true && environment.nowPlaying.snapshot?.track.title == songs[1].title
        }
        guard model.conductor.queue.upNext.count == songs.count - 2 else { throw SmokeFailure("the queue does not hold the rest of the album") }

        // Every widget and page, drawn offscreen in both languages.
        let directory = snapshotDirectory()
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var drawn = 0
        for language in AppLanguage.allCases {
            settings.general.language = language
            let scenes: [(String, () -> Void)] = [
                ("albums", { model.closePages(); model.setSize(.large) }),
                ("search", { model.query = "nova" }),
                ("album", { model.query = ""; model.closePages(); model.open(.album(album)) }),
                ("artist", { model.closePages(); model.open(.artist(artist)) }),
                ("queue", { model.closePages(); model.queueAsPage = true; model.isQueueOpen = true }),
                ("small", { model.isQueueOpen = false; model.queueAsPage = false; model.setSize(.small) }),
                ("small-search", { model.isSearchOpen = true; model.query = "harbor" }),
            ]
            for (name, prepare) in scenes {
                prepare()
                try await wait("no results for the \(name) scene") { !model.search.isLoading }
                let size = PlayerLayout.size(model.layoutState)
                let bitmap = try await renderWidget(PlayerWidget(model: model), size: size, model: model, language: language)
                try saveWidget(bitmap, name: "player-\(name)", language: language, in: directory)
                drawn += 1
            }
            model.clearSearch()
            model.setSize(.large)
            let clockSize = NSHostingView(rootView: ClockWidget(clock: clock, model: model, settings: settings.player, measuring: true)).fittingSize
            guard clockSize.width > 100, clockSize.height > 100 else { throw SmokeFailure("the clock measures \(clockSize)") }
            let others: [(String, AnyView, CGSize)] = [
                ("clock", AnyView(ClockWidget(clock: clock, model: model, settings: settings.player)), clockSize),
                ("list", AnyView(ContinuePlayingWidget(model: model)), CGSize(width: 328, height: 528)),
                ("queue-panel", AnyView(QueuePanel(model: model)), CGSize(width: PlayerLayout.queueWidth + 2 * PlayerLayout.margin, height: 460)),
            ]
            for (name, view, size) in others {
                let bitmap = try await renderWidget(view, size: size, model: model, language: language)
                try saveWidget(bitmap, name: name, language: language, in: directory)
                drawn += 1
            }
        }
        let saved = directory.map { ", snapshots in \($0.path)" } ?? ""
        return "desktop-level window that never activates; \(model.albums.value?.count ?? 0) albums of \(artist.name), \(found) songs found; "
            + "a pick played through the queue; \(drawn) widgets and pages drawn offscreen in \(AppLanguage.allCases.count) languages\(saved)"
    }

    /// Draws a widget view into a bitmap in an invisible window far off
    /// screen, glass painted (the window server's glass is not captured).
    private func renderWidget<V: View>(_ view: V, size: CGSize, model: DesktopPlayerModel, language: AppLanguage) async throws -> NSBitmapImageRep {
        let root = view
            .environment(\.widgetSnapshot, true)
            .environment(\.coverImages, model.images)
            .environment(\.locale, language.locale())
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.16, green: 0.14, blue: 0.22))
        let hosting = NSHostingView(rootView: root)
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
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(70))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SmokeFailure("Could not allocate a bitmap for a widget")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // Something besides the background was drawn.
        var lit = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
                if let color = bitmap.colorAt(x: x, y: y), color.brightnessComponent > 0.5 { lit += 1 }
            }
        }
        guard lit > 20 else { throw SmokeFailure("a widget drew nothing (\(Int(size.width))×\(Int(size.height)))") }
        return bitmap
    }

    private func saveWidget(_ bitmap: NSBitmapImageRep, name: String, language: AppLanguage, in directory: URL?) throws {
        guard let directory, let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: directory.appendingPathComponent("desktop-\(name)-\(language.rawValue).png"))
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
    private func render(_ pane: SettingsPane, height: CGFloat? = nil) async throws -> NSBitmapImageRep {
        let navigation = SettingsNavigation()
        navigation.selection = pane
        // The window background a real window paints (the About pane and
        // the demo banner sit on it, outside a Form).
        let hosting = NSHostingView(rootView: SettingsRootView(environment: environment, navigation: navigation)
            .background(Color(nsColor: .windowBackgroundColor)))
        var size = SettingsWindowController.defaultSize
        if let height { size.height = height }
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
