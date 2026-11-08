import CoreGraphics
import Foundation

/// Decoded artwork for one song plus the palette derived from it.
public struct Artwork: @unchecked Sendable {
    // CGImage is immutable once created, so sharing it across threads is safe.
    public let image: CGImage
    /// `nil` until Step 2's extraction has run for real artwork.
    public let palette: Palette?
    /// Cache key: equal identifiers mean the same picture.
    public let identifier: String

    public init(image: CGImage, palette: Palette?, identifier: String) {
        self.image = image
        self.palette = palette
        self.identifier = identifier
    }

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
}

/// Produces artwork for a song: embedded data, a high-resolution catalog
/// lookup (Step 2), file metadata (Step 9) or generated gradients (demo).
public protocol ArtworkProvider: Sendable {
    /// Artwork at roughly `pixelSize` × `pixelSize`, or `nil` if none exists.
    func artwork(for track: Track, pixelSize: Int) async -> Artwork?
}
