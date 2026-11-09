import Foundation

/// A video in YouTube's search results, with what the live wallpaper ranks
/// candidates by. Nothing of the video's description is kept except the
/// one fact that YouTube made it from an album ("Provided to YouTube by …",
/// i.e. the cover as a still).
public struct YouTubeVideo: Hashable, Sendable, Codable {
    /// The 11-character video ID.
    public var id: String
    public var title: String
    public var channel: String
    public var channelID: String?
    /// Seconds; `nil` for live streams and unknown lengths.
    public var duration: TimeInterval?
    /// The channel carries YouTube's "Official Artist Channel" badge.
    public var isOfficialArtistChannel: Bool
    /// The channel is verified (a label, a brand, an artist).
    public var isVerifiedChannel: Bool
    /// YouTube generated it from an album: the cover as a still.
    public var isArtTrack: Bool
    /// A live stream (now or upcoming).
    public var isLive: Bool
    public var viewCount: Int?

    public init(
        id: String, title: String, channel: String, channelID: String? = nil, duration: TimeInterval? = nil,
        isOfficialArtistChannel: Bool = false, isVerifiedChannel: Bool = false, isArtTrack: Bool = false,
        isLive: Bool = false, viewCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.duration = duration
        self.isOfficialArtistChannel = isOfficialArtistChannel
        self.isVerifiedChannel = isVerifiedChannel
        self.isArtTrack = isArtTrack
        self.isLive = isLive
        self.viewCount = viewCount
    }
}

/// Reads YouTube's search answers: the web client's JSON (`youtubei/v1/
/// search`) or the results page's embedded `ytInitialData`. Both hold the
/// same `videoRenderer` objects, found wherever they sit in the tree (the
/// layout around them changes often; the renderers rarely do).
public enum YouTubeSearchDecoder {
    public enum Failure: Error, Equatable {
        /// Not JSON, or a page without the data.
        case malformed
    }

    public static func videos(fromJSON data: Data) throws -> [YouTubeVideo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Failure.malformed }
        return videos(in: object)
    }

    /// The results page: the JSON assigned to `ytInitialData`.
    public static func videos(fromHTML data: Data) throws -> [YouTubeVideo] {
        guard let html = String(data: data, encoding: .utf8) else { throw Failure.malformed }
        for marker in ["var ytInitialData = ", "window[\"ytInitialData\"] = ", "ytInitialData = "] {
            guard let start = html.range(of: marker) else { continue }
            let rest = html[start.upperBound...]
            guard let end = rest.range(of: ";</script>") else { continue }
            if let json = rest[..<end.lowerBound].data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: json) {
                return videos(in: object)
            }
        }
        throw Failure.malformed
    }

    /// Every `videoRenderer` in the tree, in document order, each once.
    static func videos(in object: Any) -> [YouTubeVideo] {
        var found: [YouTubeVideo] = []
        var seen: Set<String> = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                if let renderer = dictionary["videoRenderer"] as? [String: Any], let video = video(from: renderer), seen.insert(video.id).inserted {
                    found.append(video)
                }
                for (key, value) in dictionary where key != "videoRenderer" {
                    walk(value)
                }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return found
    }

    static func video(from renderer: [String: Any]) -> YouTubeVideo? {
        guard let id = renderer["videoId"] as? String, BrowserSite.youtubeVideoID(id) == id else { return nil }
        let title = text(renderer["title"]) ?? ""
        guard !title.isEmpty else { return nil }
        let owner = renderer["ownerText"] ?? renderer["longBylineText"] ?? renderer["shortBylineText"]
        let ownerBadges = badges(renderer["ownerBadges"])
        let videoBadges = badges(renderer["badges"])
        let overlayLive = (renderer["thumbnailOverlays"] as? [[String: Any]] ?? []).contains { overlay in
            ((overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String) == "LIVE"
        }
        let snippets = (renderer["detailedMetadataSnippets"] as? [[String: Any]] ?? []).compactMap { text($0["snippetText"]) }
            + [text(renderer["descriptionSnippet"])].compactMap { $0 }
        return YouTubeVideo(
            id: id,
            title: title,
            channel: text(owner) ?? "",
            channelID: channelID(owner),
            duration: text(renderer["lengthText"]).flatMap(seconds(fromClock:)),
            isOfficialArtistChannel: ownerBadges.contains("BADGE_STYLE_TYPE_VERIFIED_ARTIST"),
            isVerifiedChannel: ownerBadges.contains("BADGE_STYLE_TYPE_VERIFIED") || ownerBadges.contains("BADGE_STYLE_TYPE_VERIFIED_ARTIST"),
            isArtTrack: snippets.contains(where: isGeneratedDescription),
            isLive: overlayLive || videoBadges.contains("BADGE_STYLE_TYPE_LIVE_NOW"),
            viewCount: text(renderer["viewCountText"]).flatMap(count(from:))
        )
    }

    /// "Provided to YouTube by …" / "Auto-generated by YouTube": the cover
    /// as a still over an album track.
    static func isGeneratedDescription(_ text: String) -> Bool {
        text.range(of: "Provided to YouTube by", options: .caseInsensitive) != nil
            || text.range(of: "Auto-generated by YouTube", options: .caseInsensitive) != nil
    }

    /// `{"simpleText": …}` or `{"runs": [{"text": …}, …]}`.
    static func text(_ node: Any?) -> String? {
        guard let dictionary = node as? [String: Any] else { return nil }
        if let simple = dictionary["simpleText"] as? String {
            return simple.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let runs = dictionary["runs"] as? [[String: Any]] else { return nil }
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func channelID(_ owner: Any?) -> String? {
        let runs = (owner as? [String: Any])?["runs"] as? [[String: Any]]
        let endpoint = (runs?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
        return endpoint?["browseId"] as? String
    }

    private static func badges(_ node: Any?) -> Set<String> {
        Set((node as? [[String: Any]] ?? []).compactMap { ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String })
    }

    /// "4:51" → 291, "1:02:45" → 3765; `nil` for anything else.
    public static func seconds(fromClock text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + Double(value)
        }
        return total
    }

    /// "169,258,652 views" → 169258652 (digits only; `nil` without any).
    public static func count(from text: String) -> Int? {
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }
        guard !digits.isEmpty, digits.count <= 15 else { return nil }
        return Int(String(String.UnicodeScalarView(digits)))
    }
}

/// Whether YouTube lets a video play in an embedded player, from its public
/// oEmbed endpoint (no key): 200 embeddable, 401/403 embedding disabled,
/// 400/404 gone or private.
public struct YouTubeEmbedInfo: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case embeddable
        case disabled
        case missing
    }

    public var status: Status
    public var title: String?
    public var channel: String?

    public init(status: Status, title: String? = nil, channel: String? = nil) {
        self.status = status
        self.title = title
        self.channel = channel
    }
}

/// Finds videos on YouTube without an account or an API key, through the
/// same public endpoint youtube.com's own search box uses (the web client's
/// `youtubei/v1/search`, videos only), with the results page as a fallback.
/// Answers are cached (a week; an empty answer a day) in the catalog cache,
/// and `RequestThrottle` keeps a calm pace (a "too many requests" answer
/// stops every request for ten minutes).
public final class YouTubeVideoSearch: Sendable {
    public static let searchEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!
    /// The web client the endpoint expects; older versions keep working.
    public static let clientVersion = "2.20251101.00.00"
    /// The search filter "type: video".
    public static let videosOnly = "EgIQAQ=="
    public static let requestsPerMinute = 8
    static let resultsLifetime: TimeInterval = 7 * 86_400
    static let emptyLifetime: TimeInterval = 86_400
    static let embedLifetime: TimeInterval = 7 * 86_400
    static let backOff: TimeInterval = 600

    private let fetcher: any HTTPFetching
    private let region: @Sendable () -> String
    private let cache: CatalogCache
    private let throttle: RequestThrottle
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "wallpaper")

    /// `region` is the two-letter country the results are for (the store
    /// country setting, or the Mac's region).
    public init(
        fetcher: any HTTPFetching,
        region: @escaping @Sendable () -> String,
        cache: CatalogCache = CatalogCache(directory: nil),
        throttle: RequestThrottle = RequestThrottle(limit: YouTubeVideoSearch.requestsPerMinute, per: 60, maximumWait: 8),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.region = region
        self.cache = cache
        self.throttle = throttle
        self.clock = clock
    }

    /// Videos for `query`, in YouTube's order.
    public func search(_ query: String) async throws -> [YouTubeVideo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let country = region().uppercased()
        let key = "youtube-search:v1:\(country):\(TrackMatching.normalized(trimmed))"
        if let cached = cache.value([YouTubeVideo].self, forKey: key, maxAge: Self.emptyLifetime, now: clock()) { return cached }
        if let cached = cache.value([YouTubeVideo].self, forKey: key, maxAge: Self.resultsLifetime, now: clock()), !cached.isEmpty {
            return cached
        }
        try await throttle.acquire()
        var videos: [YouTubeVideo]
        do {
            let (data, status) = try await fetcher.post(Self.searchEndpoint, json: Self.requestBody(query: trimmed, region: country))
            try await check(status)
            videos = try YouTubeSearchDecoder.videos(fromJSON: data)
        } catch CatalogError.rateLimited {
            throw CatalogError.rateLimited
        } catch {
            // The results page holds the same data.
            Self.log.info("YouTube's search endpoint did not answer usefully (\(String(describing: error))); trying the results page")
            guard let url = Self.resultsPageURL(query: trimmed, region: country) else { throw CatalogError.unreadable }
            try await throttle.acquire()
            var request = URLRequest(url: url)
            // "Reject all" on the consent screen some regions show first.
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
            request.setValue("en", forHTTPHeaderField: "Accept-Language")
            let answer: (data: Data, status: Int)
            do {
                answer = try await fetcher.send(request)
            } catch {
                throw CatalogError.offline
            }
            try await check(answer.status)
            do {
                videos = try YouTubeSearchDecoder.videos(fromHTML: answer.data)
            } catch {
                throw CatalogError.unreadable
            }
        }
        cache.store(videos, forKey: key, onDisk: true, now: clock())
        return videos
    }

    /// Whether the video plays in an embedded player (`nil`: no answer, try
    /// it anyway). The embedded player's own error is the final word.
    public func embedInfo(of videoID: String) async -> YouTubeEmbedInfo? {
        guard BrowserSite.youtubeVideoID(videoID) == videoID, let url = Self.oEmbedURL(videoID: videoID) else { return nil }
        let key = "youtube-embed:v1:\(videoID)"
        if let cached = cache.value(YouTubeEmbedInfo.self, forKey: key, maxAge: Self.embedLifetime, now: clock()) { return cached }
        guard (try? await throttle.acquire()) != nil, let (data, status) = try? await fetcher.get(url) else { return nil }
        let info: YouTubeEmbedInfo
        switch status {
        case 200:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            info = YouTubeEmbedInfo(status: .embeddable, title: object?["title"] as? String, channel: object?["author_name"] as? String)
        case 401, 403: info = YouTubeEmbedInfo(status: .disabled)
        case 400, 404: info = YouTubeEmbedInfo(status: .missing)
        case 429:
            await throttle.backOff(for: Self.backOff)
            return nil
        default: return nil
        }
        cache.store(info, forKey: key, onDisk: true, now: clock())
        return info
    }

    private func check(_ status: Int) async throws {
        switch status {
        case 200: return
        case 429:
            await throttle.backOff(for: Self.backOff)
            Self.log.notice("YouTube asked to slow down; video searches pause for \(Int(Self.backOff / 60)) minutes")
            throw CatalogError.rateLimited
        default:
            throw CatalogError.badStatus(status)
        }
    }

    // MARK: Requests

    public static func requestBody(query: String, region: String) -> Data {
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en", "gl": region.uppercased()]],
            "query": query,
            "params": videosOnly,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    public static func resultsPageURL(query: String, region: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "sp", value: videosOnly),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: region.uppercased()),
        ]
        return components?.url
    }

    public static func oEmbedURL(videoID: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }
}
