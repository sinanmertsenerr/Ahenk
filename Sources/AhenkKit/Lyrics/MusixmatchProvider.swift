import Foundation

/// Musixmatch through its desktop web API: the broadest synced catalog,
/// regional songs included. An anonymous user token is fetched once and
/// kept. Best effort: any failure is "not found", so the chain moves on.
public actor MusixmatchProvider: LyricsProvider {
    public nonisolated let name = "Musixmatch"
    public nonisolated let reliability = 80
    public nonisolated let supportsCanonicalSpotifyLookup = true

    private let http: any HTTPFetching
    private let appID = "web-desktop-app-v1.0"
    private let base = "https://apic-desktop.musixmatch.com/ws/1.1/"
    private var cachedToken: String?

    public init(http: any HTTPFetching) {
        self.http = http
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        try await fetchPayload(query).result
    }

    public func fetchResponse(_ query: LyricsQuery) async throws -> LyricsResponse {
        let payload = try await fetchPayload(query)
        return LyricsResponse(result: payload.result, source: name, timingAuthority: payload.authority)
    }

    public func versions(for query: LyricsQuery) async throws -> [LyricsVersion] {
        let payload = try await fetchPayload(query)
        guard payload.result.hasLyrics else { return [] }
        let track = payload.track
        return [LyricsVersion(
            provider: name, reference: track?.id ?? query.cacheKey, title: track?.title ?? query.title,
            artist: track?.artist ?? query.artist, album: track?.album ?? query.album,
            duration: track?.duration ?? query.duration, kind: LyricsVersion.kind(of: payload.result), lyrics: payload.result
        )]
    }

    struct MatchedTrack: Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var duration: TimeInterval?
    }

    private func fetchPayload(_ query: LyricsQuery) async throws -> (result: LyricsResult, authority: LyricsTimingAuthority, track: MatchedTrack?) {
        guard let token = try await userToken() else { return (.notFound, .unverified, nil) }
        var items = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynched"),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
            URLQueryItem(name: "app_id", value: appID),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "q_track", value: query.title),
            URLQueryItem(name: "q_artist", value: query.artist),
        ]
        if let album = query.album { items.append(URLQueryItem(name: "q_album", value: album)) }
        if let duration = query.duration {
            items.append(URLQueryItem(name: "q_duration", value: String(Int(duration.rounded()))))
        }
        if let spotifyTrackID = query.spotifyTrackID {
            items.append(URLQueryItem(name: "track_spotify_id", value: spotifyTrackID))
        }
        guard let request = makeRequest("macro.subtitles.get", items) else { return (.notFound, .unverified, nil) }
        let (data, status) = try await http.send(request)
        // An expired anonymous token answers 401/403 (in HTTP or in the
        // body); forget it so the next lookup signs in again.
        if status == 401 || status == 403 {
            cachedToken = nil
            return (.notFound, .unverified, nil)
        }
        guard (200..<300).contains(status) else { return (.notFound, .unverified, nil) }
        let parsed = Self.parseMacro(data, query: query)
        if parsed.tokenExpired { cachedToken = nil }
        return (parsed.result, parsed.authority, parsed.track)
    }

    /// Reads a `macro.subtitles.get` answer: synced lyrics first, then
    /// plain, and how well the matched track proves the recording.
    static func parseMacro(_ data: Data, query: LyricsQuery) -> (result: LyricsResult, authority: LyricsTimingAuthority, track: MatchedTrack?, tokenExpired: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.notFound, .unverified, nil, false)
        }
        let message = json["message"] as? [String: Any]
        let statusCode = (message?["header"] as? [String: Any])?["status_code"] as? Int
        if statusCode == 401 || statusCode == 403 { return (.notFound, .unverified, nil, true) }
        let macros = (message?["body"] as? [String: Any])?["macro_calls"] as? [String: Any]
        let matched = Self.matchedTrack(macros: macros)
        let authority = Self.timingAuthority(macros: macros, query: query)

        if let subtitle = macros?["track.subtitles.get"] as? [String: Any],
           let body = (subtitle["message"] as? [String: Any])?["body"] as? [String: Any],
           let list = body["subtitle_list"] as? [[String: Any]],
           let lrc = (list.first?["subtitle"] as? [String: Any])?["subtitle_body"] as? String,
           !lrc.isEmpty {
            let parsed = LRCParser.parse(lrc)
            if parsed.lines.contains(where: { !$0.text.isEmpty }) { return (.synced(parsed), authority, matched, false) }
        }
        if let call = macros?["track.lyrics.get"] as? [String: Any],
           let body = (call["message"] as? [String: Any])?["body"] as? [String: Any],
           let plain = (body["lyrics"] as? [String: Any])?["lyrics_body"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.plain(plain), authority, matched, false)
        }
        if let instrumental = (Self.trackBody(macros)?["instrumental"] as? NSNumber)?.boolValue, instrumental {
            return (.instrumental, authority, matched, false)
        }
        return (.notFound, authority, matched, false)
    }

    private static func trackBody(_ macros: [String: Any]?) -> [String: Any]? {
        guard let matcher = macros?["matcher.track.get"] as? [String: Any],
              let message = matcher["message"] as? [String: Any],
              let body = message["body"] as? [String: Any]
        else { return nil }
        return body["track"] as? [String: Any]
    }

    private static func matchedTrack(macros: [String: Any]?) -> MatchedTrack? {
        guard let track = trackBody(macros), let title = track["track_name"] as? String else { return nil }
        let id = (track["track_id"] as? NSNumber)?.stringValue ?? (track["commontrack_id"] as? NSNumber)?.stringValue ?? title
        return MatchedTrack(
            id: id, title: title, artist: track["artist_name"] as? String ?? "",
            album: track["album_name"] as? String, duration: (track["track_length"] as? NSNumber)?.doubleValue
        )
    }

    static func timingAuthority(macros: [String: Any]?, query: LyricsQuery) -> LyricsTimingAuthority {
        guard let track = trackBody(macros) else { return .unverified }
        if let requested = query.spotifyTrackID {
            var identifiers: [String] = []
            if let primary = track["track_spotify_id"] as? String { identifiers.append(primary) }
            identifiers += track["commontrack_spotify_ids"] as? [String] ?? []
            if identifiers.compactMap(LyricsQuery.normalizedSpotifyTrackID).contains(requested) {
                return .canonicalRecording
            }
        }
        // Matching metadata is useful, not proof: masters share titles.
        let title = track["track_name"] as? String ?? ""
        let artist = track["artist_name"] as? String ?? ""
        let length = (track["track_length"] as? NSNumber)?.doubleValue
        let titleMatches = LyricsQuery.matchText(title) == LyricsQuery.matchText(query.title)
        let wanted = LyricsQuery.matchText(query.artist)
        let returned = LyricsQuery.matchText(artist)
        let artistMatches = !wanted.isEmpty && !returned.isEmpty && (wanted.contains(returned) || returned.contains(wanted))
        let durationMatches = length.map(query.durationMatches) != false
        return titleMatches && artistMatches && durationMatches ? .providerMatched : .unverified
    }

    private func userToken() async throws -> String? {
        if let cachedToken { return cachedToken }
        guard let request = makeRequest("token.get", [
            URLQueryItem(name: "app_id", value: appID),
            URLQueryItem(name: "format", value: "json"),
        ]) else { return nil }
        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = (json["message"] as? [String: Any])?["body"] as? [String: Any],
              let token = body["user_token"] as? String,
              token.count > 20
        else { return nil }
        cachedToken = token
        return token
    }

    private func makeRequest(_ endpoint: String, _ items: [URLQueryItem]) -> URLRequest? {
        guard var components = URLComponents(string: base + endpoint) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("AWSELB=0; AWSELBCORS=0", forHTTPHeaderField: "Cookie")
        return request
    }
}
