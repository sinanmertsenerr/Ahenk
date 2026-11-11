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
    /// A moment for the first frames after the player says it plays (its
    /// own title and buttons are hidden, see `pictureOnlyScript`).
    static let settleDelay: TimeInterval = 0.4
    /// A video that has not started by then counts as failed.
    static let startTimeout: TimeInterval = 20

    private let videoID: String
    private let origin: URL
    private var start: TimeInterval
    private var loops: Bool
    private var plan: WallpaperPowerPlan
    /// The wallpaper runs under whatever covers it; the player's clip is
    /// left to WebKit, which pauses a covered silent video by itself.
    private var playsWhenCovered: Bool
    /// The player's sound is held as it arrives, to be read (`sound`).
    let hearsSound: Bool
    private var soundAnswers: [Int: CheckedContinuation<ClipSoundAnswer, Never>] = [:]
    private var nextSoundID = 1
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
          // The picture's size and how many frames a second really show.
          var measured = false;
          document.addEventListener('playing', function (event) {
            var media = event.target;
            if (measured || !media || media.tagName !== 'VIDEO') return;
            measured = true;
            var first = media.getVideoPlaybackQuality ? media.getVideoPlaybackQuality().totalVideoFrames : 0;
            setTimeout(function () {
              var q = media.getVideoPlaybackQuality ? media.getVideoPlaybackQuality() : null;
              try {
                window.webkit.messageHandlers.\(YouTubeEmbed.messageHandler).postMessage({
                  type: 'stats', width: media.videoWidth, height: media.videoHeight,
                  fps: q ? (q.totalVideoFrames - first) / 8 : 0, dropped: q ? q.droppedVideoFrames : 0,
                  box: Math.round(media.clientWidth) + 'x' + Math.round(media.clientHeight) + '@' + window.devicePixelRatio,
                  nerd: (function () {
                    try {
                      var p = document.getElementById('movie_player');
                      var n = p && p.getStatsForNerds ? p.getStatsForNerds() : null;
                      return n ? [n.codecs, n.resolution, n.color, n.optimal_res || ''].join(' | ') : 'none';
                    } catch (e) { return 'error ' + e; }
                  })()
                });
              } catch (e) {}
            }, 8000);
          }, true);
        })();
        """,
        injectionTime: .atDocumentStart, forMainFrameOnly: false
    )

    /// Inside the player's own frame, only the picture shows: its title,
    /// logo, "more videos" and end screen come back whenever it pauses,
    /// seeks or starts again, and a wallpaper has no use for them. Whatever
    /// is not the video (or does not hold it) is hidden, so a redesigned
    /// player needs no new list of names.
    private static let pictureOnlyScript = WKUserScript(
        source: """
        (function () {
          var host = location.hostname || '';
          if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(host)) return;
          var style = document.createElement('style');
          style.textContent =
            'body *:not(video):not(:has(video)) { visibility: hidden !important; opacity: 0 !important; pointer-events: none !important; }' +
            'html, body { background: #000 !important; }' +
            // The player's own title, logo, cards and end screen by name
            // as well: they are gone before the rule above is worked out
            // for a player that is still building itself.
            '.ytp-chrome-top, .ytp-chrome-bottom, .ytp-gradient-top, .ytp-gradient-bottom, .ytp-title, .ytp-watermark,' +
            '.ytp-pause-overlay, .ytp-ce-element, .ytp-cards-teaser, .ytp-cards-button, .ytp-paid-content-overlay,' +
            '.ytp-endscreen-content, .ytp-spinner, .ytp-bezel, .ytp-cued-thumbnail-overlay, .ytp-large-play-button,' +
            '.iv-branding, .annotation, .ytp-impression-link, .ytp-overflow-button, .ytp-tooltip, .ytp-popup' +
            '{ display: none !important; }';
          (document.head || document.documentElement).appendChild(style);
        })();
        """,
        injectionTime: .atDocumentStart, forMainFrameOnly: false
    )

    init(
        candidate: WallpaperCandidate, videoID: String, start: TimeInterval, loops: Bool, plan: WallpaperPowerPlan, frame: NSRect,
        playsWhenCovered: Bool = true, hearsSound: Bool = false
    ) {
        self.playsWhenCovered = playsWhenCovered
        self.hearsSound = hearsSound
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
        configuration.userContentController.addUserScript(Self.pictureOnlyScript)
        if hearsSound { Self.soundScripts.forEach(configuration.userContentController.addUserScript) }
        messages = proxy
        let webView = WKWebView(frame: canvas.bounds, configuration: configuration)
        webView.navigationDelegate = proxy
        webView.uiDelegate = proxy
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.setAccessibilityElement(false)
        if playsWhenCovered { Self.keepPlayingWhenCovered(webView) }
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

    /// WebKit counts a page in a covered window (app windows over the whole
    /// desktop, a full-screen Space) as hidden and pauses its silent video
    /// by itself; coming back, the video was behind the song by as long as
    /// it had been covered. The wallpaper runs under whatever is in front
    /// of it (see `WallpaperController.isVisible`), so the web view is told
    /// not to look at that. The setter is WebKit's own but not in its
    /// public headers: without it the video pauses as before.
    private static func keepPlayingWhenCovered(_ webView: WKWebView) {
        if !setOcclusionDetection(false, in: webView) {
            log.info("This WebKit cannot keep a covered wallpaper video playing; it will pause while covered")
        }
    }

    @discardableResult
    private static func setOcclusionDetection(_ enabled: Bool, in webView: WKWebView) -> Bool {
        let setter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: setter), let method = webView.method(for: setter) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Setter.self)(webView, setter, enabled)
        return true
    }

    // MARK: The player's sound

    /// The extension's own scripts that hold a YouTube player's audio
    /// stream as it is handed to the browser, and a reader that answers
    /// with a stretch of it. Empty when the extension's files are not
    /// there (then nothing is heard).
    private static let soundScripts: [WKUserScript] = {
        guard let sound = BrowserExtensionInstaller.script("lib/sound.js"), let hooks = BrowserExtensionInstaller.script("page/hooks.js") else { return [] }
        let reader = """
        (function () {
          if (window.top === window || !/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
          var S = window.AhenkSound, hooks = window.__ahenkHooks;
          var answer = function (message) {
            try { window.webkit.messageHandlers.\(YouTubeEmbed.messageHandler).postMessage(message); } catch (e) {}
          };
          var samplesOf = async function (held) {
            var known = held.decoded;
            if (known && known.run === held.run && known.bytes === held.bytes) return known.samples;
            var run = held.run, bytes = held.bytes;
            var context = new OfflineAudioContext({ numberOfChannels: 1, length: 1, sampleRate: S.RATE });
            var buffer = await context.decodeAudioData(S.stream(held).buffer);
            var channels = [];
            for (var i = 0; i < buffer.numberOfChannels; i += 1) channels.push(buffer.getChannelData(i));
            var samples = S.mono(channels);
            held.decoded = { run: run, bytes: bytes, samples: samples };
            return samples;
          };
          window.addEventListener('message', async function (event) {
            var ask = event.data && event.data.ahenkSound;
            if (!ask) return;
            var message = { type: 'sound', id: ask.id };
            try {
              var player = document.getElementById('movie_player');
              var held = S && hooks && hooks.sound ? hooks.sound.held(document.querySelector('video')) : null;
              if (!held) message.error = 'no sound is held (' + (hooks && hooks.sound && hooks.sound.describe ? hooks.sound.describe() : 'no hooks') + ')';
              else if (player && (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'))) message.error = 'an advertisement plays';
              else {
                message.from = held.start;
                message.until = held.until;
                var from = Math.max(Number(ask.from) || 0, held.start);
                var seconds = Math.max(1, Math.min(15, Number(ask.seconds) || 10));
                if (held.until >= from + seconds - 0.05) {
                  var run = held.run;
                  var samples = await samplesOf(held);
                  var piece = held.run === run ? S.cut(held.start, samples, from, seconds) : null;
                  if (piece) {
                    message.start = piece.start;
                    message.rate = S.RATE;
                    message.samples = S.pcm16(piece.samples);
                  }
                }
              }
            } catch (error) {
              message.error = String(error);
            }
            answer(message);
          });
        })();
        """
        return [sound, hooks, reader].map { WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: false) }
    }()

    /// `seconds` of the video's sound from `from` (seconds of the video),
    /// from what the player holds: the samples, `.notYet` while it holds
    /// less, `.failed` when it cannot be read here.
    func sound(from: TimeInterval, seconds: TimeInterval) async -> ClipSoundAnswer {
        guard hearsSound, !Self.soundScripts.isEmpty, let webView else { return .failed("the player's sound is not held") }
        let id = nextSoundID
        nextSoundID += 1
        return await withCheckedContinuation { continuation in
            soundAnswers[id] = continuation
            let ask = "{ahenkSound:{id:\(id),from:\(String(format: "%.2f", max(0, from))),seconds:\(String(format: "%.2f", seconds))}}"
            webView.evaluateJavaScript("(function(){var f=document.querySelector('iframe');if(f&&f.contentWindow)f.contentWindow.postMessage(\(ask),'*');})()", completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.soundAnswers.removeValue(forKey: id)?.resume(returning: .failed("no answer"))
            }
        }
    }

    private func receivedSound(_ message: [String: Any]) {
        guard let id = (message["id"] as? NSNumber)?.intValue, let continuation = soundAnswers.removeValue(forKey: id) else { return }
        if let error = message["error"] as? String {
            continuation.resume(returning: .failed(error))
            return
        }
        let sound = BridgeSound(
            heldFrom: (message["from"] as? NSNumber)?.doubleValue, heldUntil: (message["until"] as? NSNumber)?.doubleValue,
            start: (message["start"] as? NSNumber)?.doubleValue, rate: (message["rate"] as? NSNumber)?.doubleValue,
            samples: message["samples"] as? String
        )
        continuation.resume(returning: sound.window.map(ClipSoundAnswer.sound) ?? .notYet(heldUntil: sound.heldUntil))
    }

    /// Whether the video goes on while its window is covered (see
    /// `keepPlayingWhenCovered`): on while its sound is read, off after.
    func setPlaysWhenCovered(_ on: Bool) {
        guard on != playsWhenCovered, let webView else { return }
        playsWhenCovered = on
        Self.setOcclusionDetection(!on, in: webView)
    }

    // MARK: Control

    override func setPlaying(_ playing: Bool) {
        guard playing != wantsPlaying else { return }
        wantsPlaying = playing
        run(playing ? "window.ahenk && window.ahenk.play()" : "window.ahenk && window.ahenk.pause()")
        // Measurement: the video stays on screen, stopped on one frame.
        if playing, Experiment.has("videoPaused") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.run("window.ahenk && window.ahenk.pause()")
            }
        }
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
        for continuation in soundAnswers.values { continuation.resume(returning: .failed("the player is gone")) }
        soundAnswers = [:]
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
        if let message = body as? [String: Any], message["type"] as? String == "sound" {
            receivedSound(message)
            return
        }
        if let message = body as? [String: Any], message["type"] as? String == "stats" {
            Self.log.info("Wallpaper video: \(message["width"] ?? 0)x\(message["height"] ?? 0), \(message["fps"] ?? 0) frames a second, \(message["dropped"] ?? 0) dropped, shown at \(message["box"] ?? "?"); \(message["nerd"] ?? "")")
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

/// What the embedded player answered when asked for a stretch of its sound.
enum ClipSoundAnswer: Sendable {
    case sound(HeldSound)
    /// It holds less than was asked for (up to `heldUntil` seconds).
    case notYet(heldUntil: Double?)
    case failed(String)
}
