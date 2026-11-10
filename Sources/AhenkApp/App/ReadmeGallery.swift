import AhenkKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `--smoke --snapshots <dir> --gallery <dir>`: the README's pictures, made
/// only from Ahenk's own views drawn offscreen with the demo's invented
/// songs and generated covers (never a capture of the screen):
///
/// - `desktop-<lang>.jpg`: the generated dusk backdrop, the edge light
///   around the whole picture and the widgets at their default places;
/// - `light-styles.jpg`: every edge light style, named;
/// - `lyrics-styles.jpg`: the eight lyric styles while a line is sung;
/// - `effects-and-alignment.jpg`, `guide.jpg`, `settings.jpg`: panels and
///   windows, from the snapshots the other checks wrote.
///
/// Runs last, after the checks that write those snapshots.
@MainActor
enum ReadmeGallery {
    /// The picture's "screen", in points (a 14-inch MacBook's default).
    static let screen = CGSize(width: 1512, height: 982)
    /// Pixels per point while composing; the JPEGs are scaled down.
    static let scale: CGFloat = 2
    static let outputWidth = 1600
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func run(environment: AppEnvironment, snapshots: URL?, output: URL) async throws -> String {
        guard let snapshots else { throw SmokeFailure("--gallery needs --snapshots (it reuses their pictures)") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = environment.settings
        let originalLanguage = settings.general.language
        defer { settings.general.language = originalLanguage }

        var written: [String] = []
        let renderer = try EdgeLightRenderer(source: MetalShaders.source(named: "EdgeLight"))
        let scene = try await DesktopScene.prepare(environment: environment)
        defer { scene.stop() }
        for language in AppLanguage.allCases {
            settings.general.language = language
            let image = try await scene.render(renderer: renderer, language: language)
            try writeJPEG(image, to: output.appendingPathComponent("desktop-\(language.rawValue).jpg"))
            written.append("desktop-\(language.rawValue).jpg")
        }
        settings.general.language = .english
        try writeJPEG(try lightStyles(renderer: renderer, palette: scene.palette), to: output.appendingPathComponent("light-styles.jpg"))
        written.append("light-styles.jpg")
        try writeJPEG(try lyricStyles(from: snapshots), to: output.appendingPathComponent("lyrics-styles.jpg"))
        written.append("lyrics-styles.jpg")
        let sheets: [(String, [String])] = [
            ("effects-and-alignment.jpg", ["desktop-lyrics-effects-en.png", "desktop-lyrics-align-en.png"]),
            ("guide.jpg", ["onboarding-welcome-en.png", "onboarding-listening-en.png"]),
            ("settings.jpg", ["settings-light-en.png", "settings-sound-en.png"]),
        ]
        for (name, files) in sheets {
            let pictures = try files.map { try load(snapshots.appendingPathComponent($0)) }
            try writeJPEG(try sideBySide(pictures, cropLeft: name == "settings.jpg" ? 0.28 : 0), to: output.appendingPathComponent(name))
            written.append(name)
        }
        return "\(written.count) pictures in \(output.path): \(written.joined(separator: ", "))"
    }

    // MARK: The desktop

    /// The widgets of a running demo, drawn without their windows.
    @MainActor
    final class DesktopScene {
        let environment: AppEnvironment
        let model: DesktopPlayerModel
        let clock: ClockModel
        var palette: Palette = .neutral

        private init(environment: AppEnvironment, model: DesktopPlayerModel) {
            self.environment = environment
            self.model = model
            clock = ClockModel(settings: environment.settings)
        }

        static func prepare(environment: AppEnvironment) async throws -> DesktopScene {
            guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
            let services = environment.services
            let settings = environment.settings
            services.start(settings: settings)
            let nowPlaying = environment.nowPlaying
            nowPlaying.attach(provider: services.hub, artwork: services.artwork, features: services.features)
            environment.audio.start(hub: services.hub, settings: settings)
            settings.lyrics.enabled = true
            environment.lyrics.start()
            try await wait("the demo song and its cover") { nowPlaying.snapshot != nil && nowPlaying.artwork != nil }
            try await wait("the demo song's lyrics") { environment.lyrics.phase == .synced }
            // The second line, a second and a half into it: a line being sung.
            if let line = environment.lyrics.timeline?.lines.dropFirst().first {
                await demo.perform(.seek(to: line.start + 1.5))
                try await wait("the seek") { abs((nowPlaying.snapshot?.elapsed(at: Date()) ?? 0) - line.start - 1.5) < 1 }
            }
            let model = DesktopPlayerModel(settings: settings, nowPlaying: nowPlaying, services: services, demo: demo)
            model.start()
            model.setPresented(true)
            try await wait("the artist's albums") { model.albums.value?.isEmpty == false }
            // Covers arrive at the size shown.
            try await Task.sleep(for: .milliseconds(600))
            let scene = DesktopScene(environment: environment, model: model)
            scene.palette = nowPlaying.artwork?.palette ?? .neutral
            return scene
        }

        func stop() {
            model.stop()
            environment.lyrics.stop()
        }

        func render(renderer: EdgeLightRenderer, language: AppLanguage) async throws -> CGImage {
            let settings = environment.settings
            // A running clock follows the language by itself; this one is
            // never started.
            clock.refresh()
            let visible = CGRect(x: 0, y: 0, width: ReadmeGallery.screen.width, height: ReadmeGallery.screen.height - 33)
            let clockSize = NSHostingView(rootView: ClockWidget(clock: clock, model: model, settings: settings.player, measuring: true)).fittingSize
            let margin = ContinuePlayingWidget.margin
            let sizes: [DesktopWidget: CGSize] = [
                .clock: CGSize(width: ceil(clockSize.width), height: ceil(clockSize.height)),
                .continuePlaying: CGSize(width: DesktopPlayerController.listSize.width + 2 * margin, height: DesktopPlayerController.listSize.height + 2 * margin),
                .player: PlayerLayout.size(model.layoutState),
                .lyrics: LyricsLayout.widgetSize(textScale: settings.lyrics.textScale, showsCover: settings.lyrics.showAlbumArt),
            ]
            let frames = WidgetPlacement.defaultFrames(sizes: sizes, in: visible, lyrics: settings.lyrics.position)
            let views: [(DesktopWidget, AnyView)] = [
                (.clock, AnyView(ClockWidget(clock: clock, model: model, settings: settings.player))),
                (.continuePlaying, AnyView(ContinuePlayingWidget(model: model))),
                (.player, AnyView(PlayerWidget(model: model))),
                (.lyrics, AnyView(LyricsWidget(
                    lyrics: environment.lyrics, player: model, power: environment.power, settings: settings
                ))),
            ]

            let context = ReadmeGallery.canvas(width: ReadmeGallery.screen.width, height: ReadmeGallery.screen.height)
            let full = CGRect(origin: .zero, size: CGSize(width: context.width, height: context.height))
            if let backdrop = DemoStage.backdropImage(size: ReadmeGallery.screen, scale: ReadmeGallery.scale)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(backdrop, in: full)
            }
            context.draw(try light(renderer: renderer, size: ReadmeGallery.screen, style: .glow, time: 3.1), in: full)
            for (widget, view) in views {
                guard let frame = frames[widget] else { continue }
                let root = view
                    .environment(\.widgetSnapshot, true)
                    .environment(\.coverImages, model.images)
                    .environment(\.locale, language.locale())
                    .environment(\.colorScheme, .dark)
                let bitmap = try await OffscreenRender.bitmap(of: root, size: frame.size, background: nil, passes: 6)
                guard let image = bitmap.cgImage else { continue }
                context.draw(image, in: CGRect(
                    x: frame.minX * ReadmeGallery.scale, y: frame.minY * ReadmeGallery.scale,
                    width: frame.width * ReadmeGallery.scale, height: frame.height * ReadmeGallery.scale
                ))
            }
            guard let image = context.makeImage() else { throw SmokeFailure("the desktop picture could not be made") }
            return image
        }

        /// One frame of the edge light around a whole picture.
        private func light(renderer: EdgeLightRenderer, size: CGSize, style: LightStyle, time: Double) throws -> CGImage {
            try ReadmeGallery.lightImage(renderer: renderer, shape: EdgeShape.display(width: size.width, height: size.height, notch: nil),
                                         style: style, palette: palette, thickness: 14, time: time, pixelScale: ReadmeGallery.scale, glow: 0.85)
        }

        private static func wait(_ what: String, seconds: Double = 6, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("no \(what) within \(Int(seconds)) s") }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    // MARK: Light and lyric styles

    static func lightImage(
        renderer: EdgeLightRenderer, shape: EdgeShape, style: LightStyle, palette: Palette, thickness: Double, time: Double, pixelScale: CGFloat,
        glow: Double = 0.6
    ) throws -> CGImage {
        let look = LightLook(style: style, position: .allEdges, thickness: thickness, glow: glow, intensity: 0.95, speed: 1, detail: 0.8)
        let metrics = EdgeMetrics(shape: shape, band: look.band)
        var motion = LightMotion()
        var t = 0.0
        while t < time {
            motion.advance(to: 100 + t, features: DemoBeat.features(at: t), speed: 1)
            t += 1.0 / 60
        }
        motion.advance(to: 100 + time, features: DemoBeat.features(at: time), speed: 1)
        let uniforms = EdgeLightUniforms(
            metrics: metrics, strip: CGRect(x: 0, y: 0, width: shape.width, height: shape.height), pixelScale: Double(pixelScale),
            look: look, colors: LightColors(colors: palette.vivid).slots, isRainbow: style == .rainbow, motion: motion,
            features: DemoBeat.features(at: time), time: 100 + time, opacity: 1, quality: .full, seed: 3
        )
        let image = try renderer.renderImage(
            width: Int((shape.width * pixelScale).rounded()), height: Int((shape.height * pixelScale).rounded()), uniforms: uniforms
        )
        return try cgImage(of: image)
    }

    /// Every light style on a miniature screen, named, four in a row.
    static func lightStyles(renderer: EdgeLightRenderer, palette: Palette) throws -> CGImage {
        let tile = CGSize(width: 360, height: 232)
        let label: CGFloat = 34, gap: CGFloat = 22, columns = 4
        let styles = LightStyle.allCases
        let rows = (styles.count + columns - 1) / columns
        let width = gap + CGFloat(columns) * (tile.width + gap)
        let height = gap + CGFloat(rows) * (tile.height + label + gap)
        let context = canvas(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let shape = EdgeShape.display(width: tile.width, height: tile.height, notch: CGRect(x: 150, y: 214, width: 60, height: 18))
        for (index, style) in styles.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (tile.width + gap)
            let top = height - gap - CGFloat(row) * (tile.height + label + gap)
            let rect = CGRect(x: x, y: top - tile.height, width: tile.width, height: tile.height)
            let screenRect = rect.scaled(by: scale)
            context.saveGState()
            context.addPath(CGPath(roundedRect: screenRect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
            context.clip()
            context.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.19, alpha: 1))
            context.fill(screenRect)
            context.draw(try lightImage(renderer: renderer, shape: shape, style: style, palette: palette, thickness: 8, time: 2.25, pixelScale: scale), in: screenRect)
            context.restoreGState()
            draw(style.title, in: CGRect(x: x, y: rect.minY - label, width: tile.width, height: label - 6), size: 17, context: context)
        }
        guard let image = context.makeImage() else { throw SmokeFailure("the light styles could not be drawn") }
        return image
    }

    /// The eight lyric styles while a line is sung (from the lyrics check's
    /// snapshots), two in a row, named.
    static func lyricStyles(from snapshots: URL) throws -> CGImage {
        let pictures = try LyricStyle.allCases.map { (style: $0, image: try load(snapshots.appendingPathComponent("lyrics-\($0.rawValue)-singing-en.png"))) }
        guard let first = pictures.first?.image else { throw SmokeFailure("no lyric snapshots") }
        let tile = CGSize(width: CGFloat(first.width) / scale, height: CGFloat(first.height) / scale)
        let label: CGFloat = 36, gap: CGFloat = 20, columns = 2
        let rows = (pictures.count + columns - 1) / columns
        let width = gap + CGFloat(columns) * (tile.width + gap)
        let height = gap + CGFloat(rows) * (tile.height + label + gap)
        let context = canvas(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for (index, picture) in pictures.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (tile.width + gap)
            let top = height - gap - CGFloat(row) * (tile.height + label + gap)
            let rect = CGRect(x: x, y: top - tile.height, width: tile.width, height: tile.height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect.scaled(by: scale), cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
            context.clip()
            context.draw(picture.image, in: rect.scaled(by: scale))
            context.restoreGState()
            draw(picture.style.title, in: CGRect(x: x, y: rect.minY - label, width: tile.width, height: label - 8), size: 19, context: context)
        }
        guard let image = context.makeImage() else { throw SmokeFailure("the lyric styles could not be drawn") }
        return image
    }

    // MARK: Helpers

    /// Pictures next to each other on a dark ground; `cropLeft` cuts that
    /// share off each picture's left side (the Settings sidebar, which
    /// glass leaves blank in snapshots).
    static func sideBySide(_ pictures: [CGImage], cropLeft: CGFloat) throws -> CGImage {
        let cropped = pictures.compactMap { picture -> CGImage? in
            guard cropLeft > 0 else { return picture }
            let x = Int(CGFloat(picture.width) * cropLeft)
            return picture.cropping(to: CGRect(x: x, y: 0, width: picture.width - x, height: picture.height))
        }
        let gap = 24 * scale
        let height = (cropped.map { CGFloat($0.height) }.max() ?? 0) + 2 * gap
        let width = cropped.reduce(gap) { $0 + CGFloat($1.width) + gap }
        guard let context = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SmokeFailure("no canvas") }
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = gap
        for picture in cropped {
            let rect = CGRect(x: x, y: height - gap - CGFloat(picture.height), width: CGFloat(picture.width), height: CGFloat(picture.height))
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
            context.clip()
            context.draw(picture, in: rect)
            context.restoreGState()
            x += CGFloat(picture.width) + gap
        }
        guard let image = context.makeImage() else { throw SmokeFailure("the sheet could not be drawn") }
        return image
    }

    /// A canvas of `width` × `height` points at `scale`.
    static func canvas(width: CGFloat, height: CGFloat) -> CGContext {
        let context = CGContext(
            data: nil, width: Int((width * scale).rounded()), height: Int((height * scale).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        return context
    }

    /// A centred, white caption (points; the context is in pixels).
    static func draw(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * scale, weight: .medium),
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: attributes).draw(in: rect.scaled(by: scale))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SmokeFailure("\(url.lastPathComponent) is missing (run with --snapshots)") }
        return image
    }

    /// The light's premultiplied float pixels as an 8-bit image.
    static func cgImage(of light: LightImage) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: light.width * light.height * 4)
        for index in 0..<(light.width * light.height) {
            let alpha = max(0, min(1, light.pixels[index * 4 + 3]))
            for channel in 0..<3 {
                // Premultiplied colour may sit a little above alpha (the
                // light brightens what is under it); keep it within 0…1.
                let value = max(0, min(1, light.pixels[index * 4 + channel]))
                bytes[index * 4 + channel] = UInt8((value * 255).rounded())
            }
            bytes[index * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: light.width, height: light.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: light.width * 4,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { throw SmokeFailure("the light frame could not be converted") }
        return image
    }

    /// Scales `image` to the README's width and writes it as a JPEG.
    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let width = min(outputWidth, image.width)
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw SmokeFailure("no canvas for \(url.lastPathComponent)") }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw SmokeFailure("\(url.lastPathComponent) could not be written") }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SmokeFailure("\(url.lastPathComponent) could not be written") }
    }
}

private extension CGRect {
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}
