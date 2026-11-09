import AhenkKit
import AppKit

/// Draws one Dock tile: the round cover, a ring in the cover's colours
/// around it (wider and glowing on the beat), and the song's progress as a
/// bright arc on the ring. Plain Core Graphics into whatever context it is
/// given, so the smoke check draws the very same tile offscreen.
enum DockTileRenderer {
    /// The cover as a circle at `pixelSide`, made once per song.
    static func roundCover(_ image: CGImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0, let context = CGContext(
            data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide)
        context.interpolationQuality = .high
        context.addEllipse(in: rect)
        context.clip()
        // Fill: a cover that is not square is cropped around its middle.
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        return context.makeImage()
    }

    /// The ring's colours from the palette: at least two, closed into a
    /// loop so the conic gradient has no seam.
    static func ringColors(_ palette: Palette?) -> [CGColor] {
        let vivid = (palette ?? .neutral).vivid.map { $0.cgColor(alpha: 1) }
        var colors = Array(vivid.prefix(3))
        if colors.count == 1 { colors.append(colors[0].copy(alpha: 0.6) ?? colors[0]) }
        if colors.isEmpty { colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.6, alpha: 1)] }
        return colors + [colors[0]]
    }

    static func draw(in context: CGContext, size: CGSize, cover: CGImage?, colors: [CGColor], frame: DockArtFrame) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let geometry = DockRingGeometry.of(frame)
        let radius = geometry.ringRadius * side
        let width = geometry.ringWidth * side
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        let band = ring.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
            locations: colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        )

        // The glow: the band again, blurred, in the first colour.
        if geometry.glowRadius > 0, let glowColor = colors.first?.copy(alpha: geometry.glowOpacity) {
            context.saveGState()
            context.setShadow(offset: .zero, blur: geometry.glowRadius * side, color: glowColor)
            context.addPath(band)
            context.setFillColor(glowColor)
            context.fillPath()
            context.restoreGState()
        }

        // The ring: the colours all the way round, turned by the beat.
        if let gradient {
            context.saveGState()
            context.addPath(band)
            context.clip()
            context.setAlpha(geometry.ringOpacity)
            CGContextDrawConicGradient(context, gradient, center, .pi / 2 + 2 * .pi * frame.turn)
            context.restoreGState()
        }

        // The progress: a bright arc from the top, clockwise.
        if frame.progress > 0.003 {
            context.saveGState()
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * frame.progress, clockwise: true)
            context.addPath(arc)
            context.setLineWidth(max(1, width * 0.42))
            context.setLineCap(.round)
            context.setStrokeColor(CGColor(gray: 1, alpha: frame.isPlaying ? 0.88 : 0.6))
            context.strokePath()
            context.restoreGState()
        }

        // The cover, with a hairline edge.
        let coverRadius = geometry.coverRadius * side
        let coverRect = CGRect(x: center.x - coverRadius, y: center.y - coverRadius, width: 2 * coverRadius, height: 2 * coverRadius)
        context.saveGState()
        context.interpolationQuality = .high
        if let cover {
            context.draw(cover, in: coverRect)
        } else {
            context.setFillColor(colors.first ?? CGColor(gray: 0.3, alpha: 1))
            context.fillEllipse(in: coverRect)
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.2))
        context.setLineWidth(max(0.5, side * 0.006))
        context.strokeEllipse(in: coverRect.insetBy(dx: side * 0.003, dy: side * 0.003))
        context.restoreGState()
    }
}

/// The Dock tile's content view.
final class DockTileView: NSView {
    var cover: CGImage?
    var colors: [CGColor] = DockTileRenderer.ringColors(nil)
    var state = DockArtFrame.still(progress: 0)

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        DockTileRenderer.draw(in: context, size: bounds.size, cover: cover, colors: colors, frame: state)
    }
}
