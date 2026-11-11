import CoreGraphics
import Foundation

/// Which covers Ahenk may look up in public catalogs. A wrong cover is worse
/// than a small one, so videos, podcasts and unknown content keep what their
/// source gave. So does a music video (a clip) on YouTube or YouTube Music:
/// it shows its own picture, and only a song played over its album cover
/// gets the catalog's larger copy of that cover.
public enum ArtworkPolicy {
    public static func allowsCatalogLookup(source: MusicSource, kind: ContentKind, isMusicVideo: Bool = false) -> Bool {
        if isMusicVideo { return false }
        return switch source {
        case .demo, .local: false
        case .youtube, .otherApp: kind == .music
        case .appleMusic, .spotify, .spotifyWeb, .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal:
            kind == .music || kind == .unknown
        }
    }

    /// Spotify's public oEmbed endpoint knows the exact cover by track ID.
    public static func usesSpotifyOEmbed(_ source: MusicSource) -> Bool {
        source == .spotify || source == .spotifyWeb
    }
}

/// Finds, caches and decodes covers.
///
/// In order: the bytes the source handed over, the source's cover URL,
/// Spotify's oEmbed (exact, by track ID), then Apple's catalog for a larger
/// copy when the cover is small or missing and the policy allows it. Covers
/// are kept on disk (`ArtworkDiskCache`) and the decoded images in memory;
/// concurrent requests for the same cover share one load.
public actor ArtworkPipeline: ArtworkProvider {
    /// Covers smaller than this fraction of the requested size are
    /// upgraded from the catalog when allowed.
    static let upgradeThreshold = 0.9
    /// Catalog covers are fetched at this size.
    public static let catalogPixelSize = 1000
    static let negativeLookupLifetime: TimeInterval = 3 * 86_400

    private let disk: ArtworkDiskCache?
    private let fetcher: any HTTPFetching
    private let catalog: ITunesSearch?
    private let clock: @Sendable () -> Date
    private var memory = MemoryLRU<Artwork>(countLimit: 12, costLimit: 96_000_000)
    private var lookups: [String: StoredLookup] = [:]
    private var inFlight: [String: Task<Artwork?, Never>] = [:]
    private static let log = AhenkLogger(category: "artwork")

    public init(
        disk: ArtworkDiskCache?,
        fetcher: any HTTPFetching,
        catalog: ITunesSearch?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.disk = disk
        self.fetcher = fetcher
        self.catalog = catalog
        self.clock = clock
    }

    /// The disk-cache key that always holds the chosen cover of `track`
    /// (Continue Playing shows it later without fetching again).
    public nonisolated static func coverKey(for track: Track) -> String {
        "cover:\(track.source.rawValue):\(track.id)"
    }

    public func artwork(for track: Track, pixelSize: Int) async -> Artwork? {
        let snapshot = NowPlayingSnapshot(track: track, elapsedTime: 0, playbackRate: 0, timestamp: .distantPast, contentKind: .music)
        return await artwork(for: snapshot, pixelSize: pixelSize)
    }

    public func artwork(for snapshot: NowPlayingSnapshot, pixelSize: Int) async -> Artwork? {
        let size = max(16, min(3000, pixelSize))
        let key = Self.requestKey(snapshot, pixelSize: size)
        if let cached = memory.value(forKey: key) { return cached }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.resolve(snapshot, pixelSize: size) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            memory.insert(result, forKey: key, cost: result.pixelWidth * result.pixelHeight * 4)
        }
        return result
    }

    /// A cover stored earlier under `coverKey(for:)`, from disk only.
    public func storedCover(for track: Track, pixelSize: Int) -> Artwork? {
        let key = Self.coverKey(for: track)
        guard let data = disk?.data(forKey: key),
              let decoded = ArtworkImageDecoder.decodeSquare(data, maxPixelSize: pixelSize)
        else { return nil }
        return Artwork(image: decoded.image, palette: PaletteExtractor.palette(from: decoded.image), identifier: key)
    }

    /// Drops decoded covers from memory (memory pressure).
    public func trimMemory() {
        memory.removeAll()
    }

    // MARK: Resolution

    private struct Loaded {
        var decoded: ArtworkImageDecoder.Decoded
        var bytes: Data
        var identity: String
    }

    static func requestKey(_ snapshot: NowPlayingSnapshot, pixelSize: Int) -> String {
        let artwork = snapshot.artworkIdentifier ?? snapshot.artworkData.map { "\($0.count)" } ?? "-"
        let url = snapshot.track.artworkURL?.absoluteString ?? "-"
        // The same video is a clip or a still once its page says which.
        let video = snapshot.isMusicVideo ? "clip" : "song"
        return "\(coverKey(for: snapshot.track))|\(artwork)|\(url)|\(snapshot.contentKind.rawValue)|\(video)@\(pixelSize)"
    }

    private func resolve(_ snapshot: NowPlayingSnapshot, pixelSize: Int) async -> Artwork? {
        let track = snapshot.track
        var best: Loaded?
        // A clip: its own picture, at the size YouTube keeps it (what the
        // page hands over is often a small one).
        for url in YouTubeSongs.clipPictureURLs(for: snapshot) where best == nil {
            best = await load(url, pixelSize: pixelSize)
        }
        if best != nil {
            // Found.
        } else if let data = snapshot.artworkData,
           let decoded = ArtworkImageDecoder.decodeSquare(data, maxPixelSize: pixelSize) {
            best = Loaded(decoded: decoded, bytes: data, identity: "data:" + (snapshot.artworkIdentifier ?? ArtworkDigest.hex(of: data)))
        } else if let url = track.artworkURL {
            best = await load(url, pixelSize: pixelSize)
        }
        if best == nil, ArtworkPolicy.usesSpotifyOEmbed(track.source), let id = SpotifyOEmbed.trackID(from: track.id),
           let url = await spotifyCoverURL(trackID: id) {
            best = await load(SpotifyOEmbed.largeVariant(of: url), pixelSize: pixelSize)
            if best == nil { best = await load(url, pixelSize: pixelSize) }
        }
        let wanted = Double(min(pixelSize, 600)) * Self.upgradeThreshold
        if ArtworkPolicy.allowsCatalogLookup(source: track.source, kind: snapshot.contentKind, isMusicVideo: snapshot.isMusicVideo),
           Double(best?.decoded.sourcePixelSize ?? 0) < wanted,
           let url = await catalogURL(for: track),
           let found = await load(url, pixelSize: pixelSize),
           found.decoded.sourcePixelSize > (best?.decoded.sourcePixelSize ?? 0) {
            best = found
        }
        if best == nil, let data = disk?.data(forKey: Self.coverKey(for: track)),
           let decoded = ArtworkImageDecoder.decodeSquare(data, maxPixelSize: pixelSize) {
            // Offline: the cover chosen the last time this song played.
            best = Loaded(decoded: decoded, bytes: data, identity: Self.coverKey(for: track))
        }
        guard let best else { return nil }
        if track.source != .demo, let disk {
            let key = Self.coverKey(for: track)
            // A clip's picture also replaces a cover kept from before the page said it was one.
            if !disk.contains(key) || snapshot.artworkData != nil || snapshot.isMusicVideo {
                disk.store(best.bytes, forKey: key)
            }
        }
        let palette = PaletteExtractor.palette(from: best.decoded.image)
        return Artwork(image: best.decoded.image, palette: palette, identifier: best.identity)
    }

    private func load(_ url: URL, pixelSize: Int) async -> Loaded? {
        let key = "url:" + url.absoluteString
        if let data = disk?.data(forKey: key), let decoded = ArtworkImageDecoder.decodeSquare(data, maxPixelSize: pixelSize) {
            return Loaded(decoded: decoded, bytes: data, identity: key)
        }
        guard let (data, status) = try? await fetcher.get(url), status == 200,
              data.count > 64, data.count < 25_000_000,
              let decoded = ArtworkImageDecoder.decodeSquare(data, maxPixelSize: pixelSize)
        else { return nil }
        disk?.store(data, forKey: key)
        return Loaded(decoded: decoded, bytes: data, identity: key)
    }

    // MARK: Lookups

    struct StoredLookup: Codable, Sendable {
        var url: URL?
        var checkedAt: Date
    }

    private func remembered(_ key: String) -> StoredLookup? {
        let now = clock()
        func valid(_ lookup: StoredLookup) -> Bool {
            lookup.url != nil || now.timeIntervalSince(lookup.checkedAt) < Self.negativeLookupLifetime
        }
        if let memo = lookups[key], valid(memo) { return memo }
        if let data = disk?.data(forKey: key),
           let stored = try? JSONDecoder().decode(StoredLookup.self, from: data), valid(stored) {
            lookups[key] = stored
            return stored
        }
        return nil
    }

    private func remember(_ url: URL?, for key: String) {
        let lookup = StoredLookup(url: url, checkedAt: clock())
        lookups[key] = lookup
        if let data = try? JSONEncoder().encode(lookup) {
            disk?.store(data, forKey: key)
        }
    }

    private func catalogURL(for track: Track) async -> URL? {
        guard let catalog else { return nil }
        let key = "lookup:itunes:v1:" + [
            TrackMatching.normalized(track.artist),
            TrackMatching.coreTitle(track.title),
            TrackMatching.normalized(track.album),
            String(Int(track.duration.rounded())),
        ].joined(separator: "|")
        if let known = remembered(key) { return known.url }
        switch await catalog.lookupArtwork(for: track, pixelSize: Self.catalogPixelSize) {
        case .found(let url):
            remember(url, for: key)
            return url
        case .notFound:
            remember(nil, for: key)
            return nil
        case .failed:
            return nil
        }
    }

    private func spotifyCoverURL(trackID: String) async -> URL? {
        let key = "lookup:spotify-oembed:v1:" + trackID
        if let known = remembered(key) { return known.url }
        guard let request = SpotifyOEmbed.requestURL(trackID: trackID),
              let (data, status) = try? await fetcher.get(request)
        else { return nil }
        // Only a real answer is remembered; a network error may pass.
        let url = status == 200 ? SpotifyOEmbed.thumbnailURL(from: data) : nil
        if status == 200 || status == 404 { remember(url, for: key) }
        return url
    }
}
