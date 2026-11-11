import Foundation
import Network
import os

/// The local WebSocket server the Ahenk browser extension connects to.
///
/// - Listens on 127.0.0.1 only, on the first free port of a small fixed
///   range (`BridgeProtocol.ports`), which the extension tries in the same
///   order. Nothing outside this Mac can reach it.
/// - Accepts only the extension's origins (`BridgeOriginPolicy`); a web
///   page's handshake is refused with HTTP 400.
/// - Speaks the protocol in `BridgeProtocol.swift` through `BridgeRegistry`,
///   which decides; this class carries the bytes and the timers.
/// - Several browsers (and profiles) at once, each with any number of tabs.
///
/// Costs nothing while no browser is connected: the listener waits in the
/// kernel, and the one timer runs only while connections exist.
///
/// Thread safety: every mutable property is touched on `queue` only.
public final class BrowserBridgeServer: BrowserBridge, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var basePort: Int
        public var portCount: Int
        public var policy: BridgeOriginPolicy
        public var appVersion: String
        public var timing: BridgeRegistry.Timing
        /// How long a command waits for the tab's answer.
        public var commandTimeout: TimeInterval

        public init(
            basePort: Int, portCount: Int = BridgeProtocol.portCount, policy: BridgeOriginPolicy = .standard,
            appVersion: String, timing: BridgeRegistry.Timing = BridgeRegistry.Timing(), commandTimeout: TimeInterval = 5
        ) {
            self.basePort = basePort
            self.portCount = portCount
            self.policy = policy
            self.appVersion = appVersion
            self.timing = timing
            self.commandTimeout = commandTimeout
        }
    }

    public enum Status: Sendable, Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        /// No port of the range could be opened.
        case failed(String)
    }

    /// Finds the browser app behind a connection from its two ports (the
    /// client's, then Ahenk's).
    public typealias BrowserIdentifier = @Sendable (_ clientPort: UInt16, _ serverPort: UInt16, _ hello: BridgeHello) -> BridgeBrowserProcess?

    /// Connections beyond this are closed at once.
    public static let maximumConnections = 32

    private let queue = DispatchQueue(label: "com.sinanmertsener.Ahenk.bridge", qos: .userInitiated)
    private let identifier: BrowserIdentifier?
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "bridge")

    // Everything below lives on `queue`.
    private var configuration: Configuration
    private var registry: BridgeRegistry
    private var listener: NWListener?
    private var listeningPort: UInt16?
    private var status: Status = .stopped
    private var connections: [Int: NWConnection] = [:]
    private var clientPorts: [Int: UInt16] = [:]
    private var nextConnectionID = 1
    private var nextRequestID = 1
    private var pending: [String: (connection: Int, continuation: CheckedContinuation<BridgeResult?, Never>)] = [:]
    private var timer: DispatchSourceTimer?
    private var timerDeadline: Date?
    private var tabContinuations: [UUID: AsyncStream<[BrowserTabReport]>.Continuation] = [:]
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var summaryContinuations: [UUID: AsyncStream<[BridgeBrowserSummary]>.Continuation] = [:]
    private var lyricsContinuations: [UUID: AsyncStream<(tabKey: String, lyrics: BridgeSiteLyrics)>.Continuation] = [:]
    private var lastReports: [BrowserTabReport] = []

    public init(configuration: Configuration, identifier: BrowserIdentifier? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.identifier = identifier
        self.clock = clock
        registry = BridgeRegistry(appVersion: configuration.appVersion, timing: configuration.timing)
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        timer?.cancel()
    }

    // MARK: Lifecycle

    /// Opens the listener (idempotent).
    public func start() {
        queue.async { self.startOnQueue() }
    }

    /// Closes the listener and every connection; tabs disappear.
    public func stop() {
        queue.async { self.stopOnQueue(status: .stopped) }
    }

    /// Applies new settings (another port); restarts when they changed.
    public func update(_ configuration: Configuration) {
        queue.async {
            guard configuration != self.configuration else { return }
            let wasRunning = self.listener != nil || self.status == .starting
            self.stopOnQueue(status: .stopped)
            self.configuration = configuration
            self.registry = BridgeRegistry(appVersion: configuration.appVersion, timing: configuration.timing)
            if wasRunning { self.startOnQueue() }
        }
    }

    /// The current status, read on the bridge's queue.
    public var currentStatus: Status { queue.sync { status } }

    private func startOnQueue() {
        guard listener == nil, status != .starting else { return }
        setStatus(.starting)
        listen(on: BridgeProtocol.ports(base: configuration.basePort, count: configuration.portCount)[...])
    }

    private func listen(on ports: ArraySlice<UInt16>) {
        guard let port = ports.first, let nwPort = NWEndpoint.Port(rawValue: port) else {
            let range = BridgeProtocol.ports(base: configuration.basePort, count: configuration.portCount)
            Self.log.error("Bridge: no free port in \(range.first ?? 0)–\(range.last ?? 0)")
            setStatus(.failed("no free port"))
            return
        }
        let parameters = NWParameters.tcp
        // A restart right after quitting finds the port in TIME_WAIT; reuse
        // never lets two listeners share it (each bind is exclusive).
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.acceptLocalOnly = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = BridgeProtocol.maximumMessageSize
        let policy = configuration.policy
        webSocket.setClientRequestHandler(queue) { _, headers in
            let decision = policy.evaluate(headers: headers)
            guard decision.isAccepted else {
                if case .reject(let reason) = decision {
                    let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value ?? "none"
                    Self.log.notice("Bridge: refused a connection (\(reason); origin \(origin))")
                }
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            listen(on: ports.dropFirst())
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.listeningPort = port
                self.setStatus(.listening(port: port))
                Self.log.info("Bridge: listening on 127.0.0.1:\(port)")
            case .failed(let error), .waiting(let error):
                listener.cancel()
                self.listener = nil
                Self.log.info("Bridge: port \(port) is not available (\(error.localizedDescription))")
                self.listen(on: ports.dropFirst())
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func stopOnQueue(status newStatus: Status) {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        for (id, connection) in connections {
            connection.cancel()
            _ = registry.closed(id)
        }
        connections = [:]
        clientPorts = [:]
        for (_, entry) in pending { entry.continuation.resume(returning: nil) }
        pending = [:]
        timer?.cancel()
        timer = nil
        timerDeadline = nil
        setStatus(newStatus)
        publishTabs()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        // A browser needs one connection per profile; anything beyond a
        // handful is not an extension.
        guard connections.count < Self.maximumConnections else {
            Self.log.notice("Bridge: refused a connection (already \(connections.count) open)")
            connection.cancel()
            return
        }
        let id = nextConnectionID
        nextConnectionID += 1
        connections[id] = connection
        if case .hostPort(_, let port) = connection.endpoint { clientPorts[id] = port.rawValue }
        registry.opened(id, at: clock())
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(on: id)
            case .failed, .cancelled:
                self.connectionEnded(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        rescheduleTimer()
    }

    private func receive(on id: Int) {
        guard let connection = connections[id] else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                Self.log.debug("Bridge: connection \(id) ended (\(error.localizedDescription))")
                connection.cancel()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            // A close frame, or the other side went away without one (a
            // final, empty receive; the next one would fail).
            if metadata?.opcode == .close || (context?.isFinal == true && (data?.isEmpty ?? true)) {
                connection.cancel()
                return
            }
            if let data, !data.isEmpty, metadata?.opcode == .text || metadata?.opcode == .binary {
                self.handle(data, from: id)
            }
            if self.connections[id] != nil { self.receive(on: id) }
        }
    }

    private func handle(_ data: Data, from id: Int) {
        let message: BridgeInbound
        do {
            message = try BridgeInbound.decode(data)
        } catch {
            Self.log.debug("Bridge: unreadable message from connection \(id) (\(data.count) bytes)")
            return
        }
        if case .hello(let hello) = message {
            let browser = hello.browser.name.isEmpty ? "a browser" : hello.browser.name
            Self.log.info("Bridge: \(browser) says hello (extension \(hello.extensionVersion), protocol \(hello.protocolVersion))")
            if ExtensionVersion.needsReload(reported: hello.extensionVersion) {
                Self.log.notice("Bridge: \(browser) runs extension \(hello.extensionVersion), older than the \(ExtensionVersion.shipped) Ahenk carries; it was told, and reloads itself where the browser reads the folder again")
            }
        }
        apply(registry.received(message, from: id, at: clock()))
    }

    private func connectionEnded(_ id: Int) {
        guard connections.removeValue(forKey: id) != nil else { return }
        clientPorts[id] = nil
        for (key, entry) in pending where entry.connection == id {
            pending[key] = nil
            entry.continuation.resume(returning: nil)
        }
        apply(registry.closed(id))
        Self.log.info("Bridge: a browser disconnected (\(connections.count) still connected)")
        rescheduleTimer()
        publishSummaries()
    }

    private func apply(_ effects: [BridgeRegistry.Effect]) {
        var tabsChanged = false
        for effect in effects {
            switch effect {
            case .send(let message, let id):
                send(message, to: id)
            case .close(let id, let reason):
                Self.log.info("Bridge: closing connection \(id) (\(reason))")
                if let connection = connections[id] {
                    // Let a queued error message leave first.
                    queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
                }
            case .identify(let id):
                identify(id)
            case .tabsChanged:
                tabsChanged = true
            case .lyrics(let lyrics, let tabKey):
                // Counts only: lyrics are never written to the log.
                Self.log.info("Bridge: the site sent synced lyrics (\(lyrics.lines.count) lines)")
                lyricsContinuations.values.forEach { $0.yield((tabKey, lyrics)) }
            case .result(let result, let id):
                if let entry = pending[result.id], entry.connection == id {
                    pending[result.id] = nil
                    entry.continuation.resume(returning: result)
                }
            }
        }
        if tabsChanged { publishTabs() }
        publishSummaries()
        rescheduleTimer()
    }

    private func identify(_ id: Int) {
        guard let identifier, let hello = registry.connections[id]?.hello,
              let clientPort = clientPorts[id], let serverPort = listeningPort
        else {
            apply(registry.identified(id, as: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = identifier(clientPort, serverPort, hello)
            guard let self else { return }
            self.queue.async {
                if let found {
                    Self.log.info("Bridge: connection \(id) is \(found.bundleIdentifier) (pid \(found.processIdentifier))")
                } else {
                    Self.log.notice("Bridge: could not tell which browser connection \(id) belongs to")
                }
                self.apply(self.registry.identified(id, as: found))
            }
        }
    }

    private func send(_ message: BridgeOutbound, to id: Int) {
        guard let connection = connections[id], let data = try? message.encoded() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { Self.log.debug("Bridge: send to connection \(id) failed (\(error.localizedDescription))") }
        })
    }

    // MARK: Timer (only while connections exist)

    private func rescheduleTimer() {
        guard let deadline = registry.nextDeadline else {
            timer?.cancel()
            timer = nil
            timerDeadline = nil
            return
        }
        guard deadline != timerDeadline else { return }
        timer?.cancel()
        timerDeadline = deadline
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(0.05, deadline.timeIntervalSince(clock()) + 0.02)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.timerDeadline = nil
            self.apply(self.registry.tick(now: self.clock()))
        }
        self.timer = timer
        timer.resume()
    }

    // MARK: Publishing

    private func setStatus(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        statusContinuations.values.forEach { $0.yield(status) }
    }

    private func publishTabs() {
        let reports = registry.reports(now: clock())
        guard reports != lastReports else { return }
        lastReports = reports
        tabContinuations.values.forEach { $0.yield(reports) }
    }

    private func publishSummaries() {
        guard !summaryContinuations.isEmpty else { return }
        let summaries = registry.summaries(now: clock())
        summaryContinuations.values.forEach { $0.yield(summaries) }
    }

    // MARK: BrowserBridge

    public func tabs() -> AsyncStream<[BrowserTabReport]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[BrowserTabReport]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        queue.async {
            self.tabContinuations[key] = continuation
            continuation.yield(self.lastReports)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.tabContinuations[key] = nil }
        }
        return stream
    }

    /// The listener's state, now and on every change.
    public func statusUpdates() -> AsyncStream<Status> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(4))
        queue.async {
            self.statusContinuations[key] = continuation
            continuation.yield(self.status)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.statusContinuations[key] = nil }
        }
        return stream
    }

    /// The connected browsers and their tabs (Settings › Sources).
    public func summaries() -> AsyncStream<[BridgeBrowserSummary]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[BridgeBrowserSummary]>.makeStream(bufferingPolicy: .bufferingNewest(2))
        queue.async {
            self.summaryContinuations[key] = continuation
            continuation.yield(self.registry.summaries(now: self.clock()))
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.summaryContinuations[key] = nil }
        }
        return stream
    }

    /// Synced lyrics that a site loaded for the song in a tab.
    public func lyricsUpdates() -> AsyncStream<(tabKey: String, lyrics: BridgeSiteLyrics)> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<(tabKey: String, lyrics: BridgeSiteLyrics)>.makeStream(bufferingPolicy: .bufferingNewest(4))
        queue.async { self.lyricsContinuations[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.lyricsContinuations[key] = nil }
        }
        return stream
    }

    /// The tabs right now.
    public var currentTabs: [BrowserTabReport] { queue.sync { lastReports } }

    /// The browsers that said hello, right now.
    public var connectedBrowsers: [BridgeBrowserSummary] { queue.sync { registry.summaries(now: clock()) } }

    public func send(_ command: PlaybackCommand, toTab tabKey: String) async -> Bool {
        let result = await perform(timeout: configuration.commandTimeout) { id -> (Int, BridgeOutbound)? in
            guard let (connection, tabID) = self.registry.locate(tabKey: tabKey) else { return nil }
            return (connection, .command(BridgeCommand(id: id, tabID: tabID, playback: command)))
        }
        return result?.ok == true
    }

    /// Asks a tab to play at `rate` times the song's own speed (the sound
    /// effects' speed presets). False when the tab is gone, has no media
    /// element to speed up, or its extension is too old to know the command.
    public func setRate(_ rate: Double, forTab tabKey: String) async -> Bool {
        let result = await perform(timeout: configuration.commandTimeout) { id -> (Int, BridgeOutbound)? in
            guard let (connection, tabID) = self.registry.locate(tabKey: tabKey) else { return nil }
            return (connection, .command(BridgeCommand(id: id, tabID: tabID, rate: rate)))
        }
        return result?.ok == true
    }

    /// Asks a tab for `seconds` of the sound its player holds for the song
    /// it plays, from `from` seconds of it (`BridgeRequest.Kind.sound`).
    /// `nil`: the tab is gone, plays another song, or did not answer.
    public func heldSound(inTab tabKey: String, from: Double, seconds: Double, timeout: TimeInterval = 8) async -> BridgeResult? {
        await perform(timeout: timeout) { id -> (Int, BridgeOutbound)? in
            guard let (connection, tabID) = self.registry.locate(tabKey: tabKey),
                  let report = self.lastReports.first(where: { $0.tabID == tabKey }),
                  let site = BrowserSite(source: report.site), let track = report.siteTrackID
            else { return nil }
            let song = BridgeSong(title: report.title, artist: report.artist, trackID: track)
            return (connection, .request(BridgeRequest(id: id, kind: .sound, site: site.rawValue, tabID: tabID, song: song, from: max(0, from), seconds: seconds)))
        }
    }

    /// Sends a request to one connection and waits for its answer (`nil`:
    /// no answer in time, or the connection went away).
    public func request(_ make: @escaping @Sendable (String) -> BridgeRequest, on connection: Int, timeout: TimeInterval) async -> BridgeResult? {
        await perform(timeout: timeout) { id in
            guard self.connections[connection] != nil else { return nil }
            return (connection, .request(make(id)))
        }
    }

    private func perform(timeout: TimeInterval, _ build: @escaping @Sendable (String) -> (Int, BridgeOutbound)?) async -> BridgeResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<BridgeResult?, Never>) in
            queue.async {
                let id = "r\(self.nextRequestID)"
                self.nextRequestID += 1
                guard let (connection, message) = build(id) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.pending[id] = (connection, continuation)
                self.send(message, to: connection)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let entry = self.pending.removeValue(forKey: id) else { return }
                    entry.continuation.resume(returning: nil)
                }
            }
        }
    }
}
