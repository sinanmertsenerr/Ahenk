import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Edge light uniforms")
struct EdgeLightUniformTests {
    @Test("The struct has the shader's size and every member is accounted for")
    func layout() {
        #expect(MemoryLayout<EdgeLightUniforms>.size == EdgeLightUniforms.expectedSize)
        #expect(MemoryLayout<EdgeLightUniforms>.stride == EdgeLightUniforms.expectedSize)
        #expect(EdgeLightUniforms.memberOffsets["colors"] == 224)
        #expect(EdgeLightUniforms.memberOffsets["spectrum"] == 288)
        #expect(EdgeLightUniforms.memberOffsets.count == 31)
    }

    @Test("Uniforms carry the screen, the strip, the look, the colours and the music")
    func building() {
        let shape = EdgeShape.display(width: 1512, height: 982, notch: CGRect(x: 665, y: 950, width: 185, height: 32))
        let look = LightLook(style: .snake, position: .corners, thickness: 12, glow: 0.5, intensity: 0.7, speed: 1.5)
        let metrics = EdgeMetrics(shape: shape, band: look.band)
        var motion = LightMotion()
        motion.advance(to: 1, features: DemoBeat.features(at: 1), speed: 1)
        motion.advance(to: 1.02, features: DemoBeat.features(at: 1.02), speed: 1)
        let strip = CGRect(x: 0, y: 0, width: 1512, height: metrics.band)
        let colors = [SRGBColor("#FF0000"), SRGBColor("#00FF00")]
        let u = EdgeLightUniforms(
            metrics: metrics, strip: strip, pixelScale: 2, look: look, colors: colors, isRainbow: false,
            motion: motion, features: DemoBeat.features(at: 1.02), time: 1.02, opacity: 0.5, quality: .light, seed: 7
        )
        #expect(u.screenSize == SIMD2(1512, 982))
        #expect(u.stripSize == SIMD2(1512, Float(metrics.band)))
        #expect(u.pixelScale == 2 && u.band == Float(metrics.band))
        #expect(u.radii == SIMD4(10, 6, 10, 6))
        #expect(u.notch.x == 665 && u.notch.y == 185 && u.notch.z == 32)
        #expect(u.perimeter.x == Float(metrics.paramRadius) && u.perimeter.w == Float(metrics.perimeter))
        #expect(u.style == LightStyle.snake.shaderIndex && u.position == LightPosition.corners.shaderIndex)
        #expect(u.opacity == 0.5 && u.quality == 0 && u.seed == 7 && u.colorMode == 0)
        #expect(u.color0 == SIMD4(1, 0, 0, 1) && u.color1 == SIMD4(0, 1, 0, 1) && u.color2 == SIMD4(1, 0, 0, 1))
        #expect(u.beat > 0.5 && u.extra.z > 0.5 && u.extra.w == 1)
        #expect(u.spectrum0.x > 0)
    }

    @Test("Silence carries no levels, no notch means a zero notch")
    func silence() {
        let metrics = EdgeMetrics(shape: EdgeShape(width: 800, height: 600), band: 40)
        let u = EdgeLightUniforms(
            metrics: metrics, strip: CGRect(x: 0, y: 0, width: 800, height: 40), pixelScale: 1, look: LightLook(),
            colors: [.white], isRainbow: true, motion: LightMotion(), features: .silence, time: 0, opacity: 2, quality: .full
        )
        #expect(u.energy == 0 && u.beat == 0 && u.bands == .zero && u.spectrum7 == .zero)
        #expect(u.notch == .zero && u.colorMode == 1 && u.opacity == 1)
        #expect(u.beatAges == SIMD4(repeating: LightMotion.noBeatAge))
    }
}
