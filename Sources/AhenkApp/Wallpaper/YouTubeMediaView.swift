import AhenkKit
import AppKit
import WebKit

/// A YouTube video on one display: YouTube's embedded player
/// (privacy-enhanced, muted, no controls) in a web view that never takes a
/// click. The page is loaded with the app's bundle ID as its origin, which
/// YouTube asks of apps that embed its player (see `YouTubeEmbed`).
///
/// The player chooses its quality from its size, so the web view is laid
/// out smaller than the screen and scaled up: about 1080p normally, 720p
/// when running lighter (the wallpaper is dimmed; 4K would only cost power).
/// Nothing is stored: the web view uses a private, in-memory data store.
@MainActor
final class YouTubeMediaView: WallpaperMediaView {
    /// The player's title and channel fade a few seconds after it starts;
    /// the layer waits for that before it shows the video.
    static let settleDelay: TimeInterval = 2.5
    /// A video that has not started by then counts as failed.
    static let startTimeout: TimeInterval = 20

    private let videoID: String
    private let origin: URL
    private var start: TimeInterval
    private var loops: Bool
    private var plan: WallpaperPowerPlan
    private let canvas = NSView()
    private var webView: WKWebView?
    private var messages: MessageProxy?
    private var wantsPlaying = false
    private var lastDuration: TimeInterval?
    private var settle: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private static let log = AhenkLogger(category: "wallpaper")

    /// One in-memory store for every wallpaper web view: nothing reaches the
    /// disk, and YouTube's script is fetched once per run.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// Mutes every media element in every frame (the player's frame too)
    /// before the page's own scripts run: the wallpaper is never heard, on
    /// top of the player's own `mute`.
    private static let muteScript = WKUserScript(
        source: """
        (function () {
          var reported = '';
          var hush = function (event) {
            var media = event.target;
            if (media && (media.tagName === 'VIDEO' || media.tagName === 'AUDIO')) {
              if (!media.muted) media.muted = true;
              if (media.volume !== 0) media.volume = 0;
              // What the element really does, once per change (the app logs it).
              var state = media.muted + '/' + media.volume;
              if (state !== reported) {
                reported = state;
                try {
                  window.webkit.messageHandlers.\(YouTubeEmbed.messageHandler).postMessage({ type: 'media', muted: media.muted, volume: media.volume });
                } catch (e) {}
              }
            }
          };
          ['play', 'playing', 'volumechange', 'loadedmetadata'].forEach(function (name) {
            document.addEventListener(name, hush, true);
          });
        })();
        """,
        injectionTime: .atDocumentStart, forMainFrameOnly: false
    )

    init(candidate: WallpaperCandidate, videoID: String, start: TimeInterval, loops: Bool, plan: WallpaperPowerPlan, frame: NSRect) {
        self.videoID = videoID
        self.start = start
        self.loops = loops
        self.plan = plan
        origin = YouTubeEmbed.origin(bundleIdentifier: AppInfo.bundleIdentifier)
        super.init(candidate: candidate, frame: frame)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(canvas)
        load()
    }

    override func layout() {
        super.layout()
        layoutCanvas()
    }

    /// The web view at a size whose player asks for at most
    /// `plan.maximumVideoSide` pixels, scaled up to cover the view.
    private func layoutCanvas() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // The player covers the screen at 16:9, so its width is the larger
        // of the two.
        let playerWidth = max(size.width, size.height * 16 / 9) * scale
        let factor = max(1, playerWidth / CGFloat(max(320, plan.maximumVideoSide)))
        canvas.frame = bounds
        canvas.bounds = CGRect(origin: .zero, size: CGSize(width: size.width / factor, height: size.height / factor))
        webView?.frame = canvas.bounds
    }

    private func load() {
        guard let page = YouTubeEmbed.page(videoID: videoID, start: start, loops: loops, origin: origin) else {
            fail(.thisVideo("not a video ID"))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.suppressesIncrementalRendering = false
        let proxy = MessageProxy(owner: self)
        configuration.userContentController.add(proxy, name: YouTubeEmbed.messageHandler)
        configuration.userContentController.addUserScript(Self.muteScript)
        messages = proxy
        let webView = WKWebView(frame: canvas.bounds, configuration: configuration)
        webView.navigationDelegate = proxy
        webView.uiDelegate = proxy
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.setAccessibilityElement(false)
        canvas.addSubview(webView)
        self.webView = webView
        layoutCanvas()
        webView.loadHTMLString(page, baseURL: origin)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            self.fail(.thisVideo("did not start"))
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout, execute: timeout)
    }

    // MARK: Control

    override func setPlaying(_ playing: Bool) {
        guard playing != wantsPlaying else { return }
        wantsPlaying = playing
        run(playing ? "window.ahenk && window.ahenk.play()" : "window.ahenk && window.ahenk.pause()")
    }

    override func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        start = max(0, seconds)
        run("window.ahenk && window.ahenk.seek(\(String(format: "%.2f", start)))")
    }

    override func setLoops(_ loops: Bool) {
        guard loops != self.loops else { return }
        self.loops = loops
        run("window.ahenk && window.ahenk.setLoops(\(loops ? "true" : "false"))")
    }

    override func apply(_ plan: WallpaperPowerPlan) {
        guard plan.maximumVideoSide != self.plan.maximumVideoSide else { return }
        self.plan = plan
        layoutCanvas()
    }

    override func position(_ answer: @escaping @MainActor (TimeInterval?, TimeInterval?) -> Void) {
        guard let webView, isReady else {
            answer(nil, lastDuration)
            return
        }
        webView.evaluateJavaScript("window.ahenk ? window.ahenk.status() : null") { [weak self] result, _ in
            MainActor.assumeIsolated {
                let status = result as? [String: Any]
                let time = (status?["time"] as? NSNumber)?.doubleValue
                let reported = (status?["duration"] as? NSNumber)?.doubleValue
                let duration = reported.flatMap { $0 > 0 ? $0 : nil } ?? self?.lastDuration
                answer(time.flatMap { $0.isFinite ? $0 : nil }, duration)
            }
        }
    }

    var duration: TimeInterval? { lastDuration }

    override func tearDown() {
        super.tearDown()
        settle?.cancel()
        timeout?.cancel()
        if let webView {
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: YouTubeEmbed.messageHandler)
            webView.configuration.userContentController.removeAllUserScripts()
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webView = nil
        messages = nil
    }

    private func run(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: The page's messages

    fileprivate func received(_ body: Any) {
        if let message = body as? [String: Any], message["type"] as? String == "media" {
            let muted = message["muted"] as? Bool ?? false
            let volume = (message["volume"] as? NSNumber)?.doubleValue ?? 1
            if muted, volume == 0 {
                Self.log.info("Wallpaper video element: muted, volume 0")
            } else {
                Self.log.error("Wallpaper video element not silent (muted \(muted), volume \(volume)); muting again")
                run("window.ahenk && window.ahenk.play()")
            }
            return
        }
        guard let event = YouTubeEmbed.event(from: body) else { return }
        switch event {
        case .ready(let duration):
            lastDuration = duration ?? lastDuration
            if !wantsPlaying { run("window.ahenk && window.ahenk.pause()") }
        case .state(let state, _, let duration, let muted):
            lastDuration = duration ?? lastDuration
            if muted == false { run("window.ahenk && window.ahenk.play()") }
            if state == .playing, !isReady, settle == nil {
                timeout?.cancel()
                let settle = DispatchWorkItem { [weak self] in self?.markReady() }
                self.settle = settle
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: settle)
            }
            if state == .playing, !wantsPlaying {
                run("window.ahenk && window.ahenk.pause()")
            }
        case .error(let failure):
            Self.log.info("YouTube player error for a wallpaper video: \(String(describing: failure))")
            fail(failure.isAboutThisVideo ? .thisVideo(String(describing: failure)) : .everyVideo(String(describing: failure)))
        }
    }

    fileprivate func loadFailed(_ error: Error) {
        fail(.everyVideo(error.localizedDescription))
    }

    /// The page stays the player: links (the player's own "watch on
    /// YouTube") never open in the wallpaper.
    fileprivate static func allows(_ action: WKNavigationAction) -> Bool {
        if action.targetFrame?.isMainFrame == false { return true }
        guard let url = action.request.url else { return false }
        return url.scheme == "about" || url.host == YouTubeEmbed.origin(bundleIdentifier: AppInfo.bundleIdentifier).host
    }
}

/// Keeps WebKit's strong references off the media view, so tearing it down
/// releases everything.
private final class MessageProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var owner: YouTubeMediaView?

    init(owner: YouTubeMediaView) {
        self.owner = owner
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.received(body) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(MainActor.assumeIsolated { YouTubeMediaView.allows(navigationAction) } ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { owner?.loadFailed(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { owner?.loadFailed(URLError(.cancelled)) }
    }

    /// Never a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
