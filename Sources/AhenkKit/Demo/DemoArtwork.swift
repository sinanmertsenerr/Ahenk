import CoreGraphics
import Foundation

/// Draws abstract gradient covers for the demo songs. Deterministic: the same
/// palette, seed and size always produce the same pixels.
public enum DemoArtwork {
    public static let pixelSizeRange: ClosedRange<Int> = 16...2048

    public static func makeImage(palette: Palette, seed: UInt64, pixelSize: Int) -> CGImage? {
        let size = pixelSize.clamped(to: pixelSizeRange)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        var random = SplitMix64(seed: seed)
        let side = CGFloat(size)
        let center = CGPoint(x: side / 2, y: side / 2)

        // 1. Diagonal base gradient between the two main colours.
        let angle = random.nextUnit() * 2 * .pi
        let reach = side * 0.75
        let start = CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach)
        let end = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
        if let base = gradient([palette.primary.cgColor(), palette.secondary.cgColor()], in: space) {
            context.drawLinearGradient(base, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // 2. Soft glows in the palette colours.
        for index in 0..<4 {
            let color = palette.colors[index % palette.colors.count]
                .mixed(with: index.isMultiple(of: 2) ? .white : .black, amount: 0.15)
            let glowCenter = CGPoint(x: random.nextUnit() * side, y: random.nextUnit() * side)
            let radius = side * (0.25 + random.nextUnit() * 0.35)
            if let glow = gradient([color.cgColor(alpha: 0.75), color.cgColor(alpha: 0)], in: space) {
                context.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: radius, options: [])
            }
        }

        // 3. Fine concentric rings, like grooves on a record.
        let ringCenter = CGPoint(x: side * (0.3 + random.nextUnit() * 0.4), y: side * (0.3 + random.nextUnit() * 0.4))
        context.setLineWidth(max(1, side / 300))
        context.setStrokeColor(SRGBColor.white.cgColor(alpha: 0.08))
        var ring = side * 0.06
        while ring < side * 0.9 {
            context.strokeEllipse(in: CGRect(x: ringCenter.x - ring, y: ringCenter.y - ring, width: ring * 2, height: ring * 2))
            ring += side * (0.025 + random.nextUnit() * 0.03)
        }

        // 4. One bold disc in the third colour.
        let discRadius = side * (0.12 + random.nextUnit() * 0.1)
        let discCenter = CGPoint(x: side * (0.2 + random.nextUnit() * 0.6), y: side * (0.2 + random.nextUnit() * 0.6))
        context.setFillColor(palette.tertiary.cgColor(alpha: 0.85))
        context.fillEllipse(in: CGRect(x: discCenter.x - discRadius, y: discCenter.y - discRadius, width: discRadius * 2, height: discRadius * 2))

        return context.makeImage()
    }

    private static func gradient(_ colors: [CGColor], in space: CGColorSpace) -> CGGradient? {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])
    }
}

extension SRGBColor {
    /// The colour as an sRGB `CGColor`.
    public func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Small deterministic PRNG (SplitMix64) for reproducible demo content.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<1`.
    mutating func nextUnit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
