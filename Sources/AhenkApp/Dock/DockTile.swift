import AhenkKit
import AppKit

/// What a Dock tile is made of that stays the same for a cover and a tile
/// size: the round cover at exactly the pixels it covers, and the ring's
/// colours all the way round.
struct DockTileParts {
    /// The tile's side in pixels.
    let pixelSide: Int
    /// The round cover, `coverPixels` wide; `nil` without a cover.
    let cover: CGImage?
    let coverPixels: Int
    /// The colours round the tile's centre (a conic gradient), `pixelSide` wide.
    let ring: CGImage?
    let colors: [CGColor]

    init(artwork: CGImage?, colors: [CGColor], pixelSide: Int) {
        let side = max(16, pixelSide)
        self.pixelSide = side
        self.colors = colors
        // Whole pixels, centred on whole pixels: the cover is copied, never resampled.
        var diameter = Int((2 * DockRingGeometry.coverRadius * Double(side)).rounded())
        if (side - diameter) % 2 != 0 { diameter += 1 }
        coverPixels = diameter
        cover = artwork.flatMap { DockTileRenderer.roundCover($0, pixelSide: diameter) }
        ring = DockTileRenderer.ringDisc(colors: colors, pixelSide: side)
    }

    /// One look of the tile (everything but the progress arc) as a picture
    /// of the tile's own pixels.
    func picture(of look: DockTileLook) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let size = CGSize(width: pixelSide, height: pixelSide)
        DockTileRenderer.drawLook(in: context, size: size, parts: self, geometry: DockRingGeometry.of(look.frame()))
        return context.makeImage()
    }
}

/// Draws one Dock tile: the round cover, a ring in the cover's colours
/// around it (wider and glowing on the beat), and the song's progress as a
/// bright arc on the ring. Plain Core Graphics into whatever context it is
/// given, so the smoke check draws the very same tile offscreen.
///
/// A tile is a look (`DockTileLook`: the cover, the ring and its glow) and
/// the progress arc over it. The Dock's tile is a wide-colour bitmap in
/// which a gradient, a clip or a resampled picture is slow, so
/// `DockTileView` draws each look once into a picture and from then on
/// copies it and strokes the arc: drawing everything on every frame cost
/// about 3 ms a tile.
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

    /// The colours all the way round the centre (a conic gradient), drawn
    /// once; every look cuts its ring out of it.
    static func ringDisc(colors: [CGColor], pixelSide: Int) -> CGImage? {
        guard pixelSide > 0, colors.count >= 2, let context = CGContext(
            data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
            locations: colors.indices.map { CGFloat($0) / CGFloat(colors.count - 1) }
        ) else { return nil }
        CGContextDrawConicGradient(context, gradient, CGPoint(x: Double(pixelSide) / 2, y: Double(pixelSide) / 2), .pi / 2)
        return context.makeImage()
    }

    /// The whole tile for `frame`, exactly as it changes (no steps).
    static func draw(in context: CGContext, size: CGSize, parts: DockTileParts, frame: DockArtFrame) {
        let geometry = DockRingGeometry.of(frame)
        drawLook(in: context, size: size, parts: parts, geometry: geometry)
        drawProgress(in: context, size: size, geometry: geometry, frame: frame)
    }

    /// The glow, the ring and the cover.
    static func drawLook(in context: CGContext, size: CGSize, parts: DockTileParts, geometry: DockRingGeometry) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = geometry.ringRadius * side
        let width = geometry.ringWidth * side
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)

        // The glow: a soft halo in the first colour on both sides of the ring.
        if geometry.glowRadius > 0, let first = parts.colors.first {
            let reach = geometry.glowRadius * side
            let inner = max(0, radius - width / 2 - reach), outer = radius + width / 2 + reach
            let edge = reach / (outer - inner)
            let alphas: [(CGFloat, Double)] = [(0, 0), (edge * 0.5, 0.2), (edge, 0.7), (1 - edge, 0.7), (1 - edge * 0.5, 0.2), (1, 0)]
            let stops = alphas.map { first.copy(alpha: geometry.glowOpacity * $0.1) ?? first }
            if let halo = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops as CFArray, locations: alphas.map(\.0)) {
                context.drawRadialGradient(halo, startCenter: center, startRadius: inner, endCenter: center, endRadius: outer, options: [])
            }
        }

        // The ring: the colours all the way round.
        let band = CGMutablePath()
        band.addEllipse(in: circle.insetBy(dx: -width / 2, dy: -width / 2))
        band.addEllipse(in: circle.insetBy(dx: width / 2, dy: width / 2))
        context.saveGState()
        context.addPath(band)
        context.clip(using: .evenOdd)
        context.setAlpha(geometry.ringOpacity)
        if let ring = parts.ring {
            context.interpolationQuality = .high
            context.draw(ring, in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        } else {
            context.setFillColor(parts.colors.first ?? CGColor(gray: 1, alpha: 1))
            context.fill(circle.insetBy(dx: -width, dy: -width))
        }
        context.restoreGState()

        // The cover on whole pixels (copied as it is), with a hairline edge.
        let pixel = side / CGFloat(parts.pixelSide)
        let coverSide = CGFloat(parts.coverPixels) * pixel
        let coverRect = CGRect(x: center.x - coverSide / 2, y: center.y - coverSide / 2, width: coverSide, height: coverSide)
        context.saveGState()
        if let cover = parts.cover {
            context.interpolationQuality = .none
            context.draw(cover, in: coverRect)
        } else {
            context.setFillColor(parts.colors.first ?? CGColor(gray: 0.3, alpha: 1))
            context.fillEllipse(in: coverRect)
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.2))
        context.setLineWidth(max(0.5, side * 0.006))
        context.strokeEllipse(in: coverRect.insetBy(dx: side * 0.003, dy: side * 0.003))
        context.restoreGState()
    }

    /// The progress: a bright arc on the ring, from the top, clockwise.
    static func drawProgress(in context: CGContext, size: CGSize, geometry: DockRingGeometry, frame: DockArtFrame) {
        guard frame.progress > 0.003 else { return }
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.saveGState()
        let arc = CGMutablePath()
        arc.addArc(
            center: center, radius: geometry.ringRadius * side, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * frame.progress, clockwise: true
        )
        context.addPath(arc)
        context.setLineWidth(max(1, geometry.ringWidth * side * 0.42))
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(gray: 1, alpha: frame.isPlaying ? 0.88 : 0.6))
        context.strokePath()
        context.restoreGState()
    }
}

/// The Dock tile's content view: the look of its frame as a picture (drawn
/// once per look and cover, then kept), copied pixel for pixel, and the
/// progress arc stroked over it.
final class DockTileView: NSView {
    private var artwork: CGImage?
    private var colors: [CGColor] = DockTileRenderer.ringColors(nil)
    private var parts: DockTileParts?
    private var pictures: [DockTileLook: CGImage] = [:]
    var state = DockArtFrame.still(progress: 0)

    /// A cover is showing (the last one stays while the next song's loads).
    var hasCover: Bool { artwork != nil }

    /// Looks kept as pictures now (the smoke check).
    var pictureCount: Int { pictures.count }

    func setArtwork(_ image: CGImage?, colors: [CGColor]) {
        artwork = image
        self.colors = colors
        parts = nil
        pictures = [:]
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The pixels the Dock asks for (2× on a Retina display).
        let scale = abs(context.ctm.a) > 0 ? abs(context.ctm.a) : 2
        let side = min(bounds.width, bounds.height)
        let pixelSide = max(16, Int((side * scale).rounded()))
        if parts?.pixelSide != pixelSide {
            parts = DockTileParts(artwork: artwork, colors: colors, pixelSide: pixelSide)
            pictures = [:]
        }
        guard let parts else { return }
        // Whatever the bitmap held: a glow must never add up over frames.
        context.clear(bounds)
        let look = DockTileLook(state)
        let shownFrame = look.frame(progress: state.progress)
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        if pictures[look] == nil { pictures[look] = parts.picture(of: look) }
        if let picture = pictures[look] {
            context.interpolationQuality = .none
            context.draw(picture, in: rect)
        } else {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            DockTileRenderer.drawLook(in: context, size: rect.size, parts: parts, geometry: DockRingGeometry.of(shownFrame))
            context.restoreGState()
        }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        DockTileRenderer.drawProgress(in: context, size: rect.size, geometry: DockRingGeometry.of(shownFrame), frame: shownFrame)
        context.restoreGState()
    }
}
