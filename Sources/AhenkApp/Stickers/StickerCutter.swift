import AhenkKit
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Turns a photo into a sticker on this Mac: Vision finds the subject
/// (`VNGenerateForegroundInstanceMaskRequest`, on device) and everything
/// else becomes transparent. Nothing is uploaded anywhere.
enum StickerCutter {
    struct Cutout: @unchecked Sendable {
        let image: CGImage
        let png: Data
        /// Vision found a subject; otherwise the whole photo is used.
        let foundSubject: Bool
    }

    enum Failure: Error, Equatable {
        case unreadable
        case cannotEncode
    }

    /// Photos are read at most this large before cutting…
    static let maximumInput = 2048
    /// …and the cut-out is kept at most this large.
    static let maximumOutput = 1024

    /// The photo at `url` (any format ImageIO reads, turned upright).
    static func loadPhoto(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumInput,
              ] as CFDictionary)
        else { throw Failure.unreadable }
        return image
    }

    /// Cuts the subject out of `url`'s photo (call off the main thread).
    static func cut(photoAt url: URL) throws -> Cutout {
        try cut(try loadPhoto(url))
    }

    /// Cuts the subject out of `image`; without one, the whole picture with
    /// rounded corners.
    static func cut(_ image: CGImage) throws -> Cutout {
        var result: CGImage?
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? handler.perform([request])) != nil, let observation = request.results?.first, !observation.allInstances.isEmpty,
           let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true) {
            let masked = CIImage(cvPixelBuffer: buffer)
            result = context.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let found = result != nil
        guard let picture = scaled(result ?? rounded(image), maximum: maximumOutput), let png = pngData(picture) else {
            throw Failure.cannotEncode
        }
        return Cutout(image: picture, png: png, foundSubject: found)
    }

    /// The sticker as it is shown: with a white die-cut border around the
    /// subject's outline when `border` is on.
    static func bordered(_ image: CGImage, border: Bool) -> CGImage {
        guard border else { return image }
        let input = CIImage(cgImage: image)
        let radius = max(4, Double(max(image.width, image.height)) * 0.028)
        let pad = radius * 2
        let padded = input.transformed(by: CGAffineTransform(translationX: pad, y: pad))
            .composited(over: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: Double(image.width) + 2 * pad, height: Double(image.height) + 2 * pad)))
        let grown = padded
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.18])
        let white = grown.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.6),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ]).applyingFilter("CIColorClamp")
        let extent = CGRect(x: 0, y: 0, width: Double(image.width) + 2 * pad, height: Double(image.height) + 2 * pad)
        let combined = padded.composited(over: white).cropped(to: extent)
        return context.createCGImage(combined, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }

    /// How much larger the bordered picture is than the cut-out, per side
    /// (the sticker's size on screen is the cut-out's).
    static func borderScale(for image: CGImage) -> Double {
        let radius = max(4, Double(max(image.width, image.height)) * 0.028)
        return (Double(image.width) + 4 * radius) / Double(image.width)
    }

    // MARK: Helpers

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func rounded(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        let radius = Double(min(width, height)) * 0.08
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func scaled(_ image: CGImage, maximum: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximum else { return image }
        let scale = Double(maximum) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func image(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
