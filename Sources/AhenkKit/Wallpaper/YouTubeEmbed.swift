import Foundation

/// The page a wallpaper web view loads to show one YouTube video: YouTube's
/// IFrame Player API with the privacy-enhanced player
/// (`www.youtube-nocookie.com`), muted, without controls, keyboard or full
/// screen, filling the screen (cover-fit, cut at the edges), looping on its
/// own or held in step with the song by the app.
///
/// YouTube asks apps that embed its player to identify themselves through
/// the HTTP Referer: the page is loaded with the app's bundle ID as its
/// origin (`https://com.sinanmertsener.ahenk`), which becomes the player's
/// referrer and `origin` parameter. Without it the player fails with error
/// 153 ("video player configuration error").
public enum YouTubeEmbed {
    public static let playerHost = "https://www.youtube-nocookie.com"
    public static let apiScript = "https://www.youtube.com/iframe_api"
    /// The script message handler the page reports to.
    public static let messageHandler = "ahenkWallpaper"

    /// `https://<bundle id>` in lower case, as YouTube's embed rules ask.
    public static func origin(bundleIdentifier: String) -> URL {
        let cleaned = bundleIdentifier.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "." || $0 == "-" }
        let host = String(String.UnicodeScalarView(cleaned))
        return URL(string: "https://\(host.isEmpty ? "ahenk.local" : host)") ?? URL(string: "https://ahenk.local")!
    }

    /// The page for `videoID`, starting at `start` seconds; `loops` plays it
    /// round and round (otherwise it holds its last frame at the end).
    /// `nil` for anything that is not a video ID.
    public static func page(videoID: String, start: TimeInterval, loops: Bool, origin: URL) -> String? {
        guard BrowserSite.youtubeVideoID(videoID) == videoID else { return nil }
        let startSeconds = Int(max(0, start.isFinite ? start : 0))
        let originText = origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString
        guard originText.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":/.-".contains($0)) }) else { return nil }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
        #frame{position:absolute;left:50%;top:50%;width:max(100vw,177.7778vh);height:max(56.25vw,100vh);transform:translate(-50%,-50%)}
        #player,#frame iframe{display:block;width:100%;height:100%;border:0;pointer-events:none}
        </style></head>
        <body><div id="frame"><div id="player"></div></div>
        <script>
        (function () {
          'use strict';
          var post = function (message) {
            try { window.webkit.messageHandlers.\(messageHandler).postMessage(message); } catch (e) {}
          };
          var player = null;
          var ready = false;
          var loops = \(loops ? "true" : "false");
          var report = function (state) {
            post({ type: 'state', state: state, time: player.getCurrentTime(), duration: player.getDuration(), muted: player.isMuted() });
          };
          window.onYouTubeIframeAPIReady = function () {
            player = new YT.Player('player', {
              host: '\(playerHost)',
              videoId: '\(videoID)',
              width: '100%',
              height: '100%',
              playerVars: {
                autoplay: 1, mute: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, rel: 0, playsinline: 1,
                start: \(startSeconds), origin: '\(originText)', enablejsapi: 1
              },
              events: {
                onReady: function (event) {
                  ready = true;
                  event.target.mute();
                  event.target.playVideo();
                  post({ type: 'ready', duration: event.target.getDuration() });
                },
                onStateChange: function (event) {
                  if (!event.target.isMuted()) event.target.mute();
                  if (event.data === 0 && loops) {
                    event.target.seekTo(0, true);
                    event.target.playVideo();
                  }
                  report(event.data);
                },
                onError: function (event) { post({ type: 'error', code: event.data }); }
              }
            });
          };
          window.ahenk = {
            play: function () { if (ready) { player.mute(); player.playVideo(); } },
            pause: function () { if (ready) player.pauseVideo(); },
            seek: function (seconds) { if (ready) player.seekTo(seconds, true); },
            setLoops: function (value) { loops = !!value; },
            status: function () {
              return ready ? { time: player.getCurrentTime(), duration: player.getDuration(), state: player.getPlayerState(), muted: player.isMuted() } : null;
            }
          };
          var script = document.createElement('script');
          script.src = '\(apiScript)';
          script.onerror = function () { post({ type: 'error', code: -1 }); };
          document.head.appendChild(script);
        })();
        </script>
        </body></html>
        """
    }

    /// The player's states (YouTube's numbers).
    public enum PlayerState: Int, Equatable, Sendable {
        case unstarted = -1
        case ended = 0
        case playing = 1
        case paused = 2
        case buffering = 3
        case cued = 5
    }

    /// Why a video did not play.
    public enum Failure: Equatable, Sendable {
        /// The owner does not allow embedding (101, 150).
        case embeddingDisabled
        /// Removed, private or never there (100).
        case unavailable
        /// A bad request (2).
        case invalid
        /// The player did not accept the page's identity (152, 153).
        case playerConfiguration
        /// The HTML5 player failed (5).
        case playback
        /// The page could not load YouTube's script (offline).
        case offline
        case other(Int)

        public init(code: Int) {
            switch code {
            case 101, 150: self = .embeddingDisabled
            case 100: self = .unavailable
            case 2: self = .invalid
            case 152, 153: self = .playerConfiguration
            case 5: self = .playback
            case -1: self = .offline
            default: self = .other(code)
            }
        }

        /// Another candidate may work (the next video), as opposed to every
        /// embed failing (offline, the page's identity refused).
        public var isAboutThisVideo: Bool {
            switch self {
            case .embeddingDisabled, .unavailable, .invalid, .playback, .other: true
            case .playerConfiguration, .offline: false
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case ready(duration: TimeInterval?)
        case state(PlayerState, time: TimeInterval?, duration: TimeInterval?, muted: Bool?)
        case error(Failure)
    }

    /// A message the page posted (`nil` for anything else).
    public static func event(from body: Any) -> Event? {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return nil }
        func seconds(_ key: String) -> TimeInterval? {
            guard let value = (message[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        switch type {
        case "ready":
            return .ready(duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil })
        case "state":
            guard let raw = (message["state"] as? NSNumber)?.intValue, let state = PlayerState(rawValue: raw) else { return nil }
            return .state(state, time: seconds("time"), duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil }, muted: message["muted"] as? Bool)
        case "error":
            guard let code = (message["code"] as? NSNumber)?.intValue else { return nil }
            return .error(Failure(code: code))
        default:
            return nil
        }
    }
}
