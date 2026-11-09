import Foundation

/// What the Ahenk browser extension reports for one tab (Step 7).
public struct BrowserTabReport: Sendable, Equatable {
    /// Stable for the tab's lifetime.
    public var tabID: String
    public var browserBundleIdentifier: String?
    /// The site, exactly (the extension knows the page).
    public var site: MusicSource
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var artworkURL: URL?
    /// The page URL of the song, when the site has one.
    public var pageURL: URL?
    public var elapsedTime: TimeInterval
    public var isPlaying: Bool
    public var sampledAt: Date
    public var isLiked: Bool?
    public var isShuffled: Bool?
    public var repeatMode: RepeatMode?
    public var contentKind: ContentKind
    public var capabilities: PlaybackCapabilities

    public init(
        tabID: String, browserBundleIdentifier: String?, site: MusicSource, title: String, artist: String,
        album: String = "", duration: TimeInterval = 0, artworkURL: URL? = nil, pageURL: URL? = nil,
        elapsedTime: TimeInterval = 0, isPlaying: Bool, sampledAt: Date, isLiked: Bool? = nil,
        isShuffled: Bool? = nil, repeatMode: RepeatMode? = nil, contentKind: ContentKind = .music,
        capabilities: PlaybackCapabilities = .transport
    ) {
        self.tabID = tabID
        self.browserBundleIdentifier = browserBundleIdentifier
        self.site = site
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.pageURL = pageURL
        self.elapsedTime = elapsedTime
        self.isPlaying = isPlaying
        self.sampledAt = sampledAt
        self.isLiked = isLiked
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
        self.contentKind = contentKind
        self.capabilities = capabilities
    }

    /// The report as a snapshot; the tab is the player instance.
    public var snapshot: NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: Track(
                id: pageURL?.absoluteString ?? TrackMatching.metadataKey(title: title, artist: artist, album: album),
                source: site,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                artworkURL: artworkURL
            ),
            bundleIdentifier: browserBundleIdentifier,
            instanceIdentifier: tabID,
            elapsedTime: elapsedTime,
            playbackRate: isPlaying ? 1 : 0,
            timestamp: sampledAt,
            isShuffled: isShuffled,
            repeatMode: repeatMode,
            isLiked: isLiked,
            capabilities: capabilities,
            contentKind: contentKind
        )
    }
}

/// The app side of the browser extension (Step 7 implements it with a
/// local WebSocket server).
public protocol BrowserBridge: AnyObject, Sendable {
    /// Every tab that plays or paused media, now and on every change.
    func tabs() -> AsyncStream<[BrowserTabReport]>
    func send(_ command: PlaybackCommand, toTab tabID: String) async -> Bool
}

/// Browser tabs reported by the extension, one player per tab. Without a
/// bridge (until Step 7) it reports nothing; browser playback still shows
/// up through the system's Now Playing.
public final class BrowserProvider: Sendable {
    public static let providerID = "browser"
    public let bridge: (any BrowserBridge)?

    public init(bridge: (any BrowserBridge)?) {
        self.bridge = bridge
    }

    public var hubInput: HubInput {
        let bridge = self.bridge
        return HubInput(
            id: Self.providerID,
            priority: HubInput.dedicatedPriority,
            reports: {
                guard let bridge else {
                    let (stream, continuation) = AsyncStream<[NowPlayingSnapshot]>.makeStream()
                    continuation.yield([])
                    return stream
                }
                let upstream = bridge.tabs()
                let (stream, continuation) = AsyncStream<[NowPlayingSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(8))
                let task = Task {
                    for await tabs in upstream {
                        continuation.yield(tabs.map(\.snapshot))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
                return stream
            },
            perform: { command, player in
                guard let bridge, let tab = player.instance else { return false }
                return await bridge.send(command, toTab: tab)
            }
        )
    }
}

/// Songs Ahenk plays itself from a folder (Step 9 fills it in with
/// AVQueuePlayer). Reports nothing until then.
public final class LocalPlaybackProvider: NowPlayingProvider, Sendable {
    public static let providerID = "local"
    public let id = LocalPlaybackProvider.providerID

    public init() {}

    public func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        let (stream, continuation) = AsyncStream<NowPlayingSnapshot?>.makeStream()
        continuation.yield(nil)
        return stream
    }

    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> Bool {
        false
    }
}

/// What the desktop player asks of a music site in the browser (Step 7's
/// extension implements it): play a pick found in the catalog, the site's
/// playlists and its volume.
public protocol BrowserPlaybackRouting: AnyObject, Sendable {
    func play(_ request: BrowserPlayRequest) async -> BrowserPlayOutcome
    /// `nil` when the site shares no playlists.
    func playlists(on site: MusicSource) async -> [CatalogPlaylist]?
    func songs(ofPlaylist id: String, on site: MusicSource) async -> [CatalogSong]
    /// 0…1, `nil` when the site's player has no volume to read.
    func volume(on site: MusicSource) async -> Double?
    func setVolume(_ volume: Double, on site: MusicSource) async
}

/// A song to play on a site: found there by its title, artist and album,
/// or by the site's own ID when it is known.
public struct BrowserPlayRequest: Hashable, Sendable {
    public var site: MusicSource
    public var song: CatalogSong
    /// For the Spotify Web Player.
    public var spotifyTrackID: String?

    public init(site: MusicSource, song: CatalogSong, spotifyTrackID: String? = nil) {
        self.site = site
        self.song = song
        self.spotifyTrackID = spotifyTrackID
    }
}

public enum BrowserPlayOutcome: Hashable, Sendable {
    case started
    /// The site has no such song.
    case notFound
    /// No tab of the site is open (the extension may open one).
    case noTab
    case failed(String)
}
