import AhenkKit
import Foundation
import Metal

/// Matches `EdgeLightUniforms` in EdgeLight.metal (64 bytes).
struct EdgeLightUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var thickness: Float
    var glow: Float
    var intensity: Float
    var beat: Float
    var level: Float
    var colorA: SIMD4<Float>
    var colorB: SIMD4<Float>
}

extension SRGBColor {
    var simd: SIMD4<Float> { SIMD4(Float(red), Float(green), Float(blue), 1) }
}

/// Compiles the edge light shader and renders a few frames offscreen,
/// proving the shader pipeline end to end (`--smoke`).
enum MetalProbe {
    struct Result {
        let deviceName: String
        let compileMilliseconds: Double
        let frames: Int
        let edgeAlpha: UInt8
        let centerAlpha: UInt8
    }

    static func run(frames: [AudioFeatures], palette: Palette, light: LightSettings) throws -> Result {
        precondition(MemoryLayout<EdgeLightUniforms>.stride == 64, "EdgeLightUniforms layout drifted from the shader")
        guard let device = MTLCreateSystemDefaultDevice() else { throw SmokeFailure("No Metal device") }

        let compileStart = Date()
        let library = try MetalShaders.makeLibrary(named: "EdgeLight", device: device)
        let compileMilliseconds = Date().timeIntervalSince(compileStart) * 1000

        guard let vertex = library.makeFunction(name: "edgeLightVertex"),
              let fragment = library.makeFunction(name: "edgeLightFragment")
        else { throw SmokeFailure("Shader functions missing") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let width = 320
        let height = 200
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: textureDescriptor),
              let queue = device.makeCommandQueue()
        else { throw SmokeFailure("Could not create the render target") }

        for (index, features) in frames.enumerated() {
            var uniforms = EdgeLightUniforms(
                resolution: SIMD2(Float(width), Float(height)),
                time: Float(index) / 60,
                thickness: Float(light.thickness),
                glow: Float(light.glow),
                intensity: Float(light.intensity),
                beat: features.beat,
                level: features.level,
                colorA: palette.primary.simd,
                colorB: palette.secondary.simd
            )
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
            else { throw SmokeFailure("Could not encode frame \(index)") }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EdgeLightUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            if texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
                blit.synchronize(resource: texture)
                blit.endEncoding()
            }
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return pixel[3]
        }
        let edge = alpha(x: 1, y: height / 2)
        let center = alpha(x: width / 2, y: height / 2)
        guard edge > 0, edge > center else {
            throw SmokeFailure("Rendered frame is wrong: edge alpha \(edge), centre alpha \(center)")
        }
        return Result(
            deviceName: device.name,
            compileMilliseconds: compileMilliseconds,
            frames: frames.count,
            edgeAlpha: edge,
            centerAlpha: center
        )
    }
}
