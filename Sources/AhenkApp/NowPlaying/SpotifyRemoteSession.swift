import AhenkKit
import AppKit
import Observation
import WebKit

/// The user's Spotify sign-in for starting songs in the background (see
/// ``SpotifyRemote``): a sign-in window with Spotify's own page, the web
/// player's session read from a web view that is never shown, and the
/// command itself.
///
/// The web view is loaded only to read a session (about once an hour while
/// songs are being picked) and let go right after, so nothing of the web
/// player stays in memory. The sign-in is kept by WebKit, like a browser
/// keeps it; Ahenk never sees the password.
@MainActor
@Observable
final class SpotifyRemoteSession: NSObject, WKNavigationDelegate, NSWindowDelegate {
    enum Status: Equatable {
        case signedOut
        case connected
    }

    private(set) var status: Status
    /// The sign-in window is open.
    private(set) var isSigningIn = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = AhenkLogger(category: "player")
    @ObservationIgnored private var session: SpotifyRemote.Session?
    @ObservationIgnored private var reading: Task<SpotifyRemote.Session?, Never>?
    @ObservationIgnored private var reader: WKWebView?
    /// Ahenk's remote as Spotify knows it, and where the app on this Mac is.
    @ObservationIgnored private var route: (deviceID: String, connectionID: String, target: String, at: Date)?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var loginView: WKWebView?
    @ObservationIgnored private var loginWatch: Task<Void, Never>?
    @ObservationIgnored private var lookedForSignIn = false
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var routeKeeper: Task<Void, Never>?
    @ObservationIgnored private var routeFailedAt: Date?

    private static let signedInKey = "spotifyRemoteSignedIn"
    private static let offeredKey = "spotifyRemoteOffered"
    private static let usernameKey = "spotifyRemoteUsername"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let readTimeout: TimeInterval = 12
    private static let routeLifetime: TimeInterval = 300
    /// How often the route's age is looked at.
    private static let routeCheck: TimeInterval = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = defaults.bool(forKey: Self.signedInKey) ? .connected : .signedOut
    }

    var isConnected: Bool { status == .connected }

    // MARK: Signing in

    /// Shows Spotify's sign-in page in a window of Ahenk's.
    func signIn() {
        defaults.set(true, forKey: Self.offeredKey)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let webView = makeWebView(persistent: true)
        webView.navigationDelegate = self
        loginView = webView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Connect Spotify".l10n
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = Self.signInContent(webView: webView)
        window.center()
        self.window = window
        isSigningIn = true
        webView.load(URLRequest(url: SpotifyRemote.loginURL))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        log.info("Showing Spotify's sign-in")
        watchSignIn(in: webView)
    }

    /// Shows the sign-in once to someone who plays in Spotify and has
    /// never been asked (picking Spotify in the player asks every time).
    func offerOnce() {
        guard !isConnected, !defaults.bool(forKey: Self.offeredKey) else { return }
        signIn()
    }

    /// Forgets the sign-in: Spotify's cookies and data leave Ahenk.
    func signOut() {
        session = nil
        route = nil
        refresh?.cancel()
        defaults.removeObject(forKey: Self.usernameKey)
        setStatus(.signedOut)
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let spotify = records.filter { $0.displayName.contains("spotify") || $0.displayName.contains("scdn") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: spotify) {}
        }
        log.info("Signed out of Spotify")
    }

    private static func signInContent(webView: WKWebView) -> NSView {
        let note = NSTextField(wrappingLabelWithString: "Sign in once so Ahenk can start songs in Spotify without bringing Spotify to the front. Ahenk never sees your password.".l10n)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(note)
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            webView.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    /// Closes the window as soon as the web player answers with the
    /// session of a signed-in user.
    private func watchSignIn(in webView: WKWebView) {
        loginWatch?.cancel()
        loginWatch = Task { [weak self, weak webView] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let webView, self.loginView === webView else { return }
                // Spotify's account page after a sign-in ("you are signed
                // in"): on to the web player, which hands out the session.
                if let url = webView.url, url.host == "accounts.spotify.com", url.path.contains("/status"), !webView.isLoading {
                    webView.load(URLRequest(url: SpotifyRemote.webPlayerURL))
                    continue
                }
                guard webView.url?.host == SpotifyRemote.webPlayerHost,
                      let found = await self.readSession(in: webView), found.isSignedIn
                else { continue }
                self.session = found
                self.setStatus(.connected)
                self.scheduleRefresh(for: found)
                self.keepRouteReady()
                self.log.info("Signed in to Spotify")
                self.window?.close()
                return
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        loginWatch?.cancel()
        loginWatch = nil
        loginView?.navigationDelegate = nil
        loginView?.loadHTMLString("", baseURL: nil)
        loginView = nil
        window?.contentView = nil
        window = nil
        isSigningIn = false
        // Closed by hand: the next song looks whether the sign-in is there.
        lookedForSignIn = false
    }

    // MARK: Keeping the session ready

    /// Reads the session ahead of the first song (at launch), so a pick
    /// never waits for the web player to load; also finds a sign-in whose
    /// window was closed before the web player answered.
    func warmUp() {
        guard isConnected || (defaults.bool(forKey: Self.offeredKey) && !lookedForSignIn) else { return }
        lookedForSignIn = true
        Task { _ = await currentSession() }
        keepRouteReady()
    }

    /// Keeps the way to the Spotify app open while that app runs, so a
    /// pick is one request away: asked again a little before it would go
    /// stale. Three small requests each time; nothing while Spotify is
    /// closed or the user is signed out.
    private func keepRouteReady() {
        guard routeKeeper == nil else { return }
        routeKeeper = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.isConnected,
                   !NSRunningApplication.runningApplications(withBundleIdentifier: KnownApps.spotify).isEmpty,
                   self.route.map({ Date().timeIntervalSince($0.at) > Self.routeLifetime - Self.routeCheck * 1.5 }) ?? true,
                   self.routeFailedAt.map({ Date().timeIntervalSince($0) > Self.routeLifetime }) ?? true,
                   let session = await self.currentSession() {
                    self.route = nil
                    // Not there (Spotify signed in to another account,
                    // offline): asked again in a few minutes, not at once.
                    self.routeFailedAt = await self.currentRoute(session: session) == nil ? Date() : nil
                }
                try? await Task.sleep(for: .seconds(Self.routeCheck))
            }
        }
    }

    /// Reads a new session a few minutes before this one ends (about once
    /// an hour), so there is always a good one.
    private func scheduleRefresh(for session: SpotifyRemote.Session) {
        refresh?.cancel()
        guard let expiresAt = session.expiresAt else { return }
        let wait = max(60, expiresAt.timeIntervalSinceNow - 300)
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.isConnected else { return }
            self.session = nil
            _ = await self.currentSession()
        }
    }

    /// The web player's session for a signed-in user (lyrics are asked
    /// with it); `nil` without the sign-in.
    func signedInSession() async -> SpotifyRemote.Session? {
        guard isConnected else { return nil }
        return await currentSession()
    }

    // MARK: Liked Songs

    /// Whether the song is among the user's Liked Songs; `nil` when it
    /// cannot be asked (not signed in, Spotify did not answer).
    func isLiked(trackID: String) async -> Bool? {
        guard isConnected, let session = await librarySession(),
              let request = SpotifyRemote.likedRequest(session: session, trackID: trackID),
              let answer = await Self.send(request), (200..<300).contains(answer.status)
        else { return nil }
        return SpotifyRemote.isLiked(fromJSON: answer.data)
    }

    /// Adds the song to Liked Songs or takes it out. `false`: not done.
    func setLiked(_ liked: Bool, trackID: String) async -> Bool {
        guard isConnected, let session = await librarySession(),
              let request = SpotifyRemote.likeRequest(session: session, trackID: trackID, liked: liked, at: Date()),
              let answer = await Self.send(request), (200..<300).contains(answer.status)
        else {
            log.notice("Spotify did not take the change to Liked Songs")
            return false
        }
        log.info(liked ? "Added the song to Spotify's Liked Songs" : "Took the song out of Spotify's Liked Songs")
        return true
    }

    /// The session with the account's user name: the page names it in
    /// some loads only, so the last one seen is kept.
    private func librarySession() async -> SpotifyRemote.Session? {
        guard var session = await currentSession() else { return nil }
        if let username = session.username {
            defaults.set(username, forKey: Self.usernameKey)
        } else {
            session.username = defaults.string(forKey: Self.usernameKey)
        }
        return session.username == nil ? nil : session
    }

    /// The library can be asked (signed in, and the account's name is known).
    var knowsLibrary: Bool {
        isConnected && (session?.username ?? defaults.string(forKey: Self.usernameKey)) != nil
    }

    // MARK: Playing

    /// Starts the song in the Spotify app on this Mac, in the background.
    /// `false` when it could not be sent (not signed in, the app is not
    /// among the account's devices, Spotify said no): the caller then
    /// starts it the old way.
    func play(trackID: String) async -> Bool {
        if !isConnected {
            // The sign-in window may have been closed before the web
            // player answered: look once whether the sign-in is there.
            guard defaults.bool(forKey: Self.offeredKey), !lookedForSignIn else { return false }
            lookedForSignIn = true
            guard let found = await currentSession(), found.isSignedIn else { return false }
        }
        let started = Date()
        for attempt in 0..<2 {
            guard let session = await currentSession() else { return false }
            guard let route = await currentRoute(session: session) else {
                if attempt == 0, self.session != nil {
                    // A session Spotify no longer takes: read a new one.
                    self.session = nil
                    continue
                }
                return false
            }
            guard let request = SpotifyRemote.playRequest(
                session: session, trackID: trackID, from: route.deviceID, to: route.target, commandID: SpotifyRemote.randomID()
            ) else { return false }
            if let status = await Self.send(request)?.status, (200..<300).contains(status) {
                log.info("Spotify took the song in the background (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
                return true
            }
            self.route = nil
            if attempt == 0 { self.session = nil }
        }
        log.notice("Spotify did not take the song in the background; starting it through the app")
        return false
    }

    private func currentRoute(session: SpotifyRemote.Session) async -> (deviceID: String, connectionID: String, target: String)? {
        if let route, Date().timeIntervalSince(route.at) < Self.routeLifetime {
            return (route.deviceID, route.connectionID, route.target)
        }
        route = nil
        let deviceID = SpotifyRemote.randomID()
        guard let connectionID = await Self.connectionID(session: session),
              let register = SpotifyRemote.registerRequest(session: session, deviceID: deviceID, connectionID: connectionID),
              let registered = await Self.send(register), (200..<300).contains(registered.status),
              let ask = SpotifyRemote.stateRequest(session: session, deviceID: deviceID, connectionID: connectionID),
              let answer = await Self.send(ask), (200..<300).contains(answer.status),
              let devices = SpotifyRemote.devices(fromJSON: answer.data)
        else {
            log.notice("Spotify's remote did not answer")
            return nil
        }
        let name = Host.current().localizedName ?? ""
        guard let target = SpotifyRemote.target(in: devices, computerName: name, ownDeviceID: deviceID) else {
            log.notice("The Spotify app on this Mac is not among the account's \(devices.count) devices")
            return nil
        }
        route = (deviceID, connectionID, target, Date())
        return (deviceID, connectionID, target)
    }

    private static func send(_ request: URLRequest) async -> (data: Data, status: Int)? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (data, http.statusCode)
    }

    /// The connection ID Spotify's message socket hands out first.
    private static func connectionID(session: SpotifyRemote.Session) async -> String? {
        guard let url = SpotifyRemote.dealerURL(accessToken: session.accessToken) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel() }
        for _ in 0..<4 {
            guard let message = try? await socket.receive() else { return nil }
            if case .string(let text) = message, let id = SpotifyRemote.connectionID(fromDealerMessage: text) { return id }
        }
        return nil
    }

    // MARK: The web player's session

    private func currentSession() async -> SpotifyRemote.Session? {
        if let session, session.isFresh(at: Date()) { return session }
        if let reading { return await reading.value }
        let task = Task { @MainActor [weak self] () -> SpotifyRemote.Session? in
            await self?.loadSession()
        }
        reading = task
        let found = await task.value
        reading = nil
        return found
    }

    /// Loads the web player off screen and reads its session.
    private func loadSession() async -> SpotifyRemote.Session? {
        let webView = makeWebView(persistent: true)
        webView.navigationDelegate = self
        reader = webView
        defer {
            webView.navigationDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            reader = nil
        }
        let started = Date()
        webView.load(URLRequest(url: SpotifyRemote.webPlayerURL, timeoutInterval: Self.readTimeout))
        while Date().timeIntervalSince(started) < Self.readTimeout {
            try? await Task.sleep(for: .milliseconds(250))
            guard let found = await readSession(in: webView) else { continue }
            guard found.isSignedIn else {
                log.notice("Spotify's sign-in is gone; songs start through the app until you sign in again")
                session = nil
                setStatus(.signedOut)
                return nil
            }
            // The client token follows the session by a moment.
            if found.clientToken == nil, Date().timeIntervalSince(started) < Self.readTimeout - 3 { continue }
            // The account's name shows in a request a moment later still.
            if found.username == nil, defaults.string(forKey: Self.usernameKey) == nil, Date().timeIntervalSince(started) < 6 { continue }
            log.info("Read Spotify's session in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            session = found
            setStatus(.connected)
            scheduleRefresh(for: found)
            keepRouteReady()
            return found
        }
        log.notice("Spotify's web player gave no session in \(Int(Self.readTimeout)) s")
        return nil
    }

    private func readSession(in webView: WKWebView) async -> SpotifyRemote.Session? {
        let text: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(SpotifyRemote.sessionReadScript) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        return text.flatMap(SpotifyRemote.session(fromJSON:))
    }

    private func makeWebView(persistent: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent ? .default() : .nonPersistent()
        // The web player must never play anything itself.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: SpotifyRemote.sessionHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        return webView
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        defaults.set(new == .connected, forKey: Self.signedInKey)
    }

    // MARK: WKNavigationDelegate

    /// The reading web view loads Spotify's own pages only. The sign-in
    /// window follows wherever signing in leads (Google, Apple, Facebook).
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === reader, navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        let url = navigationAction.request.url
        let allowed = url?.host?.hasSuffix("spotify.com") == true || url?.scheme == "about"
        decisionHandler(allowed ? .allow : .cancel)
    }
}
