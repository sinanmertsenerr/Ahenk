import Foundation

/// Starting a song in the Spotify app the way Spotify's own remote does
/// (picking a song on the phone while the Mac plays): a command sent
/// through Spotify's servers to the app. The app starts the song where it
/// is, in the background; `play track` over AppleScript brings it to the
/// front instead (see ``FocusKeeping``).
///
/// It needs the user signed in to Spotify once, in a web view Ahenk keeps
/// (the web player's session). The addresses and bodies are the web
/// player's own, not a published API: when one stops working, the caller
/// falls back to AppleScript.
public enum SpotifyRemote {
    public static let webPlayerURL = URL(string: "https://open.spotify.com/")!
    public static let loginURL = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!
    public static let webPlayerHost = "open.spotify.com"
    static let service = "https://gue1-spclient.spotify.com"
    static let clientVersion = "harmony:4.43.2-a61ecaf5"

    /// The web player's session, as its page got it.
    public struct Session: Equatable, Sendable {
        public var accessToken: String
        public var clientToken: String?
        /// `false` for the session of a visitor who is not signed in.
        public var isSignedIn: Bool
        public var expiresAt: Date?
        /// The account's user name, when the page has named it in a
        /// request (the library is asked by user name).
        public var username: String?

        public init(accessToken: String, clientToken: String?, isSignedIn: Bool, expiresAt: Date?, username: String? = nil) {
            self.accessToken = accessToken
            self.clientToken = clientToken
            self.isSignedIn = isSignedIn
            self.expiresAt = expiresAt
            self.username = username
        }

        /// Good for at least another minute.
        public func isFresh(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) > 60
        }
    }

    public struct Device: Equatable, Sendable {
        public var id: String
        public var name: String
        public var type: String
    }

    /// Added to the web player's page before its own scripts: keeps what
    /// the page asks Spotify for its session (`/api/token`) and the client
    /// token it sends along. Nothing is changed in the requests.
    public static let sessionHookScript = """
    (function () {
      if (window.__ahenkHook) return;
      window.__ahenkHook = true;
      window.__ahenk = {};
      var original = window.fetch;
      window.fetch = function (input, init) {
        var url = '';
        try {
          // A string, a Request or a URL object.
          url = typeof input === 'string' ? input : String((input && input.url) || input || '');
          var headers = (init && init.headers) || (input && input.headers);
          if (headers) {
            var client = headers.get ? headers.get('client-token') : headers['client-token'];
            if (client) window.__ahenk.clientToken = client;
          }
          var user = /\\/user\\/([A-Za-z0-9._-]{1,64})\\//.exec(url);
          if (user) window.__ahenk.username = user[1];
        } catch (e) {}
        var answer = original.apply(this, arguments);
        if (url.indexOf('/api/token') !== -1) {
          answer.then(function (response) {
            return response.clone().json().then(function (json) {
              if (json && json.accessToken) window.__ahenk.session = json;
            });
          }).catch(function () {});
        }
        return answer;
      };
    })();
    """

    /// Run in the page: what the hook kept, as JSON.
    public static let sessionReadScript = "JSON.stringify(window.__ahenk || {})"

    /// The session in what `sessionReadScript` answered (`nil` until the
    /// page has asked for it).
    public static func session(fromJSON text: String) -> Session? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let session = object["session"] as? [String: Any],
              let token = session["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = (session["accessTokenExpirationTimestampMs"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return Session(
            accessToken: token,
            clientToken: (object["clientToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isSignedIn: (session["isAnonymous"] as? Bool) == false,
            expiresAt: expires,
            username: (object["username"] as? String).flatMap { isUsername($0) ? $0 : nil }
        )
    }

    // MARK: Requests

    /// Spotify's message socket; its first message names the connection.
    public static func dealerURL(accessToken: String) -> URL? {
        var components = URLComponents(string: "wss://dealer.spotify.com/")
        components?.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        return components?.url
    }

    /// The connection ID in the socket's first message.
    public static func connectionID(fromDealerMessage text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let headers = object["headers"] as? [String: Any]
        else { return nil }
        for (key, value) in headers where key.lowercased() == "spotify-connection-id" {
            if let id = value as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Registers Ahenk as a remote that plays nothing itself.
    public static func registerRequest(session: Session, deviceID: String, connectionID: String) -> URLRequest? {
        let body: [String: Any] = [
            "device": [
                "device_id": deviceID,
                "device_type": "computer",
                "brand": "spotify",
                "model": "web_player",
                "name": "Ahenk",
                "is_group": false,
                "metadata": [String: Any](),
                "platform_identifier": "web_player osx;ahenk",
                "capabilities": [
                    "change_volume": true,
                    "supports_file_media_type": true,
                    "enable_play_token": true,
                    "play_token_lost_behavior": "pause",
                    "disable_connect": false,
                    "audio_podcasts": true,
                    "video_playback": true,
                    "manifest_formats": ["file_ids_mp3", "file_urls_mp3", "file_ids_mp4", "manifest_ids_video"],
                ] as [String: Any],
            ] as [String: Any],
            "outro_endcontent_snooping": false,
            "connection_id": connectionID,
            "client_version": clientVersion,
            "volume": 65535,
        ]
        return request("POST", "\(service)/track-playback/v1/devices", session: session, body: body)
    }

    /// Asks which devices the account has (the answer is read with
    /// ``devices(fromJSON:)``).
    public static func stateRequest(session: Session, deviceID: String, connectionID: String) -> URLRequest? {
        guard isHexID(deviceID) else { return nil }
        let body: [String: Any] = [
            "member_type": "CONNECT_STATE",
            "device": ["device_info": ["capabilities": ["can_be_player": false, "hidden": true, "needs_full_player_state": true]]],
        ]
        var request = request("PUT", "\(service)/connect-state/v1/devices/hobs_\(deviceID)", session: session, body: body)
        request?.setValue(connectionID, forHTTPHeaderField: "x-spotify-connection-id")
        return request
    }

    /// "Play this song" from Ahenk's remote to the device `target`.
    public static func playRequest(session: Session, trackID: String, from deviceID: String, to target: String, commandID: String) -> URLRequest? {
        guard SpotifyAppScripts.isBase62ID(trackID), isHexID(deviceID), isHexID(target) else { return nil }
        let uri = "spotify:track:\(trackID)"
        let body: [String: Any] = [
            "command": [
                "endpoint": "play",
                "logging_params": ["command_id": commandID],
                "context": ["uri": uri, "url": "context://\(uri)"],
                "options": ["skip_to": ["track_uri": uri]],
            ] as [String: Any],
        ]
        return request("POST", "\(service)/connect-state/v1/player/command/from/\(deviceID)/to/\(target)", session: session, body: body)
    }

    private static func request(_ method: String, _ address: String, session: Session, body: [String: Any]) -> URLRequest? {
        guard let url = URL(string: address), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let clientToken = session.clientToken { request.setValue(clientToken, forHTTPHeaderField: "client-token") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        return request
    }

    // MARK: Liked Songs

    static let library = "https://spclient.wg.spotify.com/collection/v2"

    public static func isUsername(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Asks whether the song is among the user's Liked Songs (answered
    /// with ``isLiked(fromJSON:)``).
    public static func likedRequest(session: Session, trackID: String) -> URLRequest? {
        guard let username = session.username, isUsername(username), SpotifyAppScripts.isBase62ID(trackID) else { return nil }
        let body: [String: Any] = ["username": username, "set": "collection", "items": [["uri": "spotify:track:\(trackID)"]]]
        var request = request("POST", "\(library)/contains?market=from_token", session: session, body: body)
        request?.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `{"found": [true]}`.
    public static func isLiked(fromJSON data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = object["found"] as? [Bool], found.count == 1
        else { return nil }
        return found[0]
    }

    /// Adds the song to the user's Liked Songs, or takes it out.
    public static func likeRequest(session: Session, trackID: String, liked: Bool, at date: Date) -> URLRequest? {
        guard let username = session.username, isUsername(username), SpotifyAppScripts.isBase62ID(trackID) else { return nil }
        var item: [String: Any] = ["uri": "spotify:track:\(trackID)"]
        if liked {
            item["addedAt"] = Int(date.timeIntervalSince1970)
        } else {
            item["isRemoved"] = true
        }
        let body: [String: Any] = ["username": username, "set": "collection", "items": [item]]
        var request = request("POST", "\(library)/write?market=from_token", session: session, body: body)
        request?.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func isHexID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// 32 random hex digits (a device or command ID).
    public static func randomID() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: Devices

    /// The account's devices in the answer to ``stateRequest``.
    public static func devices(fromJSON data: Data) -> [Device]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: Any]
        else { return nil }
        return devices.compactMap { key, value -> Device? in
            guard let device = value as? [String: Any] else { return nil }
            let id = device["device_id"] as? String ?? key
            return Device(id: id, name: device["name"] as? String ?? "", type: (device["device_type"] as? String ?? "").uppercased())
        }.sorted { $0.id < $1.id }
    }

    /// The Spotify app on this Mac among `devices`: a computer that is not
    /// a web player and not Ahenk's own remote, named like this Mac. With
    /// another name (the user renamed one of them), the only such computer.
    /// `nil` when it cannot be told: a song must never start on a phone or
    /// on another computer.
    public static func target(in devices: [Device], computerName: String, ownDeviceID: String) -> String? {
        let computers = devices.filter { device in
            device.type == "COMPUTER" && device.id != ownDeviceID && isHexID(device.id)
                && !device.name.hasPrefix("Web Player") && device.name != "Ahenk"
        }
        let named = computers.filter { $0.name.compare(computerName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if named.count == 1 { return named[0].id }
        return computers.count == 1 ? computers[0].id : nil
    }
}
