import AhenkKit
import AppKit
import SwiftUI

/// The live wallpaper's smoke checks. Nothing appears on a screen: windows
/// are built but never ordered in, frames are drawn offscreen, the running
/// controller has every display switched off, and nothing is looked up
/// online (the demo's generated candidates only).
@MainActor
enum WallpaperCheck {
    /// Per display: the window (the desktop picture's level, under the
    /// icons, every Space, never clicked), its layer with two generated
    /// pictures crossfading, a frame drawn offscreen before and after; the
    /// state machine through a song; the embedded player's page; ranking.
    static func run(demo: DemoProvider, snapshots: URL?) async throws -> String {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let plan = WallpaperPowerPolicy.plan(LightFrameInputs())
        let song = demo.songs[0]
        let candidates = WallpaperDemo.candidates(for: song)
        var screens = 0
        var frames = 0
        for screen in NSScreen.screens {
            screens += 1
            let aspect = screen.frame.height > 0 ? screen.frame.width / screen.frame.height : 1.6
            let size = CGSize(width: 480, height: (480 / aspect).rounded())
            let window = WallpaperWindow(frame: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size))
            defer { window.close() }
            guard window.level.rawValue == desktop, window.level.rawValue < icons else {
                throw SmokeFailure("wallpaper window level \(window.level.rawValue), expected \(desktop) (icons at \(icons))")
            }
            let behavior = window.collectionBehavior
            guard behavior.contains(.canJoinAllSpaces), behavior.contains(.stationary), !behavior.contains(.fullScreenAuxiliary),
                  window.ignoresMouseEvents, !window.canBecomeKey, !window.canBecomeMain
            else { throw SmokeFailure("the wallpaper window could take clicks, the focus or leave its Space") }

            // The layer with the song's generated "video", then a crossfade
            // to another look in front of it, drawn in an invisible window
            // far outside every screen (layers attach once a window shows).
            let content = WallpaperScreenView(frame: CGRect(origin: .zero, size: size))
            let host = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.alphaValue = 0.01
            host.contentView = content
            host.orderFrontRegardless()
            defer {
                host.orderOut(nil)
                host.contentView = nil
                host.close()
            }
            content.setLook(dimming: 0.2, blur: 0)
            let first = media(candidates[0], look: 0, song: song, plan: plan, size: size)
            content.host(first)
            first.alphaValue = 1
            content.setOpacity(1, duration: 0)
            try await Task.sleep(for: .milliseconds(80))
            content.layoutSubtreeIfNeeded()
            let before = try render(content, size: size)
            let second = media(candidates[1], look: 1, song: song, plan: plan, size: size)
            content.host(second)
            second.alphaValue = 0
            content.bringToFront(second)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                second.animator().alphaValue = 1
            }, completionHandler: nil)
            try await Task.sleep(for: .milliseconds(260))
            guard content.stage.subviews.last === second, second.alphaValue == 1 else {
                throw SmokeFailure("the crossfade did not bring the next picture to the front")
            }
            content.layoutSubtreeIfNeeded()
            let after = try render(content, size: size)
            guard difference(before, after) > 0.02 else { throw SmokeFailure("the crossfade changed nothing on screen") }
            frames += 2
            if let snapshots, screens == 1 {
                try save(before, "wallpaper-generated-a", in: snapshots)
                try save(after, "wallpaper-generated-b", in: snapshots)
            }
            first.tearDown()
            second.tearDown()
        }

        // The moving cover from a generated demo cover.
        let coverSize = CGSize(width: 480, height: 300)
        let cover = CoverMotionView(candidate: .artwork, plan: plan, frame: CGRect(origin: .zero, size: coverSize))
        let coverHost = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: coverSize), styleMask: [.borderless], backing: .buffered, defer: false)
        coverHost.isReleasedWhenClosed = false
        coverHost.alphaValue = 0.01
        coverHost.contentView = cover
        coverHost.orderFrontRegardless()
        defer {
            cover.tearDown()
            coverHost.orderOut(nil)
            coverHost.contentView = nil
            coverHost.close()
        }
        let artwork = await demo.artwork(for: song.track, pixelSize: 600)
        cover.setCover(artwork?.image, palette: song.palette, key: "smoke")
        let deadline = Date().addingTimeInterval(4)
        while !cover.isReady {
            guard Date() < deadline else { throw SmokeFailure("the blurred cover was not ready within 4 s") }
            try await Task.sleep(for: .milliseconds(20))
        }
        cover.layoutSubtreeIfNeeded()
        let coverFrame = try render(cover, size: coverSize)
        frames += 1
        if let snapshots { try save(coverFrame, "wallpaper-cover", in: snapshots) }

        // The state machine through a song: loads under a clear layer, fades
        // in, crossfades, melts back after a pause, lets go.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var stage = WallpaperStage()
        var inputs = WallpaperStage.Inputs(music: .playing, wanted: "a")
        let loading = stage.update(inputs, now: t0)
        inputs.ready = ["a"]
        let shown = stage.update(inputs, now: t0 + 1)
        inputs.wanted = "b"
        inputs.ready = ["a", "b"]
        let crossfading = stage.update(inputs, now: t0 + 2)
        inputs.music = .paused(since: t0 + 5)
        _ = stage.update(inputs, now: t0 + 5)
        let melting = stage.update(inputs, now: t0 + 8.1)
        let gone = stage.update(inputs, now: t0 + 9.4)
        guard loading.opacity == 0, loading.keep == ["a"], shown.opacity == 1, crossfading.front == "b", crossfading.back == "a",
              melting.opacity == 0, melting.isUp, !gone.isUp, gone.keep.isEmpty
        else { throw SmokeFailure("the crossfade and visibility states are wrong") }

        // The embedded player's page and the ranking (invented results).
        guard let page = YouTubeEmbed.page(videoID: "ahenkSmoke1", start: 12, loops: true, origin: YouTubeEmbed.origin(bundleIdentifier: AppInfo.bundleIdentifier)),
              page.contains(YouTubeEmbed.playerHost), page.contains("origin: 'https://com.sinanmertsener.ahenk'"), page.contains("mute: 1")
        else { throw SmokeFailure("the embedded player's page is wrong") }
        let results = [
            YouTubeVideo(id: "ahenkSmoke1", title: "\(song.track.artist) - \(song.track.title) (Official Audio)", channel: song.track.artist, duration: song.track.duration, isOfficialArtistChannel: true),
            YouTubeVideo(id: "ahenkSmoke2", title: "\(song.track.artist) - \(song.track.title) (Official Video)", channel: song.track.artist, duration: song.track.duration + 4, isOfficialArtistChannel: true),
        ]
        guard VideoRanking.songVideos(results, title: song.track.title, artist: song.track.artist, duration: song.track.duration).map(\.video.id) == ["ahenkSmoke2"] else {
            throw SmokeFailure("the ranking took the audio upload")
        }
        let saved = snapshots.map { ", snapshots in \($0.path)" } ?? ""
        return "\(screens) display(s): a window at the desktop picture's level (\(desktop), icons at \(icons)) on every Space, never clicked; "
            + "\(frames) frames drawn offscreen, a crossfade between two generated pictures; the states through a song; "
            + "the embedded player's page; the official video ranked over the audio\(saved)"
    }

    /// The menu bar's Live Wallpaper switch drives the running controller:
    /// it starts with every display switched off in the in-memory settings
    /// (nothing can appear), offers the demo song's candidates, is turned
    /// off and on by the menu item, and draws its dots above the player.
    static func runSwitch(environment: AppEnvironment, snapshots: URL?) async throws -> String {
        let settings = environment.settings
        let original = settings.wallpaper
        let originalLanguage = settings.general.language
        let controller = environment.wallpaper
        defer {
            controller.stop()
            settings.wallpaper = original
            settings.general.language = originalLanguage
        }
        // The demo song through the pipeline (when no earlier check did).
        if environment.nowPlaying.snapshot == nil {
            environment.services.start(settings: settings)
            environment.nowPlaying.attach(provider: environment.services.hub, artwork: environment.services.artwork, features: environment.services.features)
        }
        settings.wallpaper.disabledDisplays = Set(NSScreen.screens.compactMap(DisplayIdentity.stableID(of:)))
        settings.wallpaper.enabled = true
        settings.wallpaper.selectedVideoID = nil
        controller.start()
        func wait(_ what: String, _ condition: @escaping () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(4)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("\(what) (status \(controller.status))") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait("the demo song's candidates did not arrive") { controller.offer.count >= 3 && controller.phase == .ready }
        let kinds = controller.offer.map(\.kind)
        guard controller.windows.allSatisfy({ !$0.isVisible }) else { throw SmokeFailure("a wallpaper window appeared on a switched-off display") }
        func flip() throws {
            let menu = NSMenu()
            QuickMenu.populate(menu, environment: environment, placement: .menuBar)
            guard let item = menu.items.first(where: { $0.title == QuickToggle.liveWallpaper.title }), let action = item.action else {
                throw SmokeFailure("no Live Wallpaper item in the menu")
            }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        try flip()
        try await wait("the live wallpaper did not turn off") { controller.status == .off }
        try flip()
        try await wait("the live wallpaper did not turn on again") { controller.status != .off }

        // The dots above the player, in both languages.
        let model = environment.desktopPlayer.model
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        var drawn = 0
        for language in AppLanguage.allCases {
            settings.general.language = language
            let size = CGSize(width: PlayerLayout.largeWidth + 2 * PlayerLayout.margin, height: PlayerLayout.pickerHeight + 2 * PlayerLayout.margin)
            let bitmap = try await renderDots(model: model, size: size, language: language)
            if let snapshots, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: snapshots.appendingPathComponent("desktop-wallpaper-dots-\(language.rawValue).png"))
            }
            drawn += 1
        }
        return "the menu's Live Wallpaper item turns the running wallpaper off and on (now \(controller.status)); "
            + "the demo song offers \(kinds.map(\.rawValue).joined(separator: ", ")); every display was switched off, nothing was shown; "
            + "the dots drawn in \(drawn) languages"
    }

    // MARK: Helpers


    private static func media(_ candidate: WallpaperCandidate, look: Int, song: DemoSong, plan: WallpaperPowerPlan, size: CGSize) -> WallpaperMediaView {
        let colors = WallpaperDemo.colors(look: look, palette: song.palette)
        return GeneratedMotionView(candidate: candidate, look: look, colors: colors, plan: plan, frame: CGRect(origin: .zero, size: size))
    }

    /// The view's layer tree drawn into a bitmap; something must be lit and
    /// varied.
    private static func render(_ view: NSView, size: CGSize) throws -> NSBitmapImageRep {
        guard let layer = view.layer,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw SmokeFailure("could not draw the wallpaper offscreen") }
        layer.render(in: context.cgContext)
        context.flushGraphics()
        var levels: [CGFloat] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                if let color = bitmap.colorAt(x: x, y: y) { levels.append(color.brightnessComponent) }
            }
        }
        let lit = levels.filter { $0 > 0.12 }.count
        let spread = (levels.max() ?? 0) - (levels.min() ?? 0)
        guard lit > levels.count / 4, spread > 0.08 else {
            throw SmokeFailure("the wallpaper drew nothing (\(lit) of \(levels.count) samples lit, spread \(String(format: "%.2f", spread)))")
        }
        return bitmap
    }

    /// Mean difference in brightness of two frames of the same size.
    private static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh), by: 8) {
            for x in stride(from: 0, to: min(a.pixelsWide, b.pixelsWide), by: 8) {
                guard let first = a.colorAt(x: x, y: y), let second = b.colorAt(x: x, y: y) else { continue }
                total += abs(Double(first.redComponent - second.redComponent)) + abs(Double(first.greenComponent - second.greenComponent))
                    + abs(Double(first.blueComponent - second.blueComponent))
                count += 3
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    private static func save(_ bitmap: NSBitmapImageRep, _ name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The dots row in an invisible window, glass painted.
    private static func renderDots(model: DesktopPlayerModel, size: CGSize, language: AppLanguage) async throws -> NSBitmapImageRep {
        let root = WallpaperPicker(model: model)
            .padding(PlayerLayout.margin)
            .environment(\.widgetSnapshot, true)
            .environment(\.locale, language.locale())
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.16, green: 0.14, blue: 0.22))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentView = hosting
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.orderFrontRegardless()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(70))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw SmokeFailure("no bitmap for the dots") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var lit = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y), color.brightnessComponent > 0.5 { lit += 1 }
            }
        }
        guard lit > 6 else { throw SmokeFailure("the dots drew nothing") }
        return bitmap
    }
}
