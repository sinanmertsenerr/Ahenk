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

    // MARK: Sources

    /// The source's own icon: the installed app's (as the Dock shows it),
    /// or the site's for a source that plays in a browser. `nil` when
    /// neither can be had; the badge then keeps its plain colour.
    func sourceIcon(_ source: MusicSource, pixelSize: Int) async -> NSImage? {
        let key = "source:\(source.rawValue)@\(pixelSize)"
        if let image = cache.object(forKey: key as NSString) { return image }
        var image: NSImage?
        if let app = Self.appBundleIdentifiers[source]?.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: pixelSize, height: pixelSize)
            image = icon
        } else if disk != nil, let host = Self.siteHosts[source],
                  let url = URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(host)") {
            image = await remote(url: url, pixelSize: pixelSize)
        }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: pixelSize * pixelSize * 4)
        }
        return image
    }

    func cachedSourceIcon(_ source: MusicSource, pixelSize: Int) -> NSImage? {
        cache.object(forKey: "source:\(source.rawValue)@\(pixelSize)" as NSString)
    }

    private static let appBundleIdentifiers: [MusicSource: [String]] = [
        .appleMusic: ["com.apple.Music"],
        .spotify: ["com.spotify.client"],
        .deezer: ["com.deezer.deezer-desktop"],
        .tidal: ["com.tidal.desktop"],
    ]

    private static let siteHosts: [MusicSource: String] = [
        .spotifyWeb: "open.spotify.com",
        .youtubeMusic: "music.youtube.com",
        .youtube: "youtube.com",
        .soundCloud: "soundcloud.com",
        .amazonMusic: "music.amazon.com",
        .deezer: "deezer.com",
        .tidal: "tidal.com",
    ]

    // MARK: Artists

    /// The artist's own picture, from their catalog page (the page names it
    /// for link previews); `nil` when the page has none or cannot be read.
    /// The picture's address is kept on disk, so the page is read once.
    func artistPhoto(_ artist: CatalogArtist, pixelSize: Int) async -> NSImage? {
        let key = "artist:\(artist.id)@\(pixelSize)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if let artwork = artist.artwork {
            // The search already named the picture.
            let image = await load(Request(artwork: artwork, pixelSize: pixelSize))
            if let image { cache.setObject(image, forKey: key as NSString, cost: pixelSize * pixelSize * 4) }
            return image
        }
        // The demo stays offline (it has no disk cache either).
        guard disk != nil, let page = artist.url, page.scheme == "https" else { return nil }
        if let running = inFlight[key] { return await running.value }
        let task = Task { () -> NSImage? in
            guard let address = await self.artistPhotoAddress(artistID: artist.id, page: page),
                  let url = Self.squarePicture(address, pixelSize: pixelSize)
            else { return nil }
            return await self.remote(url: url, pixelSize: pixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: pixelSize * pixelSize * 4)
        }
        return image
    }

    func cachedArtistPhoto(_ artist: CatalogArtist, pixelSize: Int) -> NSImage? {
        cache.object(forKey: "artist:\(artist.id)@\(pixelSize)" as NSString)
    }

    private func artistPhotoAddress(artistID: String, page: URL) async -> String? {
        let key = "artist-picture:" + artistID
        if let stored = disk?.data(forKey: key), let text = String(data: stored, encoding: .utf8), !text.isEmpty { return text }
        var request = URLRequest(url: page, timeoutInterval: 12)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (body, status) = try? await fetcher.send(request), status == 200, body.count < 8_000_000,
              let html = String(data: body, encoding: .utf8), let address = Self.previewPicture(in: html)
        else { return nil }
        disk?.store(Data(address.utf8), forKey: key)
        return address
    }

    /// The link-preview picture a page names (`og:image`), if it is one of
    /// the catalog's own resizable pictures.
    nonisolated static func previewPicture(in html: String) -> String? {
        guard let tag = html.range(of: #"<meta[^>]+property="og:image"[^>]*>"#, options: .regularExpression),
              let content = html[tag].range(of: #"content="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let address = String(html[content].dropFirst(9).dropLast())
        guard address.hasPrefix("https://"), address.contains("mzstatic.com/"), address.contains("ArtistImages") else { return nil }
        return address
    }

    /// The same picture as a square of `pixelSize`, cropped round its centre.
    nonisolated static func squarePicture(_ address: String, pixelSize: Int) -> URL? {
        let side = max(60, min(1200, pixelSize))
        let resized = address.replacingOccurrences(
            of: #"/\d+x\d+[a-z]*\.(jpg|png|webp)$"#, with: "/\(side)x\(side)cc.jpg", options: .regularExpression
        )
        return URL(string: resized)
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
            // A song that has just started has no stored cover yet: look
            // again while it is being fetched.
            guard loaded == nil, request.artwork == nil, request.origin != nil else { return }
            for wait in [1.5, 3, 6, 12] {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                loaded = await store?.load(request)
                if loaded != nil { return }
            }
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

/// An artist's own picture in a circle; their initials on the album's
/// colours until it arrives, or when there is none.
struct ArtistPhoto: View {
    let artist: CatalogArtist
    let side: CGFloat
    let palette: Palette

    @Environment(\.coverImages) private var store
    @State private var loaded: NSImage?

    private var pixelSize: Int { Int(side * 2) }

    var body: some View {
        ZStack {
            if let image = loaded ?? store?.cachedArtistPhoto(artist, pixelSize: pixelSize) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .transition(.opacity)
            } else {
                ArtistMonogram(name: artist.name, side: side, palette: palette)
            }
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.2), value: loaded != nil)
        .task(id: artist.id) {
            loaded = await store?.artistPhoto(artist, pixelSize: pixelSize)
        }
        .accessibilityHidden(true)
    }
}
