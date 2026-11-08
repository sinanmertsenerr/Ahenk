import CoreGraphics
import CoreVideo
import IOSurface
import Metal

/// Three IOSurfaces one strip of light is drawn into in turn. The strip's
/// plain `CALayer` shows the newest as its `contents`; all of a screen's
/// strips change in one Core Animation transaction per frame.
///
/// Why not `CAMetalLayer`: at 60 fps every presented drawable costs frame
/// pacing bookkeeping, a shared event and a "presented" callback. With four
/// strips per screen that was more than half of the light's CPU time;
/// swapping surfaces costs one transaction per frame.
///
/// Render thread only.
final class SurfaceRing {
    let width: Int
    let height: Int
    private var surfaces: [IOSurface] = []
    private var textures: [MTLTexture] = []
    private var next = 0
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()

    /// Premultiplied BGRA surfaces in sRGB, `width` × `height` pixels.
    init?(device: MTLDevice, width: Int, height: Int, count: Int = 3) {
        self.width = max(1, width)
        self.height = max(1, height)
        for _ in 0..<count {
            guard let surface = IOSurface(properties: [
                .width: self.width,
                .height: self.height,
                .bytesPerElement: 4,
                .pixelFormat: UInt32(kCVPixelFormatType_32BGRA),
            ]) else { return nil }
            if let space = Self.colorSpace {
                IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: self.width, height: self.height, mipmapped: false
            )
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
            surfaces.append(surface)
            textures.append(texture)
        }
    }

    /// The next surface the window server is not showing, or `nil` when
    /// all are still on screen (then the strip keeps its last frame).
    func acquire() -> (surface: IOSurface, texture: MTLTexture)? {
        for offset in 0..<surfaces.count {
            let index = (next + offset) % surfaces.count
            if !surfaces[index].isInUse {
                next = (index + 1) % surfaces.count
                return (surfaces[index], textures[index])
            }
        }
        return nil
    }
}
