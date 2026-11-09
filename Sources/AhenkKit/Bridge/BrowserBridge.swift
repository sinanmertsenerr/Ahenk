import Foundation
import os

/// What the Ahenk browser extension reports for one tab.
public struct BrowserTabReport: Sendable, Equatable, Identifiable {
    /// Stable for the tab's lifetime and across reconnects: the browser
    /// profile and the browser's tab ID (`BridgeRegistry.tabKey`).
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
    /// The song's ID in `Track.id` form (`spotify:track:…`, a watch URL);
    /// `nil` falls back to the page URL, then to the metadata.
    public var trackIdentifier: String?
    /// The browser's main process (the audio engine taps its helpers).
    public var processIdentifier: Int32?
    public var isPositionKnown = true
    public var playbackRate: Double = 1
    /// The browser's own tab ID and the connection it came through.
    public var browserTabID: Int?
    public var connectionID: Int?
    /// What the extension can do in this tab beyond transport commands.
    public var bridgeCapabilities: Set<BridgeCapability> = []
    public var volume: Double?
    /// The tab is the selected one in its window.
    public var isActiveTab = false
    public var lastActive: Date?
    /// The browser's own name ("Chrome", "Firefox").
    public var browserName: String?
    /// YouTube and YouTube Music: what the song's video shows (an official
    /// video, an upload, the cover as a still).
    public var songVideoKind: SongVideoKind?

    public var id: String { tabID }

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
                id: trackIdentifier ?? pageURL?.absoluteString ?? TrackMatching.metadataKey(title: title, artist: artist, album: album),
                source: site,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                artworkURL: artworkURL
            ),
            bundleIdentifier: browserBundleIdentifier,
            processIdentifier: processIdentifier,
            instanceIdentifier: tabID,
            elapsedTime: elapsedTime,
            playbackRate: isPlaying ? (playbackRate > 0 ? playbackRate : 1) : 0,
            timestamp: sampledAt,
            isPositionKnown: isPositionKnown,
            isShuffled: isShuffled,
            repeatMode: repeatMode,
            isLiked: isLiked,
            capabilities: capabilities,
            contentKind: contentKind,
            songVideoKind: songVideoKind
        )
    }

    /// The player this tab is in the hub.
    public var playerID: PlayerID {
        PlayerID(source: site, bundleIdentifier: browserBundleIdentifier, instance: tabID)
    }
}

/// The app side of the browser extension (`BrowserBridgeServer`).
public protocol BrowserBridge: AnyObject, Sendable {
    /// Every tab that plays or paused media, now and on every change.
    func tabs() -> AsyncStream<[BrowserTabReport]>
    func send(_ command: PlaybackCommand, toTab tabID: String) async -> Bool
}

/// Browser tabs reported by the extension, one player per tab. Its reports
/// hide the system reader's guess for the same browser (the same song seen
/// twice), see `HubCore`. Without a bridge it reports nothing.
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
            shadowsSameApp: true,
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

/// Ahenk's own player for song files (the app's AVQueuePlayer): what it
/// plays and the commands it takes.
public protocol LocalPlaybackEngine: AnyObject, Sendable {
    /// The current snapshot at once, then every noticeable change; `nil`
    /// while nothing is loaded.
    func snapshots() -> AsyncStream<NowPlayingSnapshot?>
    func perform(_ command: PlaybackCommand) async -> Bool
}

/// Songs Ahenk plays itself from the user's folders, as the hub's "Local"
/// source. Without an engine (the demo) it reports nothing.
public final class LocalPlaybackProvider: NowPlayingProvider, Sendable {
    public static let providerID = "local"
    public let id = LocalPlaybackProvider.providerID
    public let engine: (any LocalPlaybackEngine)?

    public init(engine: (any LocalPlaybackEngine)? = nil) {
        self.engine = engine
    }

    public func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        if let engine { return engine.snapshots() }
        let (stream, continuation) = AsyncStream<NowPlayingSnapshot?>.makeStream()
        continuation.yield(nil)
        return stream
    }

    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> Bool {
        await engine?.perform(command) ?? false
    }
}

/// Hands one value to any number of streams: the newest at once to a new
/// stream, then every change. Thread-safe.
public final class SnapshotBroadcaster<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
        var value: Value
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    public init(_ initial: Value) {
        state = OSAllocatedUnfairLock(initialState: State(value: initial))
    }

    public var value: Value { state.withLock { $0.value } }

    public func stream() -> AsyncStream<Value> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let current = state.withLock { state -> Value in
            state.continuations[key] = continuation
            return state.value
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    public func publish(_ value: Value) {
        let targets = state.withLock { state -> [AsyncStream<Value>.Continuation] in
            state.value = value
            return Array(state.continuations.values)
        }
        targets.forEach { $0.yield(value) }
    }
}

/// What the desktop player asks of a music site in the browser (the
/// extension through `BridgePlaybackRouter`): play a pick found in the
/// catalog, the site's playlists, its queue and its volume.
public protocol BrowserPlaybackRouting: AnyObject, Sendable {
    func play(_ request: BrowserPlayRequest) async -> BrowserPlayOutcome
    /// `nil` when the site shares no playlists.
    func playlists(on site: MusicSource) async -> [CatalogPlaylist]?
    func songs(ofPlaylist id: String, on site: MusicSource) async -> [CatalogSong]
    /// Plays a playlist of the site from `index` (its own order and queue).
    func playPlaylist(_ id: String, from index: Int?, on site: MusicSource) async -> BrowserPlayOutcome
    /// The site's own queue (`nil`: the site does not show it).
    func queue(on site: MusicSource) async -> BrowserQueue?
    func playQueueItem(_ index: Int, on site: MusicSource) async -> Bool
    func removeQueueItem(_ index: Int, on site: MusicSource) async -> Bool
    /// 0…1, `nil` when the site's player has no volume to read.
    func volume(on site: MusicSource) async -> Double?
    func setVolume(_ volume: Double, on site: MusicSource) async
    /// The site has a tab whose player reports a volume.
    func hasVolume(on site: MusicSource) -> Bool
    /// An extension is connected.
    var isConnected: Bool { get }
}

/// The songs of a site's own queue.
public struct BrowserQueue: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var index: Int
        public var song: CatalogSong
        public var isCurrent: Bool
        public var id: Int { index }

        public init(index: Int, song: CatalogSong, isCurrent: Bool) {
            self.index = index
            self.song = song
            self.isCurrent = isCurrent
        }
    }

    public var site: MusicSource
    public var items: [Item]
    /// Songs can be taken out of it.
    public var canRemove: Bool

    public init(site: MusicSource, items: [Item], canRemove: Bool) {
        self.site = site
        self.items = items
        self.canRemove = canRemove
    }

    /// What comes after the song that plays.
    public var upNext: [Item] {
        guard let current = items.firstIndex(where: \.isCurrent) else { return items }
        return Array(items[(current + 1)...])
    }
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
    /// No tab of the site is open and none could be opened.
    case noTab
    /// No browser extension is connected.
    case noExtension
    /// The site opened with the song; the user starts it there.
    case opened
    case failed(String)
}
