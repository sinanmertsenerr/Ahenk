import CoreGraphics
import Foundation

/// Decoded artwork for one song plus the palette derived from it.
public struct Artwork: @unchecked Sendable {
    // CGImage is immutable once created, so sharing it across threads is safe.
    public let image: CGImage
    /// Extracted from the image (`PaletteExtractor`); fixed for the demo.
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

/// Produces artwork for a song: embedded data, a cover URL, a catalog
/// lookup, file metadata (Step 9) or generated gradients (demo).
public protocol ArtworkProvider: Sendable {
    /// Artwork at roughly `pixelSize` × `pixelSize`, or `nil` if none exists.
    func artwork(for track: Track, pixelSize: Int) async -> Artwork?

    /// Artwork for what plays right now, which may carry the cover bytes
    /// itself. Defaults to the track-only lookup.
    func artwork(for snapshot: NowPlayingSnapshot, pixelSize: Int) async -> Artwork?
}

extension ArtworkProvider {
    public func artwork(for snapshot: NowPlayingSnapshot, pixelSize: Int) async -> Artwork? {
        await artwork(for: snapshot.track, pixelSize: pixelSize)
    }
}

/// Sends each source to its own artwork provider (the demo draws its covers,
/// everything else goes through the pipeline).
public struct RoutingArtworkProvider: ArtworkProvider {
    private let routes: [MusicSource: any ArtworkProvider]
    private let fallback: (any ArtworkProvider)?

    public init(routes: [MusicSource: any ArtworkProvider], fallback: (any ArtworkProvider)?) {
        self.routes = routes
        self.fallback = fallback
    }

    public func artwork(for track: Track, pixelSize: Int) async -> Artwork? {
        await (routes[track.source] ?? fallback)?.artwork(for: track, pixelSize: pixelSize)
    }

    public func artwork(for snapshot: NowPlayingSnapshot, pixelSize: Int) async -> Artwork? {
        await (routes[snapshot.track.source] ?? fallback)?.artwork(for: snapshot, pixelSize: pixelSize)
    }
}
