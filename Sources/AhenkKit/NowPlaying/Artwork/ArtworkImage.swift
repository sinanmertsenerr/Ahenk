import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Short content hashes for cache keys.
public enum ArtworkDigest {
    /// The first 16 bytes of SHA-256, as 32 hex digits.
    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(of text: String) -> String {
        hex(of: Data(text.utf8))
    }
}

/// Decodes covers with ImageIO, downsampling while decoding, and makes them
/// square: video thumbnails lose their letterbox bars, then the centre is
/// cut out.
public enum ArtworkImageDecoder {
    /// Width and height from the image header, without decoding pixels.
    public static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        // EXIF orientations 5–8 swap the axes.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    public static func aspectRatio(of data: Data) -> Double? {
        pixelDimensions(of: data).map { Double($0.width) / Double($0.height) }
    }

    public struct Decoded: @unchecked Sendable {
        // CGImage is immutable, so sharing it is safe.
        public let image: CGImage
        /// The longer side of the original image, before downsampling.
        public let sourcePixelSize: Int
    }

    /// A square image of at most `maxPixelSize` per side, or `nil` when the
    /// bytes are not an image.
    public static func decodeSquare(_ data: Data, maxPixelSize: Int) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let original = pixelDimensions(of: data)
        let longest = max(original?.width ?? 0, original?.height ?? 0)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Leave room for the square crop of wide thumbnails.
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixelSize * 2),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let square = squared(thumbnail, maxPixelSize: maxPixelSize) else { return nil }
        return Decoded(image: square, sourcePixelSize: longest > 0 ? longest : max(thumbnail.width, thumbnail.height))
    }

    /// Crops letterbox bars and the sides, then scales to `maxPixelSize`.
    static func squared(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        var crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if abs(Double(image.width) / Double(image.height) - 1) > 0.02 {
            let bars = letterbox(of: image)
            crop = crop.inset(by: bars)
            let side = min(crop.width, crop.height)
            crop = CGRect(x: crop.midX - side / 2, y: crop.midY - side / 2, width: side, height: side).integral
        }
        guard let cropped = image.cropping(to: crop) else { return nil }
        let side = min(maxPixelSize, cropped.width, cropped.height)
        guard cropped.width != side || cropped.height != side else { return cropped }
        return redraw(cropped, side: side)
    }

    /// Near-black rows at the top and bottom (video thumbnails with bars).
    static func letterbox(of image: CGImage) -> VerticalInsets {
        let sampleWidth = 32
        let sampleHeight = max(8, min(256, image.height))
        var bytes = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return .zero }
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard ok else { return .zero }
        func isDark(row: Int) -> Bool {
            var dark = 0
            for x in 0..<sampleWidth {
                let i = (row * sampleWidth + x) * 4
                if max(bytes[i], bytes[i + 1], bytes[i + 2]) < 20 { dark += 1 }
            }
            return dark >= sampleWidth - 1
        }
        // Bitmap row 0 is the top of the image.
        var top = 0
        while top < sampleHeight / 3, isDark(row: top) { top += 1 }
        var bottom = 0
        while bottom < sampleHeight / 3, isDark(row: sampleHeight - 1 - bottom) { bottom += 1 }
        let scale = Double(image.height) / Double(sampleHeight)
        return VerticalInsets(top: Double(top) * scale, bottom: Double(bottom) * scale)
    }

    static func redraw(_ image: CGImage, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// PNG bytes of `image` (generated covers, tests).
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Top and bottom insets in pixels (no AppKit in AhenkKit).
struct VerticalInsets: Equatable {
    var top: Double
    var bottom: Double
    static let zero = VerticalInsets(top: 0, bottom: 0)
}

private extension CGRect {
    func inset(by insets: VerticalInsets) -> CGRect {
        // CGImage cropping uses a top-left origin.
        let height = max(1, self.height - insets.top - insets.bottom)
        return CGRect(x: minX, y: minY + insets.top, width: width, height: height)
    }
}
