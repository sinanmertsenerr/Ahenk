import Foundation

/// An album's motion artwork in Apple's catalog: short looping videos (HLS)
/// of the animated cover, in a square and a tall (3:4) cut. Streamed while
/// they show, never stored.
public struct MotionArtwork: Hashable, Sendable, Codable {
    /// The catalog's album number.
    public var albumID: String
    public var square: URL?
    public var tall: URL?

    public init(albumID: String, square: URL?, tall: URL?) {
        self.albumID = albumID
        self.square = square
        self.tall = tall
    }

    /// The cut that fills a screen of `aspectRatio` (width ÷ height) with
    /// the least cropping: the square one for landscape screens, the tall
    /// one for portrait screens.
    public func url(forAspectRatio aspectRatio: Double) -> URL? {
        aspectRatio >= 0.87 ? (square ?? tall) : (tall ?? square)
    }
}

/// Reads the pieces of the motion artwork lookup (ported from the author's
/// DynamicIsland): the web player's page names its script, the script holds
/// the anonymous token the web player reads the catalog with, and the
/// catalog's album answer holds `editorialVideo`.
public enum MotionArtworkDecoder {
    public enum Failure: Error, Equatable {
        case malformed
    }

    /// The album's motion artwork; `nil` when the album has none (a
    /// definitive answer).
    public static func artwork(albumID: String, from data: Data) throws -> MotionArtwork? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]]
        else { throw Failure.malformed }
        guard let attributes = items.first?["attributes"] as? [String: Any],
              let editorial = attributes["editorialVideo"] as? [String: Any]
        else { return nil }
        func video(_ keys: [String]) -> URL? {
            for key in keys {
                if let field = editorial[key] as? [String: Any], let text = field["video"] as? String,
                   let url = URL(string: text), url.scheme?.lowercased() == "https" {
                    return url
                }
            }
            return nil
        }
        let square = video(["motionDetailSquare", "motionSquareVideo1x1"])
        let tall = video(["motionDetailTall", "motionTallVideo3x4"])
        guard square != nil || tall != nil else { return nil }
        return MotionArtwork(albumID: albumID, square: square, tall: tall)
    }

    /// The web player's main script ("/assets/index~….js") in its page.
    public static func scriptPath(inPage html: String) -> String? {
        guard let range = html.range(of: #"/assets/[^"' ]*index[^"' ]*\.js"#, options: .regularExpression) else { return nil }
        return String(html[range])
    }

    /// The anonymous token in the script (a JSON Web Token).
    public static func token(inScript script: String) -> String? {
        guard let range = script.range(of: #"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, options: .regularExpression) else {
            return nil
        }
        return String(script[range])
    }

    /// When the token stops working (its `exp` claim).
    public static func expiry(ofToken token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expires = (claims["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: expires)
    }
}

public enum MotionArtworkLookup: Equatable, Sendable {
    case found(MotionArtwork)
    /// The catalog answered: the album has no motion artwork.
    case none
    /// No answer (offline, refused); worth asking again later.
    case failed
}

/// Finds an album's motion artwork in Apple's catalog with the web player's
/// anonymous token: no account, no key of Ahenk's. Answers are cached (a
/// week; "none" three days), the token until a day before it expires; a
/// refused token is fetched again once.
public actor MotionArtworkFinder {
    public static let pageURL = URL(string: "https://music.apple.com/us/new")!
    static let foundLifetime: TimeInterval = 7 * 86_400
    static let missLifetime: TimeInterval = 3 * 86_400
    /// After a failed token fetch, wait this long before the next try.
    static let tokenRetryPause: TimeInterval = 600

    private struct Stored: Codable {
        var artwork: MotionArtwork?
    }

    private struct StoredToken: Codable {
        var value: String
        var expires: Date
    }

    private let fetcher: any HTTPFetching
    private let storefront: @Sendable () -> String
    private let cache: CatalogCache
    private let throttle: RequestThrottle
    private let clock: @Sendable () -> Date
    private var token: StoredToken?
    private var tokenFailedAt: Date?
    private static let log = AhenkLogger(category: "wallpaper")

    public init(
        fetcher: any HTTPFetching,
        storefront: @escaping @Sendable () -> String,
        cache: CatalogCache = CatalogCache(directory: nil),
        throttle: RequestThrottle = RequestThrottle(limit: 12, per: 60, maximumWait: 6),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.storefront = storefront
        self.cache = cache
        self.throttle = throttle
        self.clock = clock
    }

    /// The motion artwork of the catalog album with this number.
    public func artwork(albumID: String) async -> MotionArtworkLookup {
        guard !albumID.isEmpty, albumID.allSatisfy(\.isNumber) else { return .none }
        let country = storefront().lowercased()
        let key = "motion-artwork:v1:\(country):\(albumID)"
        if let stored = cache.value(Stored.self, forKey: key, maxAge: Self.missLifetime, now: clock()) {
            return stored.artwork.map(MotionArtworkLookup.found) ?? .none
        }
        if let stored = cache.value(Stored.self, forKey: key, maxAge: Self.foundLifetime, now: clock()), let artwork = stored.artwork {
            return .found(artwork)
        }
        for attempt in 0..<2 {
            guard let token = await currentToken(), let url = Self.albumURL(albumID: albumID, country: country) else { return .failed }
            guard (try? await throttle.acquire()) != nil else { return .failed }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            guard let (data, status) = try? await fetcher.send(request) else { return .failed }
            switch status {
            case 200:
                let found: MotionArtwork?
                do {
                    found = try MotionArtworkDecoder.artwork(albumID: albumID, from: data)
                } catch {
                    return .failed
                }
                cache.store(Stored(artwork: found), forKey: key, onDisk: true, now: clock())
                return found.map(MotionArtworkLookup.found) ?? .none
            case 404:
                cache.store(Stored(artwork: nil), forKey: key, onDisk: true, now: clock())
                return .none
            case 401 where attempt == 0, 403 where attempt == 0:
                // The web player's token rotated: fetch it again.
                self.token = nil
                cache.store(StoredToken(value: "", expires: .distantPast), forKey: Self.tokenKey, onDisk: true, now: clock())
                continue
            case 429:
                await throttle.backOff(for: 600)
                return .failed
            default:
                return .failed
            }
        }
        return .failed
    }

    public static func albumURL(albumID: String, country: String) -> URL? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(country.lowercased())/albums/\(albumID)")
        components?.queryItems = [URLQueryItem(name: "extend", value: "editorialVideo")]
        return components?.url
    }

    // MARK: The token

    static let tokenKey = "motion-artwork-token:v1"

    private func currentToken() async -> String? {
        let now = clock()
        if let token, token.expires > now.addingTimeInterval(3_600) { return token.value }
        if let stored = cache.value(StoredToken.self, forKey: Self.tokenKey, maxAge: 400 * 86_400, now: now),
           !stored.value.isEmpty, stored.expires > now.addingTimeInterval(86_400) {
            token = stored
            return stored.value
        }
        if let tokenFailedAt, now.timeIntervalSince(tokenFailedAt) < Self.tokenRetryPause { return nil }
        guard let fresh = await fetchToken() else {
            tokenFailedAt = now
            Self.log.info("Could not read the catalog token for motion artwork")
            return nil
        }
        tokenFailedAt = nil
        token = fresh
        cache.store(fresh, forKey: Self.tokenKey, onDisk: true, now: now)
        return fresh.value
    }

    private func fetchToken() async -> StoredToken? {
        guard (try? await throttle.acquire()) != nil,
              let (page, status) = try? await fetcher.get(Self.pageURL), status == 200,
              let html = String(data: page, encoding: .utf8),
              let path = MotionArtworkDecoder.scriptPath(inPage: html),
              let scriptURL = URL(string: path, relativeTo: Self.pageURL)?.absoluteURL,
              (try? await throttle.acquire()) != nil,
              let (script, scriptStatus) = try? await fetcher.get(scriptURL), scriptStatus == 200,
              let text = String(data: script, encoding: .utf8),
              let value = MotionArtworkDecoder.token(inScript: text)
        else { return nil }
        // Without a readable expiry, trust it for a week.
        let expires = MotionArtworkDecoder.expiry(ofToken: value) ?? clock().addingTimeInterval(7 * 86_400)
        return StoredToken(value: value, expires: expires)
    }
}
