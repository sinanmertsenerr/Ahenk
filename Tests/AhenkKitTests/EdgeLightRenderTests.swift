import CoreGraphics
import Foundation
import Metal
import Testing
@testable import AhenkKit

/// Renders the real shader offscreen: every style must draw light, only in
/// the border band, with finite values; the strips must add up to the
/// whole-screen picture; the uniform layout must match the shader.
///
/// Set `AHENK_LIGHT_PREVIEW_DIR=/some/dir` to also write a PNG per style
/// (three moments of the demo beat over a dark desktop) for looking at.
@Suite("Edge light rendering")
struct EdgeLightRenderTests {
    static let shaderURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AhenkApp/Resources/Shaders/EdgeLight.metal")

    static let renderer: EdgeLightRenderer? = {
        guard let source = try? String(contentsOf: shaderURL, encoding: .utf8) else { return nil }
        return try? EdgeLightRenderer(source: source)
    }()

    /// A small notched screen (a MacBook in miniature) and the demo colours.
    static let shape = EdgeShape.display(width: 360, height: 232, notch: CGRect(x: 150, y: 214, width: 60, height: 18))
    static let colors = Palette(colors: [SRGBColor("#0E5E6F"), SRGBColor("#FF7A6B"), SRGBColor("#FFD9A0")]).vivid

    /// Light that would survive 8-bit output (half a step); smaller values
    /// at the very rim are float rounding, not light.
    static let visible: Float = 0.5 / 255

    /// The uniforms for a whole-screen strip at `time` seconds into the demo beat.
    static func frame(
        style: LightStyle, position: LightPosition = .allEdges, at time: Double, shape: EdgeShape = shape,
        pixelScale: Double = 1, strip: CGRect? = nil, quality: LightQuality = .full, rainbow: Bool = false
    ) -> (EdgeLightUniforms, EdgeMetrics) {
        let look = LightLook(style: style, position: position, thickness: 8, glow: 0.6, intensity: 0.9, speed: 1, detail: 0.8)
        let metrics = EdgeMetrics(shape: shape, band: look.band)
        var motion = LightMotion()
        var t = 0.0
        while t < time {
            motion.advance(to: 100 + t, features: DemoBeat.features(at: t), speed: look.speed)
            t += 1.0 / 60
        }
        motion.advance(to: 100 + time, features: DemoBeat.features(at: time), speed: look.speed)
        let uniforms = EdgeLightUniforms(
            metrics: metrics, strip: strip ?? CGRect(x: 0, y: 0, width: shape.width, height: shape.height),
            pixelScale: pixelScale, look: look, colors: colors, isRainbow: rainbow, motion: motion,
            features: DemoBeat.features(at: time), time: 100 + time, opacity: 1, quality: quality, seed: 3
        )
        return (uniforms, metrics)
    }

    @Test("The uniform struct matches the shader byte for byte")
    func layoutMatchesShader() throws {
        let renderer = try #require(Self.renderer, "EdgeLight.metal did not compile")
        let layout = try renderer.shaderUniformLayout()
        #expect(MemoryLayout<EdgeLightUniforms>.size == EdgeLightUniforms.expectedSize)
        #expect(layout.size == MemoryLayout<EdgeLightUniforms>.size)
        #expect(Set(layout.members.keys) == Set(EdgeLightUniforms.memberOffsets.keys))
        for (name, offset) in EdgeLightUniforms.memberOffsets {
            #expect(layout.members[name] == offset, "\(name): Swift \(offset), shader \(layout.members[name] ?? -1)")
        }
    }

    @Test("Every style draws finite light, only inside the band", arguments: LightStyle.allCases)
    func styleRendersInsideTheBand(style: LightStyle) throws {
        let renderer = try #require(Self.renderer, "EdgeLight.metal did not compile")
        var sheet: [LightImage] = []
        for time in [0.6, 2.25, 5.1] {
            let (uniforms, metrics) = Self.frame(style: style, at: time)
            let image = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: uniforms)
            #expect(image.isWellFormed, "\(style) at \(time) s has values outside 0…1 or not finite")
            #expect(image.maximumAlpha > 0.2, "\(style) at \(time) s is (almost) empty: max alpha \(image.maximumAlpha)")
            let field = EdgeField(metrics: metrics)
            var outside = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    guard image.pixel(x: x, y: y).w > Self.visible else { continue }
                    let px = Double(x) + 0.5
                    let py = Self.shape.height - (Double(y) + 0.5)
                    if !field.mayLight(x: px, y: py, position: .allEdges, pixel: 1) { outside += 1 }
                }
            }
            #expect(outside == 0, "\(style) at \(time) s lights \(outside) pixels outside the band")
            sheet.append(image)
        }
        try Self.writePreview(sheet, name: style.rawValue)
    }

    @Test("Position settings keep the light where they say", arguments: [LightPosition.bottom, .top, .corners])
    func positionMasks(position: LightPosition) throws {
        let renderer = try #require(Self.renderer, "EdgeLight.metal did not compile")
        let (uniforms, metrics) = Self.frame(style: .glow, position: position, at: 1.0)
        let image = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: uniforms)
        let field = EdgeField(metrics: metrics)
        #expect(image.isWellFormed)
        #expect(image.maximumAlpha > 0.2)
        var outside = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixel(x: x, y: y).w > Self.visible {
                if !field.mayLight(x: Double(x) + 0.5, y: Self.shape.height - (Double(y) + 0.5), position: position, pixel: 1) {
                    outside += 1
                }
            }
        }
        #expect(outside == 0, "\(position) lights \(outside) pixels it should not")
        let top = image.pixel(x: image.width / 4, y: 1).w
        let bottom = image.pixel(x: image.width / 4, y: image.height - 2).w
        switch position {
        case .bottom:
            #expect(bottom > 0.2 && top == 0)
        case .top:
            #expect(top > 0.2 && bottom == 0)
        case .corners:
            #expect(image.pixel(x: 2, y: image.height - 3).w > 0.1)
            #expect(image.pixel(x: image.width / 2 - 40, y: image.height - 2).w == 0)
        case .allEdges:
            break
        }
        try Self.writePreview([image], name: "position-\(position.rawValue)")
    }

    @Test("The atlas, turned back into strips, adds up to the whole-screen picture", arguments: LightPosition.allCases)
    func atlasMatchesTheWholeScreen(position: LightPosition) throws {
        let renderer = try #require(Self.renderer, "EdgeLight.metal did not compile")
        let scale = 2.0
        let (whole, metrics) = Self.frame(style: .sparkles, position: position, at: 1.3, pixelScale: scale)
        let full = try renderer.renderImage(width: Int(Self.shape.width * scale), height: Int(Self.shape.height * scale), uniforms: whole)
        let atlas = EdgeAtlas(strips: EdgeLayout.strips(for: metrics, position: position), scale: scale)
        let draws = atlas.slots.map { slot -> (uniforms: EdgeLightUniforms, slot: EdgeAtlasSlot) in
            var uniforms = whole
            uniforms.stripOrigin = SIMD2(Float(slot.strip.minX), Float(slot.strip.minY))
            uniforms.stripSize = SIMD2(Float(slot.strip.width), Float(slot.strip.height))
            uniforms.atlasOrigin = SIMD2(Float(slot.pixels.minX), Float(slot.pixels.minY))
            uniforms.rotated = slot.isRotated ? 1 : 0
            return (uniforms, slot)
        }
        let image = try renderer.renderAtlasImage(atlas, draws: draws)
        #expect(image.isWellFormed)
        var covered = [Bool](repeating: false, count: full.width * full.height)
        for slot in atlas.slots {
            // Every pixel of the strip on the screen, found in its slot.
            let originX = Int(slot.strip.minX * scale)
            let originY = Int((Self.shape.height - slot.strip.maxY) * scale)
            let width = Int(slot.strip.width * scale)
            let height = Int(slot.strip.height * scale)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (originY + y) * full.width + originX + x
                    #expect(!covered[index], "strips overlap at \(originX + x), \(originY + y)")
                    covered[index] = true
                    // Screen pixel (x, y) from the strip's top-left; a turned slot runs
                    // from the strip's bottom end along its row, its top edge the strip's left.
                    let ax = Int(slot.pixels.minX) + (slot.isRotated ? (height - 1 - y) : x)
                    let ay = Int(slot.pixels.minY) + (slot.isRotated ? x : y)
                    let delta: SIMD4<Float> = image.pixel(x: ax, y: ay) - full.pixel(x: originX + x, y: originY + y)
                    let difference = max(abs(delta.x), abs(delta.y), abs(delta.z), abs(delta.w))
                    if difference > 0.002 {
                        Issue.record("\(slot.place) differs from the whole screen at \(x), \(y) by \(difference)")
                        return
                    }
                }
            }
        }
        // Gutters stay transparent.
        if let first = atlas.slots.first, Int(first.pixels.maxY) + 1 < image.height {
            #expect(image.pixel(x: 0, y: Int(first.pixels.maxY)).w == 0)
        }
        // Every lit pixel of the whole screen belongs to a strip.
        for y in 0..<full.height {
            for x in 0..<full.width where full.pixel(x: x, y: y).w > Self.visible && !covered[y * full.width + x] {
                Issue.record("lit pixel \(x), \(y) is in no strip")
                return
            }
        }
    }

    @Test("Opacity 0 draws nothing; light quality still draws")
    func opacityAndQuality() throws {
        let renderer = try #require(Self.renderer, "EdgeLight.metal did not compile")
        var (uniforms, _) = Self.frame(style: .fire, at: 1.0, quality: .light)
        let light = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: uniforms)
        #expect(light.maximumAlpha > 0.2)
        uniforms.opacity = 0
        let none = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: uniforms)
        #expect(none.maximumAlpha == 0)
        let (rainbow, _) = Self.frame(style: .glow, at: 1.0, rainbow: true)
        let colorful = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: rainbow)
        #expect(colorful.isWellFormed && colorful.maximumAlpha > 0.2)
    }

    @Test("Silence leaves a calm light, the beat makes it brighter")
    func beatBrightens() throws {
        let renderer = try #require(Self.renderer, "EdgeLight.metal did not compile")
        let (onBeat, metrics) = Self.frame(style: .glow, at: 2.02)
        var quiet = onBeat
        quiet.extra.z = 0
        quiet.thickness = onBeat.thickness
        let loud = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: onBeat)
        let calm = try renderer.renderImage(width: Int(Self.shape.width), height: Int(Self.shape.height), uniforms: quiet)
        #expect(onBeat.extra.z > 0.5, "the demo beat at 2.02 s is just after a beat")
        let y = Int(Self.shape.height) - 4
        #expect(loud.pixel(x: 40, y: y).w > calm.pixel(x: 40, y: y).w)
        #expect(metrics.band > 0)
    }

    // MARK: Previews

    static func writePreview(_ images: [LightImage], name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AHENK_LIGHT_PREVIEW_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, image) in images.enumerated() {
            guard let png = image.pngData(over: SRGBColor("#1E2230")) else { continue }
            try png.write(to: directory.appendingPathComponent("\(name)-\(index).png"))
        }
    }
}
