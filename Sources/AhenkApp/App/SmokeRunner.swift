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
        await report.check("demo") { try await self.checkDemo() }
        await report.check("nowPlaying") { try await self.checkNowPlaying() }
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
            + ["backward.fill", "forward.fill", "play.fill", "pause.fill", "plus", "minus", "waveform"])
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

    private func checkNowPlaying() async throws -> String {
        guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
        let model = environment.nowPlaying
        model.attach(provider: demo, artwork: demo, lyrics: demo, features: demo)
        let deadline = Date().addingTimeInterval(5)
        while model.snapshot == nil || model.artwork == nil || model.lyrics == nil {
            guard Date() < deadline else { throw SmokeFailure("The model did not receive song, cover and lyrics within 5 s") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let features = model.featureSource?.currentFeatures(), !features.isSilent else {
            throw SmokeFailure("No audio features while playing")
        }
        let title = model.snapshot?.track.title ?? "?"
        return "\u{201C}\(title)\u{201D} with cover, \(model.lyrics?.lines.count ?? 0) lyric lines and live features"
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
        let saved = directory.map { ", snapshots in \($0.path)" } ?? ""
        return "\(rendered) panes rendered offscreen (\(SettingsPane.allCases.count) panes × \(AppLanguage.allCases.count) languages)\(saved)"
    }

    // MARK: Helpers

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
