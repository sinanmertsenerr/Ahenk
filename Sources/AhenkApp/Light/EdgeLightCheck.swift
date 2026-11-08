import AhenkKit
import AppKit
import Metal

/// `--smoke` checks of the edge light, all offscreen: nothing appears on
/// any screen.
@MainActor
enum EdgeLightCheck {
    /// Light that survives 8-bit output (half a step).
    static let visible: Float = 0.5 / 255

    /// Compiles the bundled shader and compares the uniform struct with the
    /// shader's own layout.
    static func compileAndCompare() throws -> (EdgeLightRenderer, String) {
        let renderer = try EdgeLightRenderer(source: MetalShaders.source(named: "EdgeLight"))
        let layout = try renderer.shaderUniformLayout()
        guard layout.size == MemoryLayout<EdgeLightUniforms>.size else {
            throw SmokeFailure("uniforms are \(MemoryLayout<EdgeLightUniforms>.size) bytes in Swift, \(layout.size) in the shader")
        }
        for (name, offset) in EdgeLightUniforms.memberOffsets where layout.members[name] != offset {
            throw SmokeFailure("uniform \(name) is at \(offset) in Swift, \(layout.members[name] ?? -1) in the shader")
        }
        let detail = "\(renderer.device.name): compiled EdgeLight.metal in \(Int(renderer.compileMilliseconds.rounded())) ms; "
            + "\(layout.members.count) uniforms (\(layout.size) bytes) match the shader"
        return (renderer, detail)
    }

    /// Every style at three moments of the demo beat on a miniature notched
    /// screen: finite values, real light, and nothing outside the band.
    /// Also each position setting, and one frame drawn into the strip layers
    /// of a window that is never shown.
    static func run(renderer: EdgeLightRenderer, palette: Palette, snapshots: URL?) throws -> String {
        let shape = EdgeShape.display(width: 360, height: 232, notch: CGRect(x: 150, y: 214, width: 60, height: 18))
        let colors = LightColors(colors: palette.vivid).slots
        let started = ContinuousClock.now
        var frames = 0
        for style in LightStyle.allCases {
            var sheet: [LightImage] = []
            for time in [0.6, 2.25, 5.1] {
                let image = try render(renderer, style: style, position: .allEdges, shape: shape, colors: colors, at: time)
                frames += 1
                try validate(image, style: style, position: .allEdges, shape: shape, time: time)
                sheet.append(image)
            }
            if let snapshots, let png = LightImage.row(sheet, gap: 8).pngData(over: SRGBColor("#1E2230")) {
                try png.write(to: snapshots.appendingPathComponent("light-\(style.rawValue).png"))
            }
        }
        for position in LightPosition.allCases where position != .allEdges {
            let image = try render(renderer, style: .glow, position: position, shape: shape, colors: colors, at: 1)
            try validate(image, style: .glow, position: position, shape: shape, time: 1)
            frames += 1
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let strips = try drawIntoStrips(renderer: renderer, colors: colors)
        return "\(LightStyle.allCases.count) styles and \(LightPosition.allCases.count - 1) positions: \(frames) frames rendered offscreen "
            + "in \(Int(milliseconds.rounded())) ms, finite, lit only inside the band; \(strips)"
    }

    private static func render(
        _ renderer: EdgeLightRenderer, style: LightStyle, position: LightPosition, shape: EdgeShape,
        colors: [SRGBColor], at time: Double
    ) throws -> LightImage {
        let look = LightLook(style: style, position: position, thickness: 8, glow: 0.6, intensity: 0.9, speed: 1, detail: 0.8)
        let metrics = EdgeMetrics(shape: shape, band: look.band)
        var motion = LightMotion()
        var t = 0.0
        while t < time {
            motion.advance(to: 100 + t, features: DemoBeat.features(at: t), speed: 1)
            t += 1.0 / 60
        }
        motion.advance(to: 100 + time, features: DemoBeat.features(at: time), speed: 1)
        let uniforms = EdgeLightUniforms(
            metrics: metrics, strip: CGRect(x: 0, y: 0, width: shape.width, height: shape.height), pixelScale: 1,
            look: look, colors: colors, isRainbow: false, motion: motion, features: DemoBeat.features(at: time),
            time: 100 + time, opacity: 1, quality: .full, seed: 3
        )
        return try renderer.renderImage(width: Int(shape.width), height: Int(shape.height), uniforms: uniforms)
    }

    private static func validate(_ image: LightImage, style: LightStyle, position: LightPosition, shape: EdgeShape, time: Double) throws {
        let what = "\(style.rawValue) (\(position.rawValue)) at \(time) s"
        guard image.isWellFormed else { throw SmokeFailure("\(what) has values that are not finite or outside 0…1") }
        guard image.maximumAlpha > 0.2 else { throw SmokeFailure("\(what) is empty (max alpha \(image.maximumAlpha))") }
        let look = LightLook(style: style, position: position, thickness: 8, glow: 0.6, intensity: 0.9, speed: 1, detail: 0.8)
        let field = EdgeField(metrics: EdgeMetrics(shape: shape, band: look.band))
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixel(x: x, y: y).w > visible {
                let px = Double(x) + 0.5
                let py = shape.height - (Double(y) + 0.5)
                guard field.mayLight(x: px, y: py, position: position, pixel: 1) else {
                    throw SmokeFailure("\(what) lights \(x), \(y), outside the band")
                }
            }
        }
    }

    /// The real path: a light window for the main screen (never ordered
    /// in), its strip layers laid out for the default look, one frame drawn
    /// into the screen's atlas and shown on every strip layer.
    private static func drawIntoStrips(renderer: EdgeLightRenderer, colors: [SRGBColor]) throws -> String {
        guard let nsScreen = NSScreen.main ?? NSScreen.screens.first, let screen = LightScreen(nsScreen) else {
            throw SmokeReport.Skip("no screen")
        }
        let look = LightLook(settings: LightSettings())
        let metrics = EdgeMetrics(shape: screen.shape, band: look.band)
        let layout = EdgeLayout.strips(for: metrics, position: .allEdges)
        let overlay = EdgeLightOverlay(screen: screen)
        defer { overlay.close() }
        overlay.layout(layout, resolutionScale: 1)
        let atlas = overlay.atlas
        guard atlas.slots.count == layout.count, overlay.strips.count == layout.count else {
            throw SmokeFailure("\(overlay.strips.count) strip layers for \(layout.count) strips")
        }
        guard let ring = SurfaceRing(device: renderer.device, width: atlas.width, height: atlas.height),
              let (surface, texture) = ring.acquire(),
              let commands = renderer.queue.makeCommandBuffer()
        else { throw SmokeFailure("no atlas surface of \(atlas.width)×\(atlas.height)") }
        let draws = atlas.slots.map { slot in
            (uniforms: EdgeLightUniforms(
                metrics: metrics, strip: slot.strip, pixelScale: atlas.scale, look: look, colors: colors, isRainbow: false,
                motion: LightMotion(), features: DemoBeat.features(at: 1), time: 1, opacity: 1, quality: .full,
                seed: screen.seed, slot: slot
            ), slot: slot)
        }
        try renderer.encode(atlas: draws, into: texture, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for strip in overlay.strips { strip.layer.contents = surface }
        CATransaction.commit()
        let drawn = atlas.slots.count
        let pixels = atlas.slots.reduce(0) { $0 + Int($1.pixels.width * $1.pixels.height) }
        let share = EdgeLayout.area(of: layout) / (screen.frame.width * screen.frame.height)
        return "\(screen.name) \(Int(screen.frame.width))×\(Int(screen.frame.height))\(screen.shape.notch == nil ? "" : " with a notch"): "
            + "\(drawn) strips drawn in one \(atlas.width)×\(atlas.height) atlas (\(pixels / 1000) k pixels, \(Int((share * 100).rounded())) % of the screen)"
    }
}

extension LightImage {
    /// `images` side by side (same height), `gap` transparent pixels apart.
    static func row(_ images: [LightImage], gap: Int) -> LightImage {
        guard let height = images.map(\.height).max() else { return LightImage(width: 1, height: 1, pixels: [0, 0, 0, 0]) }
        let width = images.reduce(0) { $0 + $1.width } + gap * max(0, images.count - 1)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var x0 = 0
        for image in images {
            for y in 0..<image.height {
                let source = y * image.width * 4
                let target = (y * width + x0) * 4
                pixels.replaceSubrange(target..<(target + image.width * 4), with: image.pixels[source..<(source + image.width * 4)])
            }
            x0 += image.width + gap
        }
        return LightImage(width: width, height: height, pixels: pixels)
    }
}
