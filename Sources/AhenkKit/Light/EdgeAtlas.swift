import CoreGraphics
import Foundation

/// Where one strip of light lives in a screen's atlas: every strip of a
/// screen is drawn into one surface in one render pass, and each strip's
/// layer shows its own part of it.
public struct EdgeAtlasSlot: Equatable, Sendable {
    public var place: EdgeStrip.Place
    /// The strip on the screen, in points (y up).
    public var strip: CGRect
    /// Its rectangle in the atlas, in pixels (origin top-left, as Metal).
    public var pixels: CGRect
    /// Tall strips are stored turned a quarter so the atlas stays a few
    /// rows high: the row's start is the strip's bottom end and the row's
    /// top edge its left edge. The layer turns it back (+90°).
    public var isRotated: Bool

    /// The part of the atlas the strip's layer shows, in Core Animation's
    /// unit space, which counts y from the bottom of the image.
    public func contentsRect(atlasWidth: Int, atlasHeight: Int) -> CGRect {
        let width = Double(max(1, atlasWidth))
        let height = Double(max(1, atlasHeight))
        return CGRect(
            x: pixels.minX / width, y: (height - pixels.maxY) / height,
            width: pixels.width / width, height: pixels.height / height
        )
    }

    /// The layer's size before it is turned (points).
    public var layerSize: CGSize {
        isRotated ? CGSize(width: strip.height, height: strip.width) : strip.size
    }
}

/// All of a screen's strips packed into one surface: shelves of rows,
/// strips turned to lie flat, a transparent gutter between neighbours so
/// scaled drawing never picks up another strip's edge.
public struct EdgeAtlas: Equatable, Sendable {
    /// Transparent pixels between slots.
    public static let gutter = 2

    public let width: Int
    public let height: Int
    public let slots: [EdgeAtlasSlot]
    /// Pixels per point.
    public let scale: Double

    public init(strips: [EdgeStrip], scale: Double) {
        let scale = max(0.1, scale)
        self.scale = scale
        let sizes = strips.map { strip -> (EdgeStrip, Bool, Int, Int) in
            let rotated = strip.rect.height > strip.rect.width
            let along = rotated ? strip.rect.height : strip.rect.width
            let across = rotated ? strip.rect.width : strip.rect.height
            return (strip, rotated, max(1, Int((along * scale).rounded())), max(1, Int((across * scale).rounded())))
        }
        let shelfWidth = sizes.map(\.2).max() ?? 1
        var slots: [EdgeAtlasSlot] = []
        var x = 0
        var y = 0
        var shelfHeight = 0
        var usedWidth = 1
        for (strip, rotated, width, height) in sizes {
            if x > 0, x + width > shelfWidth {
                y += shelfHeight + Self.gutter
                x = 0
                shelfHeight = 0
            }
            slots.append(EdgeAtlasSlot(
                place: strip.place, strip: strip.rect,
                pixels: CGRect(x: x, y: y, width: width, height: height), isRotated: rotated
            ))
            usedWidth = max(usedWidth, x + width)
            x += width + Self.gutter
            shelfHeight = max(shelfHeight, height)
        }
        width = usedWidth
        height = max(1, y + shelfHeight)
        self.slots = slots
    }
}
