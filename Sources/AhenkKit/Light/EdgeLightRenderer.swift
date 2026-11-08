import CoreGraphics
import Foundation
import ImageIO
import Metal
import os
import UniformTypeIdentifiers

/// Compiles the edge light shader once and draws it: into the screens'
/// strip layers (the app's render thread), the Settings previews, and
/// offscreen images for the tests, `--smoke` and snapshots.
///
/// One instance is shared by everything that draws the light: one device,
/// one command queue, one library and one pipeline per pixel format.
/// Thread-safe; encoding happens on whichever thread owns the command
/// buffer.
public final class EdgeLightRenderer: Sendable {
    public enum RenderError: Error, CustomStringConvertible {
        case noDevice
        case missingFunction(String)
        case encoding(String)

        public var description: String {
            switch self {
            case .noDevice: "No Metal device"
            case .missingFunction(let name): "Shader function \(name) is missing"
            case .encoding(let what): "Could not \(what)"
            }
        }
    }

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    /// How long compiling the shader source took.
    public let compileMilliseconds: Double
    private let vertex: MTLFunction
    private let fragment: MTLFunction
    private let pipelines = OSAllocatedUnfairLock<[UInt: MTLRenderPipelineState]>(initialState: [:])

    public static let vertexName = "edgeLightVertex"
    public static let fragmentName = "edgeLightFragment"

    /// Compiles `source` (EdgeLight.metal). Takes a few hundred
    /// milliseconds the first time on a Mac, about a millisecond once
    /// Metal's shader cache has it: create it off the main thread.
    public init(source: String, device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.encoding("create a command queue") }
        queue.label = "Ahenk edge light"
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        let started = ContinuousClock.now
        let library = try device.makeLibrary(source: source, options: options)
        let elapsed = started.duration(to: .now)
        compileMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        guard let vertex = library.makeFunction(name: Self.vertexName) else { throw RenderError.missingFunction(Self.vertexName) }
        guard let fragment = library.makeFunction(name: Self.fragmentName) else { throw RenderError.missingFunction(Self.fragmentName) }
        self.device = device
        self.queue = queue
        self.library = library
        self.vertex = vertex
        self.fragment = fragment
    }

    /// The pipeline for drawing into `format` (built once per format).
    public func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = pipelines.withLock({ $0[format.rawValue] }) { return cached }
        let state = try device.makeRenderPipelineState(descriptor: descriptor(for: format))
        pipelines.withLock { $0[format.rawValue] = state }
        return state
    }

    private func descriptor(for format: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Edge light (\(format.rawValue))"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // Every strip is cleared and drawn whole by one triangle: no blending.
        descriptor.colorAttachments[0].pixelFormat = format
        return descriptor
    }

    /// Byte offsets of the uniform struct's members as the compiled shader
    /// lays them out, by member name, plus its total size.
    public func shaderUniformLayout() throws -> (members: [String: Int], size: Int) {
        var reflection: MTLRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(
            descriptor: descriptor(for: .bgra8Unorm), options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection
        )
        guard let binding = reflection?.fragmentBindings.first(where: { $0.type == .buffer && $0.index == 0 }) as? MTLBufferBinding,
              let type = binding.bufferStructType
        else { throw RenderError.encoding("read the uniform layout from the shader") }
        var members: [String: Int] = [:]
        for member in type.members { members[member.name] = member.offset }
        return (members, binding.bufferDataSize)
    }

    // MARK: Drawing

    /// Encodes one strip: draws every pixel of `texture` (no clear needed).
    public func encode(_ uniforms: EdgeLightUniforms, into texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.encoding("start a render pass")
        }
        encoder.setRenderPipelineState(try pipeline(for: texture.pixelFormat))
        var values = uniforms
        encoder.setFragmentBytes(&values, length: MemoryLayout<EdgeLightUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws `uniforms` into a new `width` × `height` float image and waits
    /// for the GPU. For tests, `--smoke` and snapshots, not for every frame.
    public func renderImage(width: Int, height: Int, uniforms: EdgeLightUniforms) throws -> LightImage {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: max(1, width), height: max(1, height), mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer()
        else { throw RenderError.encoding("create an offscreen target") }
        try encode(uniforms, into: texture, commandBuffer: commands)
        if texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        var pixels = [Float](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!, bytesPerRow: texture.width * 16,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
            )
        }
        return LightImage(width: texture.width, height: texture.height, pixels: pixels)
    }
}

/// An offscreen edge light frame: premultiplied RGBA floats, top row first.
public struct LightImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The pixel at column `x`, row `y` (row 0 is the top).
    public func pixel(x: Int, y: Int) -> SIMD4<Float> {
        let index = (y * width + x) * 4
        return SIMD4(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    /// Every component is a finite number in `0...1`.
    public var isWellFormed: Bool {
        pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    public var maximumAlpha: Float {
        stride(from: 3, to: pixels.count, by: 4).reduce(0) { max($0, pixels[$1]) }
    }

    /// Share of pixels with any light.
    public var litShare: Double {
        let lit = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0.002 }.count
        return Double(lit) / Double(max(1, width * height))
    }

    /// The frame over a solid background, as PNG (for snapshots).
    public func pngData(over background: SRGBColor) -> Data? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let back = SIMD3<Float>(Float(background.red), Float(background.green), Float(background.blue))
        for index in 0..<(width * height) {
            let rgb = SIMD3(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2])
            let alpha = pixels[index * 4 + 3]
            let out = rgb + back * (1 - alpha)
            for channel in 0..<3 {
                bytes[index * 4 + channel] = UInt8(max(0, min(255, (out[channel] * 255).rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
