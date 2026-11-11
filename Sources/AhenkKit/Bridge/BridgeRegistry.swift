import Foundation

/// The browser behind a connection, as Ahenk found it on this Mac.
public struct BridgeBrowserProcess: Sendable, Equatable {
    /// The browser's main process.
    public var processIdentifier: Int32
    public var bundleIdentifier: String

    public init(processIdentifier: Int32, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// One connected browser profile, for Settings › Sources.
public struct BridgeBrowserSummary: Sendable, Equatable, Identifiable {
    public var id: Int
    /// The browser's own name for itself ("Chrome", "Firefox").
    public var browserName: String
    public var bundleIdentifier: String?
    public var extensionVersion: String
    public var connectedAt: Date
    public var tabs: [BrowserTabReport]

    public init(id: Int, browserName: String, bundleIdentifier: String?, extensionVersion: String, connectedAt: Date, tabs: [BrowserTabReport]) {
        self.id = id
        self.browserName = browserName
        self.bundleIdentifier = bundleIdentifier
        self.extensionVersion = extensionVersion
        self.connectedAt = connectedAt
        self.tabs = tabs
    }
}

/// The bridge's state as a pure machine: connections open and close,
/// messages arrive, time passes; it answers with the effects to carry out
/// (send, close, publish). `BrowserBridgeServer` feeds it from the sockets;
/// tests feed it by hand.
///
/// - A connection must say `hello` within `helloTimeout` with a protocol
///   version Ahenk speaks, else it is told why and closed.
/// - A connection that sends nothing (not even its heartbeat) for
///   `idleTimeout` is closed.
/// - A new connection from a browser profile that is still connected (its
///   service worker restarted) replaces the old one and keeps its tabs until
///   the new one reports them, so players do not flicker.
/// - Tabs are held back until the browser's app is known (at most
///   `identifyTimeout`), so each tab joins the hub once, under its browser.
public struct BridgeRegistry: Sendable {
    public enum Effect: Sendable, Equatable {
        case send(BridgeOutbound, to: Int)
        case close(Int, reason: String)
        /// Which browser app this connection is (look it up, then call
        /// `identified`).
        case identify(Int)
        case tabsChanged
        case lyrics(BridgeSiteLyrics, tabKey: String)
        case result(BridgeResult, from: Int)
    }

    public struct Connection: Sendable, Equatable {
        public var id: Int
        public var openedAt: Date
        public var lastMessageAt: Date
        public var hello: BridgeHello?
        public var protocolVersion: Int?
        public var greetedAt: Date?
        public var browser: BridgeBrowserProcess?
        public var isIdentified = false
        public var tabs: [Int: BridgeTab] = [:]
        /// Tabs carried over from the connection this one replaced, until
        /// this one reports its own.
        public var hasOwnTabs = false

        public var isGreeted: Bool { greetedAt != nil }
    }

    public struct Timing: Sendable, Equatable {
        public var helloTimeout = BridgeProtocol.helloTimeout
        public var idleTimeout = BridgeProtocol.idleTimeout
        public var identifyTimeout: TimeInterval = 1.5

        public init() {}
    }

    public let appVersion: String
    public var timing: Timing
    public private(set) var connections: [Int: Connection] = [:]

    public init(appVersion: String, timing: Timing = Timing()) {
        self.appVersion = appVersion
        self.timing = timing
    }

    // MARK: Events

    public mutating func opened(_ id: Int, at now: Date) {
        connections[id] = Connection(id: id, openedAt: now, lastMessageAt: now)
    }

    public mutating func closed(_ id: Int) -> [Effect] {
        guard let connection = connections.removeValue(forKey: id) else { return [] }
        return connection.isIdentified && !connection.tabs.isEmpty ? [.tabsChanged] : []
    }

    public mutating func received(_ message: BridgeInbound, from id: Int, at now: Date) -> [Effect] {
        guard var connection = connections[id] else { return [] }
        connection.lastMessageAt = now
        defer { if connections[id] != nil { connections[id]?.lastMessageAt = now } }

        guard connection.isGreeted else {
            guard case .hello(let hello) = message else {
                connections[id] = connection
                return []
            }
            return greet(&connection, hello: hello, now: now)
        }

        switch message {
        case .hello:
            // Said twice: harmless, answered again.
            return [.send(.welcome(welcome(connection.protocolVersion ?? BridgeProtocol.version)), to: id)]
        case .tabs(let tabs):
            connection.tabs = Dictionary(tabs.map { ($0.tabID, $0) }, uniquingKeysWith: { _, last in last })
            connection.hasOwnTabs = true
            connections[id] = connection
            return connection.isIdentified ? [.tabsChanged] : []
        case .tab(let tab):
            if !connection.hasOwnTabs {
                // The first own report: what was carried over is replaced.
                connection.tabs = [:]
                connection.hasOwnTabs = true
            }
            let changed = connection.tabs[tab.tabID] != tab
            connection.tabs[tab.tabID] = tab
            connections[id] = connection
            return changed && connection.isIdentified ? [.tabsChanged] : []
        case .tabRemoved(let tabID):
            let removed = connection.tabs.removeValue(forKey: tabID) != nil
            connections[id] = connection
            return removed && connection.isIdentified ? [.tabsChanged] : []
        case .lyrics(let lyrics):
            guard let profile = connection.hello?.profile else { return [] }
            return [.lyrics(lyrics, tabKey: Self.tabKey(profile: profile, tabID: lyrics.tabID))]
        case .result(let result):
            return [.result(result, from: id)]
        case .ping:
            return [.send(.pong, to: id)]
        case .pong, .unknown:
            return []
        }
    }

    /// The browser app behind `id` was looked up (`nil`: not found).
    public mutating func identified(_ id: Int, as browser: BridgeBrowserProcess?) -> [Effect] {
        guard var connection = connections[id] else { return [] }
        if connection.isIdentified {
            // A look-up again after a reconnect, which kept the old answer
            // meanwhile: only a new, real answer changes anything.
            guard let browser, browser != connection.browser else { return [] }
            connection.browser = browser
            connections[id] = connection
            return connection.tabs.isEmpty ? [] : [.tabsChanged]
        }
        connection.browser = browser
        connection.isIdentified = true
        connections[id] = connection
        return connection.tabs.isEmpty ? [] : [.tabsChanged]
    }

    /// Closes connections that never said hello or went quiet, and stops
    /// waiting for an identification that takes too long.
    public mutating func tick(now: Date) -> [Effect] {
        var effects: [Effect] = []
        for (id, connection) in connections.sorted(by: { $0.key < $1.key }) {
            if !connection.isGreeted, now.timeIntervalSince(connection.openedAt) >= timing.helloTimeout {
                effects.append(.send(.error(code: "noHello", message: "Say hello first."), to: id))
                effects.append(.close(id, reason: "no hello"))
                connections[id] = nil
            } else if connection.isGreeted, now.timeIntervalSince(connection.lastMessageAt) >= timing.idleTimeout {
                effects.append(.close(id, reason: "silent for \(Int(timing.idleTimeout)) s"))
                connections[id] = nil
                if connection.isIdentified, !connection.tabs.isEmpty { effects.append(.tabsChanged) }
            } else if connection.isGreeted, !connection.isIdentified, let greeted = connection.greetedAt,
                      now.timeIntervalSince(greeted) >= timing.identifyTimeout {
                effects.append(contentsOf: identified(id, as: nil))
            }
        }
        return effects
    }

    /// When `tick` has to run next.
    public var nextDeadline: Date? {
        connections.values.map { connection -> Date in
            if !connection.isGreeted { return connection.openedAt.addingTimeInterval(timing.helloTimeout) }
            if !connection.isIdentified, let greeted = connection.greetedAt {
                return greeted.addingTimeInterval(timing.identifyTimeout)
            }
            return connection.lastMessageAt.addingTimeInterval(timing.idleTimeout)
        }.min()
    }

    private mutating func greet(_ connection: inout Connection, hello: BridgeHello, now: Date) -> [Effect] {
        let id = connection.id
        guard let version = BridgeProtocol.negotiate(theirs: hello.protocolVersion, theirMinimum: hello.minimumProtocolVersion) else {
            connections[id] = nil
            return [
                .send(.error(code: "incompatible", message: "This Ahenk speaks protocol \(BridgeProtocol.minimumVersion)–\(BridgeProtocol.version); update the older side."), to: id),
                .close(id, reason: "protocol \(hello.protocolVersion) not spoken"),
            ]
        }
        guard !hello.profile.isEmpty else {
            connections[id] = nil
            return [.send(.error(code: "noProfile", message: "Hello needs a profile."), to: id), .close(id, reason: "no profile")]
        }
        var effects: [Effect] = [.send(.welcome(welcome(version)), to: id)]
        connection.hello = hello
        connection.protocolVersion = version
        connection.greetedAt = now
        // The same browser profile again: the old connection is stale. Its
        // tabs and browser stay until the new one reports (no flicker); the
        // browser is looked up again all the same (it may have restarted).
        if let stale = connections.values.first(where: { $0.id != id && $0.hello?.profile == hello.profile }) {
            connections[stale.id] = nil
            connection.tabs = stale.tabs
            connection.browser = stale.browser
            connection.isIdentified = stale.isIdentified
            effects.append(.close(stale.id, reason: "replaced by a new connection from the same browser"))
        }
        connections[id] = connection
        effects.append(.identify(id))
        return effects
    }

    private func welcome(_ version: Int) -> BridgeWelcome {
        BridgeWelcome(protocolVersion: version, appVersion: appVersion)
    }

    // MARK: What the hub and Settings see

    public static func tabKey(profile: String, tabID: Int) -> String {
        "\(profile)/\(tabID)"
    }

    /// Every reported tab of every identified connection, newest first.
    public func reports(now: Date) -> [BrowserTabReport] {
        connections.values
            .filter { $0.isGreeted && $0.isIdentified }
            .sorted { $0.id < $1.id }
            .flatMap { connection in
                connection.tabs.values.sorted { $0.tabID < $1.tabID }.compactMap { tab in
                    BrowserTabReport(tab: tab, connection: connection, now: now)
                }
            }
    }

    public func summaries(now: Date) -> [BridgeBrowserSummary] {
        connections.values.filter(\.isGreeted).sorted { $0.id < $1.id }.map { connection in
            BridgeBrowserSummary(
                id: connection.id,
                browserName: connection.hello?.browser.name ?? "",
                bundleIdentifier: connection.browser?.bundleIdentifier,
                extensionVersion: connection.hello?.extensionVersion ?? "",
                connectedAt: connection.greetedAt ?? connection.openedAt,
                tabs: connection.tabs.values.sorted { $0.tabID < $1.tabID }.compactMap {
                    BrowserTabReport(tab: $0, connection: connection, now: now)
                }
            )
        }
    }

    /// The connection and the browser's tab ID behind a tab key.
    public func locate(tabKey: String) -> (connection: Int, tabID: Int)? {
        for connection in connections.values where connection.isGreeted {
            guard let profile = connection.hello?.profile else { continue }
            for tabID in connection.tabs.keys where Self.tabKey(profile: profile, tabID: tabID) == tabKey {
                return (connection.id, tabID)
            }
        }
        return nil
    }
}

extension BrowserTabReport {
    /// A tab as the hub sees it; `nil` for a page that is not one of the
    /// sites (the extension never reports those, but a page must not be able
    /// to claim another site).
    init?(tab: BridgeTab, connection: BridgeRegistry.Connection, now: Date) {
        guard let profile = connection.hello?.profile,
              let site = BrowserSite.site(reported: tab.site, url: tab.url)
        else { return nil }
        self.init(
            tabID: BridgeRegistry.tabKey(profile: profile, tabID: tab.tabID),
            browserBundleIdentifier: connection.browser?.bundleIdentifier,
            site: site.source,
            title: tab.title,
            artist: tab.artist,
            album: tab.album,
            duration: tab.duration ?? 0,
            artworkURL: tab.artworkURL.flatMap(Self.webURL),
            pageURL: (tab.trackURL ?? tab.url).flatMap(Self.webURL),
            elapsedTime: tab.position ?? 0,
            isPlaying: tab.state == .playing,
            sampledAt: Self.sampleTime(tab.sampledAt, now: now),
            isLiked: tab.liked,
            isShuffled: tab.shuffle,
            repeatMode: tab.repeatMode,
            contentKind: tab.kind,
            capabilities: Self.capabilities(tab.capabilities)
        )
        trackIdentifier = site.trackIdentifier(trackID: tab.trackID, trackURL: tab.trackURL)
        processIdentifier = connection.browser?.processIdentifier
        isPositionKnown = tab.position != nil
        playbackRate = tab.state == .playing ? (tab.playbackRate.flatMap { $0 > 0 ? $0 : nil } ?? 1) : 0
        browserTabID = tab.tabID
        connectionID = connection.id
        bridgeCapabilities = tab.capabilities
        siteTrackID = tab.trackID
        volume = tab.volume
        isActiveTab = tab.isActive ?? false
        lastActive = tab.lastActive.map { Date(timeIntervalSince1970: $0 / 1000) }
        browserName = connection.hello?.browser.name
        if site == .youtube || site == .youtubeMusic {
            songVideoKind = SongVideoKind(youTubeType: tab.musicVideoType)
        }
    }

    /// The browser's sample time, unless it is implausible (missing, in the
    /// future, or older than an hour): then now.
    static func sampleTime(_ milliseconds: Double, now: Date) -> Date {
        guard milliseconds > 0 else { return now }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let age = now.timeIntervalSince(date)
        return age < -2 || age > 3_600 ? now : date
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    static func capabilities(_ set: Set<BridgeCapability>) -> PlaybackCapabilities {
        var result: PlaybackCapabilities = []
        if set.contains(.playPause) { result.insert(.playPause) }
        if set.contains(.next) || set.contains(.previous) { result.insert(.skip) }
        if set.contains(.seek) { result.insert(.seek) }
        if set.contains(.shuffle) { result.insert(.shuffle) }
        if set.contains(.repeat) { result.insert(.repeatAll) }
        if set.contains(.repeatOne) { result.insert(.repeatOne) }
        if set.contains(.like) { result.insert(.like) }
        if set.contains(.unlike) { result.insert(.unlike) }
        return result
    }
}
