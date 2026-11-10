import AhenkKit
import AppKit
import WebKit

/// Reads Spotify's search page in a web view that is never shown: no
/// window, no account, nothing kept on disk, nothing played. One page at a
/// time; the web view is let go half a minute after the last search, so
/// its processes do not stay around.
final class SpotifySearchWebReader: SpotifySearchPageReading {
    func rows(for url: URL) async -> [SpotifySearchRow]? {
        await Session.shared.rows(for: url)
    }

    @MainActor
    private final class Session: NSObject, WKNavigationDelegate {
        static let shared = Session()

        /// How long the page gets to list its songs.
        static let timeout: TimeInterval = 10
        static let pollInterval: Duration = .milliseconds(250)
        /// The web view stays this long after a search (the next pick is
        /// often seconds away).
        static let keepAlive: TimeInterval = 30
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        private let log = AhenkLogger(category: "catalog")
        private var webView: WKWebView?
        private var last: Task<Void, Never>?
        private var release: Task<Void, Never>?
        /// The load of the search that is being read, and whether its page
        /// has replaced the one before it.
        private var current: WKNavigation?
        private var committed = false
        private var failed = false

        func rows(for url: URL) async -> [SpotifySearchRow]? {
            let previous = last
            let task = Task { @MainActor () -> [SpotifySearchRow]? in
                await previous?.value
                return await self.read(url)
            }
            last = Task { _ = await task.value }
            return await task.value
        }

        private func read(_ url: URL) async -> [SpotifySearchRow]? {
            guard url.host == SpotifySearchPage.host else { return nil }
            release?.cancel()
            defer { scheduleRelease() }
            let webView = self.webView ?? makeWebView()
            self.webView = webView
            failed = false
            committed = false
            let started = Date()
            current = webView.load(URLRequest(url: url, timeoutInterval: Self.timeout))
            defer { current = nil }
            while Date().timeIntervalSince(started) < Self.timeout, !failed {
                try? await Task.sleep(for: Self.pollInterval)
                // The page of this search, not the one before it.
                guard committed, webView.url?.path.contains("/search/") == true else { continue }
                if let text = await evaluate(SpotifySearchPage.readScript, in: webView),
                   let rows = SpotifySearchPage.rows(fromJSON: text), !rows.isEmpty {
                    log.info("Spotify's search page answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    webView.loadHTMLString("", baseURL: nil)
                    return rows
                }
            }
            log.notice("Spotify's search page listed no songs in \(Int(Date().timeIntervalSince(started))) s\(failed ? " (it did not load)" : "")")
            webView.loadHTMLString("", baseURL: nil)
            return nil
        }

        private func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.allowsAirPlayForMediaPlayback = false
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
            webView.customUserAgent = Self.userAgent
            webView.navigationDelegate = self
            return webView
        }

        private func evaluate(_ script: String, in webView: WKWebView) async -> String? {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? String)
                }
            }
        }

        private func scheduleRelease() {
            release?.cancel()
            release = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.keepAlive))
                guard !Task.isCancelled else { return }
                self?.webView?.navigationDelegate = nil
                self?.webView = nil
            }
        }

        // MARK: WKNavigationDelegate

        /// Only Spotify's own pages load in the main frame; a link that
        /// leads elsewhere is not followed.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame != false else {
                decisionHandler(.allow)
                return
            }
            let url = navigationAction.request.url
            let allowed = url?.host == SpotifySearchPage.host || url?.scheme == "about"
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if navigation === current { committed = true }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === current { failed = true }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === current { failed = true }
        }
    }
}
