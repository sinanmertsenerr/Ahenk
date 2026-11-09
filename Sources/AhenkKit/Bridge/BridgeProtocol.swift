import Foundation

// The JSON Ahenk and its browser extension exchange over the local
// WebSocket (one text frame per message, one object per frame, `type` first).
//
//   extension → app   hello, tabs, tab, tabRemoved, lyrics, result, ping, pong
//   app → extension   welcome, command, request, ping, pong, error
//
// The extension opens the connection and says `hello` with the protocol
// versions it speaks; Ahenk answers `welcome` with the version both use, or
// `error` and closes. Unknown message types and unknown fields are ignored,
// so either side can grow without breaking the other. Every field is
// decoded on its own: a wrong value drops that field, not the message.
//
// The extension's own copy of these rules lives in `Extension/lib/protocol.js`.

/// Versions, timing and ports shared with the extension.
public enum BridgeProtocol {
    /// The version this build speaks best.
    public static let version = 1
    /// The oldest version this build still speaks.
    public static let minimumVersion = 1
    /// The extension sends `ping` this often; it also keeps its service
    /// worker alive (Chrome 116+ counts WebSocket traffic as activity).
    public static let heartbeatInterval: TimeInterval = 20
    /// A connection that sends nothing for this long is closed.
    public static let idleTimeout: TimeInterval = 65
    /// A connection must say `hello` this soon after opening. A refused
    /// handshake (a web page's origin) gets HTTP 400, but Network.framework
    /// leaves that socket open; this timeout closes it.
    public static let helloTimeout: TimeInterval = 5
    /// Ports tried from the base port up (the extension tries the same ones).
    public static let portCount = 4
    /// Larger frames are refused (lyrics and playlists stay far below).
    public static let maximumMessageSize = 1 << 20

    /// The ports Ahenk may listen on, in the order both sides try them.
    public static func ports(base: Int, count: Int = portCount) -> [UInt16] {
        (0..<max(1, count)).compactMap { offset in
            let port = base + offset
            return (1...65_535).contains(port) ? UInt16(port) : nil
        }
    }

    /// The version both sides speak, or `nil` when the ranges do not meet.
    public static func negotiate(
        theirs: Int, theirMinimum: Int?, ours: Int = version, ourMinimum: Int = minimumVersion
    ) -> Int? {
        let agreed = min(theirs, ours)
        let floor = max(theirMinimum ?? theirs, ourMinimum)
        return agreed >= floor ? agreed : nil
    }
}

// MARK: - Values

/// The browser the extension runs in, as it describes itself.
public struct BridgeBrowser: Codable, Equatable, Sendable {
    /// "Chrome", "Edge", "Brave", "Firefox", "Chromium", …
    public var name: String
    public var version: String?
    /// `navigator.userAgentData.brands` (Chromium only).
    public var brands: [String]?

    public init(name: String, version: String? = nil, brands: [String]? = nil) {
        self.name = name
        self.version = version
        self.brands = brands
    }

    private enum CodingKeys: String, CodingKey { case name, version, brands }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name, "")
        version = c.lenientOptional(.version)
        brands = c.lenientOptional(.brands)
    }
}

public struct BridgeHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var minimumProtocolVersion: Int?
    public var extensionVersion: String
    /// The extension's own origin (`chrome-extension://<id>`), for display.
    public var extensionOrigin: String?
    public var browser: BridgeBrowser
    /// Random, stored by the extension: one browser profile. A reconnect
    /// with the same profile replaces the old connection.
    public var profile: String

    public init(
        protocolVersion: Int = BridgeProtocol.version, minimumProtocolVersion: Int? = BridgeProtocol.minimumVersion,
        extensionVersion: String, extensionOrigin: String? = nil, browser: BridgeBrowser, profile: String
    ) {
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.extensionVersion = extensionVersion
        self.extensionOrigin = extensionOrigin
        self.browser = browser
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", minimumProtocolVersion = "minProtocol", extensionVersion, extensionOrigin, browser, profile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = c.lenient(.protocolVersion, 0)
        minimumProtocolVersion = c.lenientOptional(.minimumProtocolVersion)
        extensionVersion = c.lenient(.extensionVersion, "")
        extensionOrigin = c.lenientOptional(.extensionOrigin)
        browser = c.lenient(.browser, BridgeBrowser(name: ""))
        profile = c.lenient(.profile, "")
    }
}

public struct BridgeWelcome: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var app: String
    public var appVersion: String
    /// Seconds between the extension's pings.
    public var heartbeat: Double

    public init(protocolVersion: Int, app: String = "Ahenk", appVersion: String, heartbeat: Double = BridgeProtocol.heartbeatInterval) {
        self.protocolVersion = protocolVersion
        self.app = app
        self.appVersion = appVersion
        self.heartbeat = heartbeat
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", app, appVersion, heartbeat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = c.lenient(.protocolVersion, 0)
        app = c.lenient(.app, "")
        appVersion = c.lenient(.appVersion, "")
        heartbeat = c.lenient(.heartbeat, BridgeProtocol.heartbeatInterval)
    }
}

/// What the extension can do in a tab right now.
public enum BridgeCapability: String, Codable, CaseIterable, Sendable {
    case playPause, next, previous, seek, shuffle, `repeat`, repeatOne, like, unlike
    /// Search the site and play a pick there.
    case search
    case playlists
    /// Read the site's queue; `queueEdit`: remove from it.
    case queue, queueEdit
    case volume
}

/// One tab that plays or paused media on a music site.
public struct BridgeTab: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case playing, paused, stopped
    }

    /// The browser's tab ID (unique within one browser profile).
    public var tabID: Int
    /// The site's ID as the extension names it (`BrowserSite`).
    public var site: String
    /// The page's URL.
    public var url: String?
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: String?
    public var duration: Double?
    /// Position in seconds at `sampledAt`.
    public var position: Double?
    /// Milliseconds since 1970 when `position` was read (the browser's clock,
    /// which is this Mac's clock).
    public var sampledAt: Double
    public var playbackRate: Double?
    public var state: State
    public var liked: Bool?
    public var shuffle: Bool?
    public var repeatMode: RepeatMode?
    /// The site's own ID of the song (a YouTube video ID, a Spotify track ID).
    public var trackID: String?
    /// The song's own page on the site.
    public var trackURL: String?
    /// "music", "video", "podcast", "advertisement", "unknown".
    public var kind: ContentKind
    public var capabilities: Set<BridgeCapability>
    /// 0…1 when the site's player has a volume the extension can read.
    public var volume: Double?
    /// The tab is the selected one in its window.
    public var isActive: Bool?
    /// Milliseconds since 1970 of the user's last visit to the tab.
    public var lastActive: Double?

    public init(
        tabID: Int, site: String, url: String? = nil, title: String, artist: String, album: String = "",
        artworkURL: String? = nil, duration: Double? = nil, position: Double? = nil, sampledAt: Double,
        playbackRate: Double? = nil, state: State, liked: Bool? = nil, shuffle: Bool? = nil, repeatMode: RepeatMode? = nil,
        trackID: String? = nil, trackURL: String? = nil, kind: ContentKind = .unknown,
        capabilities: Set<BridgeCapability> = [.playPause], volume: Double? = nil, isActive: Bool? = nil, lastActive: Double? = nil
    ) {
        self.tabID = tabID
        self.site = site
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.position = position
        self.sampledAt = sampledAt
        self.playbackRate = playbackRate
        self.state = state
        self.liked = liked
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.trackID = trackID
        self.trackURL = trackURL
        self.kind = kind
        self.capabilities = capabilities
        self.volume = volume
        self.isActive = isActive
        self.lastActive = lastActive
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tabId", site, url, title, artist, album, artworkURL = "artwork", duration, position, sampledAt
        case playbackRate = "rate", state, liked, shuffle, repeatMode = "repeat", trackID = "trackId", trackURL = "trackUrl"
        case kind, capabilities = "can", volume, isActive = "active", lastActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try c.decode(Int.self, forKey: .tabID)
        site = c.lenient(.site, "")
        url = c.lenientOptional(.url)
        title = c.lenient(.title, "")
        artist = c.lenient(.artist, "")
        album = c.lenient(.album, "")
        artworkURL = c.lenientOptional(.artworkURL)
        duration = Self.finite(c.lenientOptional(.duration), atLeast: 0)
        position = Self.finite(c.lenientOptional(.position), atLeast: 0)
        sampledAt = Self.finite(c.lenientOptional(.sampledAt), atLeast: 0) ?? 0
        playbackRate = Self.finite(c.lenientOptional(.playbackRate), atLeast: 0)
        state = c.lenient(.state, .paused)
        liked = c.lenientOptional(.liked)
        shuffle = c.lenientOptional(.shuffle)
        repeatMode = c.lenientOptional(.repeatMode)
        trackID = c.lenientOptional(.trackID)
        trackURL = c.lenientOptional(.trackURL)
        kind = c.lenient(.kind, .unknown)
        capabilities = c.lenientSet(.capabilities, [])
        volume = Self.finite(c.lenientOptional(.volume), atLeast: 0).map { min(1, $0) }
        isActive = c.lenientOptional(.isActive)
        lastActive = c.lenientOptional(.lastActive)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tabID, forKey: .tabID)
        try c.encode(site, forKey: .site)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encode(sampledAt, forKey: .sampledAt)
        try c.encodeIfPresent(playbackRate, forKey: .playbackRate)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(liked, forKey: .liked)
        try c.encodeIfPresent(shuffle, forKey: .shuffle)
        try c.encodeIfPresent(repeatMode, forKey: .repeatMode)
        try c.encodeIfPresent(trackID, forKey: .trackID)
        try c.encodeIfPresent(trackURL, forKey: .trackURL)
        try c.encode(kind, forKey: .kind)
        try c.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try c.encodeIfPresent(volume, forKey: .volume)
        try c.encodeIfPresent(isActive, forKey: .isActive)
        try c.encodeIfPresent(lastActive, forKey: .lastActive)
    }

    private static func finite(_ value: Double?, atLeast lower: Double) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(lower, value)
    }
}

/// A song as both sides describe it in requests and results.
public struct BridgeSong: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: Double?
    /// The site's own ID (a YouTube video ID, a Spotify track ID).
    public var trackID: String?
    public var url: String?
    public var artworkURL: String?

    public init(
        title: String, artist: String, album: String? = nil, duration: Double? = nil, trackID: String? = nil,
        url: String? = nil, artworkURL: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackID = trackID
        self.url = url
        self.artworkURL = artworkURL
    }

    enum CodingKeys: String, CodingKey {
        case title, artist, album, duration, trackID = "trackId", url, artworkURL = "artwork"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.title, "")
        artist = c.lenient(.artist, "")
        album = c.lenientOptional(.album)
        duration = (c.lenientOptional(.duration) as Double?).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        trackID = c.lenientOptional(.trackID)
        url = c.lenientOptional(.url)
        artworkURL = c.lenientOptional(.artworkURL)
    }
}

public struct BridgePlaylist: Codable, Equatable, Sendable {
    /// The site's ID of the playlist (stable, used to open it again).
    public var id: String
    public var name: String
    public var url: String?
    public var songCount: Int?
    public var artworkURL: String?

    public init(id: String, name: String, url: String? = nil, songCount: Int? = nil, artworkURL: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.songCount = songCount
        self.artworkURL = artworkURL
    }

    enum CodingKeys: String, CodingKey { case id, name, url, songCount = "count", artworkURL = "artwork" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, "")
        name = c.lenient(.name, "")
        url = c.lenientOptional(.url)
        songCount = c.lenientOptional(.songCount)
        artworkURL = c.lenientOptional(.artworkURL)
    }
}

/// A song in the site's own queue.
public struct BridgeQueueItem: Codable, Equatable, Sendable {
    /// Position in the site's list (what `playQueueItem` and
    /// `removeQueueItem` refer to).
    public var index: Int
    public var song: BridgeSong
    public var isCurrent: Bool

    public init(index: Int, song: BridgeSong, isCurrent: Bool = false) {
        self.index = index
        self.song = song
        self.isCurrent = isCurrent
    }

    enum CodingKeys: String, CodingKey { case index, song, isCurrent = "current" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        song = try c.decode(BridgeSong.self, forKey: .song)
        isCurrent = c.lenient(.isCurrent, false)
    }
}

/// A transport command for one tab.
public struct BridgeCommand: Codable, Equatable, Sendable {
    public enum Name: String, Codable, Sendable {
        case play, pause, toggle, next, previous, seek, shuffle, `repeat`, like, volume
    }

    public var id: String
    public var tabID: Int
    public var command: Name
    /// `seek`: seconds.
    public var position: Double?
    /// `shuffle`, `like`.
    public var on: Bool?
    /// `repeat`.
    public var mode: RepeatMode?
    /// `volume`: 0…1.
    public var volume: Double?

    public init(id: String, tabID: Int, command: Name, position: Double? = nil, on: Bool? = nil, mode: RepeatMode? = nil, volume: Double? = nil) {
        self.id = id
        self.tabID = tabID
        self.command = command
        self.position = position
        self.on = on
        self.mode = mode
        self.volume = volume
    }

    /// The wire form of a hub command.
    public init(id: String, tabID: Int, playback: PlaybackCommand) {
        switch playback {
        case .play: self.init(id: id, tabID: tabID, command: .play)
        case .pause: self.init(id: id, tabID: tabID, command: .pause)
        case .togglePlayPause: self.init(id: id, tabID: tabID, command: .toggle)
        case .next: self.init(id: id, tabID: tabID, command: .next)
        case .previous: self.init(id: id, tabID: tabID, command: .previous)
        case .seek(let seconds): self.init(id: id, tabID: tabID, command: .seek, position: max(0, seconds.isFinite ? seconds : 0))
        case .setShuffle(let on): self.init(id: id, tabID: tabID, command: .shuffle, on: on)
        case .setRepeat(let mode): self.init(id: id, tabID: tabID, command: .repeat, mode: mode)
        case .setLiked(let on): self.init(id: id, tabID: tabID, command: .like, on: on)
        }
    }

    enum CodingKeys: String, CodingKey { case id, tabID = "tabId", command, position, on, mode, volume }
}

/// A request that is more than a transport command.
public struct BridgeRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Find `song` on the site and play it (opening a tab if needed).
        case play
        case playlists
        case playlistSongs
        /// Play `playlistID` from `index` (or its start).
        case playPlaylist
        case queue
        case playQueueItem
        case removeQueueItem
        case volume
        case setVolume
    }

    public var id: String
    public var kind: Kind
    public var site: String
    /// `nil`: the extension picks the site's tab, or opens one (`play`).
    public var tabID: Int?
    public var song: BridgeSong?
    public var playlistID: String?
    public var playlistURL: String?
    public var index: Int?
    public var volume: Double?

    public init(
        id: String, kind: Kind, site: String, tabID: Int? = nil, song: BridgeSong? = nil, playlistID: String? = nil,
        playlistURL: String? = nil, index: Int? = nil, volume: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.site = site
        self.tabID = tabID
        self.song = song
        self.playlistID = playlistID
        self.playlistURL = playlistURL
        self.index = index
        self.volume = volume
    }

    enum CodingKeys: String, CodingKey {
        case id, kind = "request", site, tabID = "tabId", song, playlistID = "playlistId", playlistURL = "playlistUrl", index, volume
    }
}

/// The answer to a command or a request.
public struct BridgeResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case started
        /// The site has no such song or playlist.
        case notFound
        /// No tab of the site is open, and none could be opened.
        case noTab
        /// A tab of the site was opened with the song; autoplay was blocked,
        /// so the user starts it there.
        case opened
        case failed
    }

    public var id: String
    public var ok: Bool
    public var outcome: Outcome?
    /// A short, untranslated reason for the log.
    public var error: String?
    public var tabID: Int?
    public var playlists: [BridgePlaylist]?
    public var songs: [BridgeSong]?
    public var queue: [BridgeQueueItem]?
    public var volume: Double?

    public init(
        id: String, ok: Bool, outcome: Outcome? = nil, error: String? = nil, tabID: Int? = nil, playlists: [BridgePlaylist]? = nil,
        songs: [BridgeSong]? = nil, queue: [BridgeQueueItem]? = nil, volume: Double? = nil
    ) {
        self.id = id
        self.ok = ok
        self.outcome = outcome
        self.error = error
        self.tabID = tabID
        self.playlists = playlists
        self.songs = songs
        self.queue = queue
        self.volume = volume
    }

    enum CodingKeys: String, CodingKey { case id, ok, outcome, error, tabID = "tabId", playlists, songs, queue, volume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ok = c.lenient(.ok, false)
        outcome = c.lenientOptional(.outcome)
        error = c.lenientOptional(.error)
        tabID = c.lenientOptional(.tabID)
        playlists = c.contains(.playlists) ? c.lenientArray(.playlists, []) : nil
        songs = c.contains(.songs) ? c.lenientArray(.songs, []) : nil
        queue = c.contains(.queue) ? c.lenientArray(.queue, []) : nil
        volume = (c.lenientOptional(.volume) as Double?).flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}

public struct BridgeLyricWord: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double?
    public var text: String

    public init(start: Double, end: Double? = nil, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct BridgeLyricLine: Codable, Equatable, Sendable {
    /// Seconds from the start of the song.
    public var start: Double
    public var end: Double?
    public var text: String
    public var words: [BridgeLyricWord]?

    public init(start: Double, end: Double? = nil, text: String, words: [BridgeLyricWord]? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// Synced lyrics the site itself loaded for the song in a tab.
public struct BridgeSiteLyrics: Codable, Equatable, Sendable {
    public var tabID: Int
    public var site: String
    public var song: BridgeSong
    public var lines: [BridgeLyricLine]

    public init(tabID: Int, site: String, song: BridgeSong, lines: [BridgeLyricLine]) {
        self.tabID = tabID
        self.site = site
        self.song = song
        self.lines = lines
    }

    enum CodingKeys: String, CodingKey { case tabID = "tabId", site, song, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try c.decode(Int.self, forKey: .tabID)
        site = c.lenient(.site, "")
        song = try c.decode(BridgeSong.self, forKey: .song)
        lines = c.lenientArray(.lines, [])
    }
}

// MARK: - Messages

/// Extension → app.
public enum BridgeInbound: Equatable, Sendable {
    case hello(BridgeHello)
    /// Every tab with media in this browser profile (replaces what was known).
    case tabs([BridgeTab])
    /// One tab changed.
    case tab(BridgeTab)
    case tabRemoved(tabID: Int)
    case lyrics(BridgeSiteLyrics)
    case result(BridgeResult)
    case ping
    case pong
    /// A type this build does not know; ignored.
    case unknown(String)

    enum CodingKeys: String, CodingKey { case type, tabs, tab, tabID = "tabId", lyrics }

    /// Reads one frame. Throws for anything that is not a JSON object with a
    /// `type`, or a known type whose required parts are missing.
    public static func decode(_ data: Data) throws -> BridgeInbound {
        guard data.count <= BridgeProtocol.maximumMessageSize else { throw BridgeProtocolError.tooLarge }
        return try JSONDecoder().decode(Envelope.self, from: data).message
    }

    private struct Envelope: Decodable {
        let message: BridgeInbound

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "hello": message = .hello(try BridgeHello(from: decoder))
            case "tabs": message = .tabs(c.lenientArray(.tabs, []))
            case "tab": message = .tab(try c.decode(BridgeTab.self, forKey: .tab))
            case "tabRemoved": message = .tabRemoved(tabID: try c.decode(Int.self, forKey: .tabID))
            case "lyrics": message = .lyrics(try c.decode(BridgeSiteLyrics.self, forKey: .lyrics))
            case "result": message = .result(try BridgeResult(from: decoder))
            case "ping": message = .ping
            case "pong": message = .pong
            default: message = .unknown(type)
            }
        }
    }

    /// The frame as the extension sends it (tests and the smoke check play
    /// the extension's part).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .hello(let hello): return try encoder.encode(Tagged(type: "hello", body: hello))
        case .tabs(let tabs): return try encoder.encode(Keyed(type: "tabs", key: "tabs", value: tabs))
        case .tab(let tab): return try encoder.encode(Keyed(type: "tab", key: "tab", value: tab))
        case .tabRemoved(let id): return try encoder.encode(Keyed(type: "tabRemoved", key: "tabId", value: id))
        case .lyrics(let lyrics): return try encoder.encode(Keyed(type: "lyrics", key: "lyrics", value: lyrics))
        case .result(let result): return try encoder.encode(Tagged(type: "result", body: result))
        case .ping: return try encoder.encode(Bare(type: "ping"))
        case .pong: return try encoder.encode(Bare(type: "pong"))
        case .unknown(let type): return try encoder.encode(Bare(type: type))
        }
    }
}

/// App → extension.
public enum BridgeOutbound: Equatable, Sendable {
    case welcome(BridgeWelcome)
    case command(BridgeCommand)
    case request(BridgeRequest)
    case ping
    case pong
    /// Sent before Ahenk closes a connection it cannot serve.
    case error(code: String, message: String)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .welcome(let welcome): return try encoder.encode(Tagged(type: "welcome", body: welcome))
        case .command(let command): return try encoder.encode(Tagged(type: "command", body: command))
        case .request(let request): return try encoder.encode(Tagged(type: "request", body: request))
        case .ping: return try encoder.encode(Bare(type: "ping"))
        case .pong: return try encoder.encode(Bare(type: "pong"))
        case .error(let code, let message): return try encoder.encode(ErrorBody(type: "error", code: code, message: message))
        }
    }

    enum CodingKeys: String, CodingKey { case type, code, message }

    /// Reads a frame the app sent (the extension's side, for tests).
    public static func decode(_ data: Data) throws -> BridgeOutbound {
        try JSONDecoder().decode(Envelope.self, from: data).message
    }

    private struct Envelope: Decodable {
        let message: BridgeOutbound

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "welcome": message = .welcome(try BridgeWelcome(from: decoder))
            case "command": message = .command(try BridgeCommand(from: decoder))
            case "request": message = .request(try BridgeRequest(from: decoder))
            case "ping": message = .ping
            case "pong": message = .pong
            case "error": message = .error(code: c.lenient(.code, ""), message: c.lenient(.message, ""))
            case let other: throw BridgeProtocolError.unknownType(other)
            }
        }
    }
}

public enum BridgeProtocolError: Error, Equatable, Sendable {
    case tooLarge
    case unknownType(String)
}

// MARK: - Encoding helpers

/// `{"type": …, <the body's own fields>}`.
private struct Tagged<Body: Encodable>: Encodable {
    let type: String
    let body: Body

    private enum TypeKey: String, CodingKey { case type }

    func encode(to encoder: Encoder) throws {
        try body.encode(to: encoder)
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(type, forKey: .type)
    }
}

/// `{"type": …, <key>: <value>}`.
private struct Keyed<Value: Encodable>: Encodable {
    let type: String
    let key: String
    let value: Value

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(type, forKey: DynamicKey(stringValue: "type"))
        try c.encode(value, forKey: DynamicKey(stringValue: key))
    }
}

private struct Bare: Encodable {
    let type: String
}

private struct ErrorBody: Encodable {
    let type: String
    let code: String
    let message: String
}
