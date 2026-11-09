import Foundation

/// The decisions behind playing on a music site in the browser: which tab
/// takes a request, where a new tab opens, what an answer means, and how
/// the site's songs and playlists look in the desktop player.
public enum BrowserPlaybackPolicy {
    /// Where a request goes.
    public enum Route: Equatable, Sendable {
        /// No browser extension is connected.
        case noExtension
        /// To this tab.
        case tab(connection: Int, tabID: Int)
        /// To this browser, which opens a tab of the site.
        case newTab(connection: Int)
    }

    /// The tab of `site` that should take a request: one that plays (the
    /// one that started most recently… or simply the first reported); else
    /// the one the user looked at last (the selected tab of a window first);
    /// else any.
    public static func tab(for site: MusicSource, among tabs: [BrowserTabReport]) -> BrowserTabReport? {
        let candidates = tabs.filter { $0.site == site && $0.browserTabID != nil && $0.connectionID != nil }
        if let playing = candidates.filter(\.isPlaying).max(by: { $0.sampledAt < $1.sampledAt }) { return playing }
        return candidates.max { a, b in
            if a.isActiveTab != b.isActiveTab { return !a.isActiveTab }
            let lastA = a.lastActive ?? .distantPast
            let lastB = b.lastActive ?? .distantPast
            if lastA != lastB { return lastA < lastB }
            return a.sampledAt < b.sampledAt
        }
    }

    /// Where to ask for `site`. Without a tab of the site, the browser the
    /// user used last opens one: the connection with the most recently
    /// active tab of any site, else the newest connection.
    public static func route(for site: MusicSource, tabs: [BrowserTabReport], connections: [Int]) -> Route {
        guard !connections.isEmpty else { return .noExtension }
        if let tab = tab(for: site, among: tabs), let connection = tab.connectionID, let tabID = tab.browserTabID {
            return .tab(connection: connection, tabID: tabID)
        }
        let recent = tabs
            .filter { $0.connectionID.map(connections.contains) ?? false }
            .max { ($0.lastActive ?? $0.sampledAt) < ($1.lastActive ?? $1.sampledAt) }
        return .newTab(connection: recent?.connectionID ?? connections.max() ?? connections[0])
    }

    /// What the extension's answer to `play` means.
    public static func outcome(of result: BridgeResult?) -> BrowserPlayOutcome {
        guard let result else { return .failed("no answer from the browser") }
        switch result.outcome {
        case .started: return result.ok ? .started : .failed(result.error ?? "not started")
        case .opened: return .opened
        case .notFound: return .notFound
        case .noTab: return .noTab
        case .failed: return .failed(result.error ?? "failed")
        case nil: return result.ok ? .started : .failed(result.error ?? "failed")
        }
    }

    // MARK: Songs and playlists in the player

    /// A pick from Apple's catalog as the extension searches for it.
    public static func bridgeSong(_ song: CatalogSong, on site: MusicSource, spotifyTrackID: String?) -> BridgeSong {
        let ownID: String?
        if let origin = song.origin, origin.source == site {
            ownID = origin.id
        } else if site == .spotifyWeb {
            ownID = spotifyTrackID
        } else {
            ownID = nil
        }
        var trackID = ownID
        var url: String?
        if let ownID, let page = URL(string: ownID), page.scheme?.hasPrefix("http") == true {
            url = ownID
            trackID = BrowserSite(source: site).flatMap { site in
                switch site {
                case .youtube, .youtubeMusic: BrowserSite.youtubeVideoID(ownID)
                case .spotify: BrowserSite.spotifyTrackID(ownID)
                default: nil
                }
            }
        } else if site == .spotifyWeb {
            trackID = ownID.flatMap(BrowserSite.spotifyTrackID)
        }
        return BridgeSong(
            title: song.title, artist: song.artistName, album: song.albumTitle.isEmpty ? nil : song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil, trackID: trackID, url: url
        )
    }

    /// A song the site listed (a playlist, its queue) as the player shows it.
    public static func catalogSong(_ song: BridgeSong, on site: BrowserSite) -> CatalogSong {
        let ownID = site.trackIdentifier(trackID: song.trackID, trackURL: song.url)
            ?? TrackMatching.metadataKey(title: song.title, artist: song.artist, album: song.album ?? "")
        let artwork = song.artworkURL.flatMap(URL.init(string:)).map { CatalogArtwork.remote($0) }
        let track = Track(
            id: ownID, source: site.source, title: song.title, artist: song.artist, album: song.album ?? "",
            duration: song.duration ?? 0, artworkURL: song.artworkURL.flatMap(URL.init(string:))
        )
        return CatalogSong(
            id: "site:\(site.rawValue):\(ownID)", title: song.title, artistName: song.artist, albumTitle: song.album ?? "",
            duration: song.duration ?? 0, artwork: artwork, url: song.url.flatMap(URL.init(string:)), origin: track
        )
    }

    /// `site:<site>:<the site's playlist ID>`.
    public static func playlistID(_ id: String, on site: BrowserSite) -> String {
        "site:\(site.rawValue):\(id)"
    }

    /// The site and the site's own ID of a playlist the player lists.
    public static func parsePlaylistID(_ id: String) -> (site: BrowserSite, id: String)? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "site", let site = BrowserSite(rawValue: String(parts[1])), !parts[2].isEmpty else { return nil }
        return (site, String(parts[2]))
    }

    public static func catalogPlaylist(_ playlist: BridgePlaylist, on site: BrowserSite) -> CatalogPlaylist? {
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playlist.id.isEmpty, !name.isEmpty else { return nil }
        return CatalogPlaylist(
            id: playlistID(playlist.id, on: site), name: name, songCount: playlist.songCount,
            artwork: playlist.artworkURL.flatMap(URL.init(string:)).map { .remote($0) }
        )
    }
}
