import AhenkKit
import AppKit
import SwiftUI

/// Covers for the widgets: catalog covers (downloaded at the size they are
/// shown and kept on disk in `~/Library/Caches/Ahenk/Covers`), generated
/// demo covers, and the covers of songs that played (stored by the artwork
/// pipeline when they played). Decoded off the main thread, kept in memory.
@MainActor
final class CoverImageStore {
    struct Request: Hashable {
        var artwork: CatalogArtwork?
        /// A song that played: its stored cover when there is no artwork.
        var origin: Track?
        var pixelSize: Int

        var key: String {
            if let artwork { return artwork.cacheKey(pixelSize: pixelSize) }
            if let origin { return "origin:\(origin.source.rawValue):\(origin.id)@\(pixelSize)" }
            return "none"
        }

        init(song: CatalogSong, pixelSize: Int) {
            artwork = song.artwork
            origin = song.origin
            self.pixelSize = pixelSize
        }

        init(artwork: CatalogArtwork?, pixelSize: Int) {
            self.artwork = artwork
            origin = nil
            self.pixelSize = pixelSize
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let fetcher: any HTTPFetching
    private let disk: ArtworkDiskCache?
    private let pipeline: ArtworkPipeline?
    private let demo: DemoProvider?

    /// `~/Library/Caches/Ahenk/Covers`.
    static var diskDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk/Covers", isDirectory: true)
    }

    init(services: NowPlayingServices, demo: DemoProvider?) {
        fetcher = services.fetcher
        disk = services.isDemo ? nil : ArtworkDiskCache(directory: Self.diskDirectory, maximumBytes: 120_000_000)
        pipeline = services.artwork as? ArtworkPipeline
        self.demo = demo
        cache.totalCostLimit = 80_000_000
        cache.countLimit = 400
    }

    func cached(_ request: Request) -> NSImage? {
        cache.object(forKey: request.key as NSString)
    }

    func load(_ request: Request) async -> NSImage? {
        let key = request.key
        if let image = cache.object(forKey: key as NSString) { return image }
        guard key != "none" else { return nil }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.resolve(request) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: request.pixelSize * request.pixelSize * 4)
        }
        return image
    }

    private func resolve(_ request: Request) async -> NSImage? {
        let size = request.pixelSize
        switch request.artwork {
        case .generated(let seed, let colors)?:
            let image = await Task.detached(priority: .utility) {
                DemoArtwork.makeImage(palette: Palette(colors: colors), seed: seed, pixelSize: size).map(SendableImage.init)
            }.value
            return image.map { NSImage(cgImage: $0.image, size: .zero) }
        case .remote(let url)?:
            return await remote(url: request.artwork?.url(pixelSize: size) ?? url, pixelSize: size)
        case nil:
            guard let origin = request.origin else { return nil }
            if origin.source == .demo, let demo, let artwork = await demo.artwork(for: origin, pixelSize: size) {
                return NSImage(cgImage: artwork.image, size: .zero)
            }
            if let pipeline, let stored = await pipeline.storedCover(for: origin, pixelSize: size) {
                return NSImage(cgImage: stored.image, size: .zero)
            }
            if origin.source == .local, origin.id.hasPrefix("/") {
                // A song file: the cover inside it, or its folder's picture.
                let url = URL(fileURLWithPath: origin.id)
                let decoded = await Task.detached(priority: .utility) { () -> SendableImage? in
                    guard let data = await LocalMetadata.artwork(of: url) else { return nil }
                    return ArtworkImageDecoder.decodeSquare(data, maxPixelSize: size).map { SendableImage(image: $0.image) }
                }.value
                return decoded.map { NSImage(cgImage: $0.image, size: .zero) }
            }
            if let url = origin.artworkURL { return await remote(url: url, pixelSize: size) }
            return nil
        }
    }

    private func remote(url: URL, pixelSize: Int) async -> NSImage? {
        let key = "url:" + url.absoluteString
        var data = disk?.data(forKey: key)
        if data == nil {
            guard let (body, status) = try? await fetcher.get(url), status == 200, body.count > 64, body.count < 20_000_000 else {
                return nil
            }
            disk?.store(body, forKey: key)
            data = body
        }
        guard let data else { return nil }
        let decoded = await Task.detached(priority: .utility) {
            ArtworkImageDecoder.decodeSquare(data, maxPixelSize: pixelSize).map { SendableImage(image: $0.image) }
        }.value
        return decoded.map { NSImage(cgImage: $0.image, size: .zero) }
    }

    /// Drops decoded covers (memory pressure, the player turned off).
    func trim() {
        cache.removeAllObjects()
    }
}

/// A CGImage crossing from a decoding task (immutable once made).
private struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

private struct CoverImageStoreKey: EnvironmentKey {
    static let defaultValue: CoverImageStore? = nil
}

extension EnvironmentValues {
    var coverImages: CoverImageStore? {
        get { self[CoverImageStoreKey.self] }
        set { self[CoverImageStoreKey.self] = newValue }
    }
}

/// A cover at a given size with rounded corners; a soft gradient in the
/// album's colours stands in while it loads.
struct CoverArt: View {
    let request: CoverImageStore.Request
    var side: CGFloat
    var cornerRadius: CGFloat

    @Environment(\.coverImages) private var store
    @State private var loaded: NSImage?

    init(song: CatalogSong, side: CGFloat, cornerRadius: CGFloat, scale: CGFloat = 2) {
        request = CoverImageStore.Request(song: song, pixelSize: Int(side * scale))
        self.side = side
        self.cornerRadius = cornerRadius
    }

    init(artwork: CatalogArtwork?, side: CGFloat, cornerRadius: CGFloat, scale: CGFloat = 2) {
        request = CoverImageStore.Request(artwork: artwork, pixelSize: Int(side * scale))
        self.side = side
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let image = loaded ?? store?.cached(request) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .task(id: request) {
            guard store?.cached(request) == nil else { return }
            loaded = await store?.load(request)
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let palette = request.artwork?.palette ?? Palette.neutral
        return LinearGradient(
            colors: [Color(palette.primary).opacity(0.55), Color(palette.secondary).opacity(0.35)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: side * 0.32, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
