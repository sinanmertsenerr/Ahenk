import CoreGraphics
import Foundation

/// Photos drawn in code for the demo's stickers and the smoke check (no
/// real photos anywhere): an invented subject on a soft studio backdrop
/// with a floor shadow, which Vision cuts out like a real one.
public enum DemoStickerArt {
    public enum Subject: CaseIterable, Sendable {
        /// A blue mug with a handle and two eyes.
        case mug
        /// A shaded orange ball.
        case ball
    }

    public static func makeImage(_ subject: Subject = .mug, width: Int = 1024, height: Int = 768) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let w = Double(width), h = Double(height)
        let backdrop = CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.78, green: 0.82, blue: 0.86, alpha: 1), CGColor(red: 0.55, green: 0.6, blue: 0.66, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(backdrop, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        let unit = min(w / 1024, h / 768)
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
            CGRect(x: w / 2 + (x - 512) * unit, y: h / 2 + (y - 384) * unit, width: width * unit, height: height * unit)
        }
        switch subject {
        case .mug:
            context.setFillColor(CGColor(gray: 0, alpha: 0.22))
            context.fillEllipse(in: rect(330, 140, 380, 50))
            let blue = CGColor(red: 0.16, green: 0.45, blue: 0.85, alpha: 1)
            context.addPath(CGPath(roundedRect: rect(380, 170, 260, 300), cornerWidth: 40 * unit, cornerHeight: 40 * unit, transform: nil))
            context.setFillColor(blue)
            context.fillPath()
            context.setLineWidth(38 * unit)
            context.setStrokeColor(blue)
            context.addEllipse(in: rect(590, 250, 130, 140))
            context.strokePath()
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            context.fillEllipse(in: rect(440, 320, 60, 60))
            context.fillEllipse(in: rect(520, 320, 60, 60))
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fillEllipse(in: rect(462, 335, 22, 26))
            context.fillEllipse(in: rect(542, 335, 22, 26))
        case .ball:
            context.setFillColor(CGColor(gray: 0, alpha: 0.25))
            context.fillEllipse(in: rect(360, 150, 320, 60))
            let shade = CGGradient(
                colorsSpace: space,
                colors: [CGColor(red: 1, green: 0.75, blue: 0.4, alpha: 1), CGColor(red: 0.85, green: 0.3, blue: 0.1, alpha: 1)] as CFArray,
                locations: [0, 1]
            )!
            context.saveGState()
            context.addEllipse(in: rect(360, 200, 320, 320))
            context.clip()
            let light = rect(460, 440, 0, 0).origin, dark = rect(520, 360, 0, 0).origin
            context.drawRadialGradient(shade, startCenter: light, startRadius: 10 * unit, endCenter: dark, endRadius: 200 * unit, options: [])
            context.restoreGState()
        }
        return context.makeImage()
    }
}
