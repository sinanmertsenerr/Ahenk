import Foundation
import os

/// Plays picks, lists playlists, reads queues and volumes on music sites,
/// through the browser extension (`BrowserBridgeServer` requests), following
/// `BrowserPlaybackPolicy`.
public final class BridgePlaybackRouter: BrowserPlaybackRouting, @unchecked Sendable {
    // Safety: `server` is Sendable; `playlistURLs` is behind its lock.
    private let server: BrowserBridgeServer
    private let playlistURLs = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let log = AhenkLogger(category: "bridge")

    /// Playing a pick can mean loading a search page and its results.
    public static let playTimeout: TimeInterval = 25
    public static let readTimeout: TimeInterval = 10

    public init(server: BrowserBridgeServer) {
        self.server = server
    }

    public var isConnected: Bool { !server.connectedBrowsers.isEmpty }

    public var extensionNeedsReload: Bool {
        server.connectedBrowsers.contains { ExtensionVersion.needsReload(reported: $0.extensionVersion) }
    }

    private func route(for site: MusicSource) -> BrowserPlaybackPolicy.Route {
        BrowserPlaybackPolicy.route(for: site, tabs: server.currentTabs, connections: server.connectedBrowsers.map(\.id))
    }

    // MARK: Playing a pick

    public func play(_ request: BrowserPlayRequest) async -> BrowserPlayOutcome {
        guard let site = BrowserSite(source: request.site) else { return .failed("not a music site") }
        let song = BrowserPlaybackPolicy.bridgeSong(request.song, on: request.site, spotifyTrackID: request.spotifyTrackID)
        let target: (connection: Int, tabID: Int?)
        switch route(for: request.site) {
        case .noExtension: return .noExtension
        case .tab(let connection, let tabID): target = (connection, tabID)
        case .newTab(let connection): target = (connection, nil)
        }
        Self.log.info("Bridge: asking \(site.rawValue) to play a pick\(target.tabID == nil ? " in a new tab" : "")")
        let result = await server.request({ id in
            BridgeRequest(id: id, kind: .play, site: site.rawValue, tabID: target.tabID, song: song)
        }, on: target.connection, timeout: Self.playTimeout)
        let outcome = BrowserPlaybackPolicy.outcome(of: result)
        Self.log.info("Bridge: \(site.rawValue) answered the pick: \(Self.describe(outcome))")
        return outcome
    }

    private static func describe(_ outcome: BrowserPlayOutcome) -> String {
        switch outcome {
        case .started: "started"
        case .opened: "shown, not started (the browser lets a page play only after a click in it)"
        case .notFound: "not found"
        case .noTab: "no tab of the site"
        case .noExtension: "no extension"
        case .failed(let reason): "failed (\(reason))"
        }
    }

    // MARK: Playlists

    public func playlists(on source: MusicSource) async -> [CatalogPlaylist]? {
        guard let site = BrowserSite(source: source), case .tab(let connection, let tabID) = route(for: source) else { return nil }
        let result = await server.request({ id in
            BridgeRequest(id: id, kind: .playlists, site: site.rawValue, tabID: tabID)
        }, on: connection, timeout: Self.readTimeout)
        guard let result, result.ok, let lists = result.playlists else { return nil }
        playlistURLs.withLock { urls in
            for list in lists { if let url = list.url { urls[BrowserPlaybackPolicy.playlistID(list.id, on: site)] = url } }
        }
        return lists.compactMap { BrowserPlaybackPolicy.catalogPlaylist($0, on: site) }
    }

    public func songs(ofPlaylist id: String, on source: MusicSource) async -> [CatalogSong] {
        guard let (site, ownID) = BrowserPlaybackPolicy.parsePlaylistID(id), site.source == source,
              case .tab(let connection, let tabID) = route(for: source)
        else { return [] }
        let url = playlistURLs.withLock { $0[id] }
        let result = await server.request({ requestID in
            BridgeRequest(id: requestID, kind: .playlistSongs, site: site.rawValue, tabID: tabID, playlistID: ownID, playlistURL: url)
        }, on: connection, timeout: Self.readTimeout)
        return (result?.songs ?? []).map { BrowserPlaybackPolicy.catalogSong($0, on: site) }
    }

    public func playPlaylist(_ id: String, from index: Int?, on source: MusicSource) async -> BrowserPlayOutcome {
        guard let (site, ownID) = BrowserPlaybackPolicy.parsePlaylistID(id), site.source == source else { return .notFound }
        let target: (connection: Int, tabID: Int?)
        switch route(for: source) {
        case .noExtension: return .noExtension
        case .tab(let connection, let tabID): target = (connection, tabID)
        case .newTab(let connection): target = (connection, nil)
        }
        let url = playlistURLs.withLock { $0[id] }
        let result = await server.request({ requestID in
            BridgeRequest(id: requestID, kind: .playPlaylist, site: site.rawValue, tabID: target.tabID, playlistID: ownID, playlistURL: url, index: index)
        }, on: target.connection, timeout: Self.playTimeout)
        let outcome = BrowserPlaybackPolicy.outcome(of: result)
        Self.log.info("Bridge: \(site.rawValue) answered the playlist: \(Self.describe(outcome))")
        return outcome
    }

    // MARK: A song's music video

    /// Where a song falls in its music video, as YouTube Music pairs the
    /// two (`BridgeClip`): asked of a YouTube Music tab that can say.
    /// `nil`: no such tab, or the site pairs the video with no song for
    /// this listener.
    public func clip(ofVideo videoID: String) async -> BridgeClip? {
        guard BrowserSite.youtubeVideoID(videoID) == videoID else { return nil }
        let tabs = server.currentTabs.filter { $0.site == .youtubeMusic && $0.bridgeCapabilities.contains(.clip) && $0.browserTabID != nil && $0.connectionID != nil }
        guard let tab = BrowserPlaybackPolicy.tab(for: .youtubeMusic, among: tabs), let connection = tab.connectionID, let tabID = tab.browserTabID else { return nil }
        let result = await server.request({ id in
            BridgeRequest(id: id, kind: .clip, site: BrowserSite.youtubeMusic.rawValue, tabID: tabID, videoID: videoID)
        }, on: connection, timeout: Self.readTimeout)
        guard let clip = result?.clip, result?.ok == true, clip.videoID == videoID else { return nil }
        return clip
    }

    // MARK: Queue

    public func queue(on source: MusicSource) async -> BrowserQueue? {
        guard let site = BrowserSite(source: source), case .tab(let connection, let tabID) = route(for: source) else { return nil }
        let tab = server.currentTabs.first { $0.connectionID == connection && $0.browserTabID == tabID }
        guard tab?.bridgeCapabilities.contains(.queue) == true else { return nil }
        let result = await server.request({ id in
            BridgeRequest(id: id, kind: .queue, site: site.rawValue, tabID: tabID)
        }, on: connection, timeout: Self.readTimeout)
        guard let result, result.ok, let items = result.queue else { return nil }
        return BrowserQueue(
            site: source,
            items: items.map { BrowserQueue.Item(index: $0.index, song: BrowserPlaybackPolicy.catalogSong($0.song, on: site), isCurrent: $0.isCurrent) },
            canRemove: tab?.bridgeCapabilities.contains(.queueEdit) == true
        )
    }

    public func playQueueItem(_ index: Int, on source: MusicSource) async -> Bool {
        await simpleRequest(.playQueueItem, on: source, index: index)
    }

    public func removeQueueItem(_ index: Int, on source: MusicSource) async -> Bool {
        await simpleRequest(.removeQueueItem, on: source, index: index)
    }

    // MARK: Volume

    public func volume(on source: MusicSource) async -> Double? {
        guard let site = BrowserSite(source: source), case .tab(let connection, let tabID) = route(for: source) else { return nil }
        let result = await server.request({ id in
            BridgeRequest(id: id, kind: .volume, site: site.rawValue, tabID: tabID)
        }, on: connection, timeout: Self.readTimeout)
        return result?.ok == true ? result?.volume : nil
    }

    public func setVolume(_ volume: Double, on source: MusicSource) async {
        _ = await simpleRequest(.setVolume, on: source, volume: min(1, max(0, volume)))
    }

    public func hasVolume(on source: MusicSource) -> Bool {
        guard let tab = BrowserPlaybackPolicy.tab(for: source, among: server.currentTabs) else { return false }
        return tab.bridgeCapabilities.contains(.volume)
    }

    private func simpleRequest(_ kind: BridgeRequest.Kind, on source: MusicSource, index: Int? = nil, volume: Double? = nil) async -> Bool {
        guard let site = BrowserSite(source: source), case .tab(let connection, let tabID) = route(for: source) else { return false }
        let result = await server.request({ id in
            BridgeRequest(id: id, kind: kind, site: site.rawValue, tabID: tabID, index: index, volume: volume)
        }, on: connection, timeout: Self.readTimeout)
        return result?.ok == true
    }
}
