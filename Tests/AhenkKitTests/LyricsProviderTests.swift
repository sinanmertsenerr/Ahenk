import Foundation
import os
import Testing
@testable import AhenkKit

// Every title, artist and line in these fixtures is invented.

/// Answers requests by the first route whose fragment the URL contains,
/// in order, and records every request with its headers.
final class RouteFetcher: HTTPFetching, Sendable {
    struct Route: Sendable {
        var fragment: String
        var body: String
        var status: Int
    }

    private let state: OSAllocatedUnfairLock<(routes: [Route], requests: [URLRequest])>

    init(_ routes: [(String, String, Int)] = []) {
        state = OSAllocatedUnfairLock(initialState: (routes.map { Route(fragment: $0.0, body: $0.1, status: $0.2) }, []))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var urls: [String] { requests.compactMap { $0.url?.absoluteString } }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let text = request.url?.absoluteString.removingPercentEncoding ?? ""
        let route = state.withLock { state -> Route? in
            state.requests.append(request)
            return state.routes.first { text.contains($0.fragment) }
        }
        guard let route else { throw URLError(.notConnectedToInternet) }
        return (Data(route.body.utf8), route.status)
    }
}

enum LyricsFixtures {
    static let lrc = """
    [00:05.00]Counting rooftops in the rain
    [00:09.00]Every gutter hums a tune
    [00:13.00]Paper lanterns over the lane
    [00:17.00]Holding on to afternoon
    [00:21.00]Back beneath the copper sky
    [00:25.00]Every window waves goodbye
    """

    static func row(id: Int, title: String = "Paper Lanterns", artist: String = "The Tin Orchard", duration: Double = 192,
                    synced: String? = lrc, plain: String? = "Counting rooftops in the rain", instrumental: Bool = false) -> String {
        func json(_ value: String?) -> String {
            guard let value else { return "null" }
            let data = try! JSONSerialization.data(withJSONObject: [value])
            return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
        }
        return """
        {"id": \(id), "trackName": \(json(title)), "artistName": \(json(artist)), "albumName": "Rooftop Weather",
         "duration": \(duration), "instrumental": \(instrumental), "plainLyrics": \(json(plain)), "syncedLyrics": \(json(synced))}
        """
    }

    /// `lrc` with every timestamp moved by `seconds`.
    static func shiftedLRC(_ seconds: Double) -> String {
        let lyrics = LRCParser.parse(lrc).shifted(by: seconds)
        return lyrics.lines.map { line in
            let minutes = Int(line.start) / 60
            let rest = line.start - Double(minutes * 60)
            return String(format: "[%02d:%05.2f]%@", minutes, rest, line.text)
        }.joined(separator: "\n")
    }

    static let query = LyricsQuery(title: "Paper Lanterns", artist: "The Tin Orchard", album: "Rooftop Weather", duration: 192)
}

@Suite("Lyrics providers")
struct LyricsProviderTests {
    @Test("LRCLIB: the exact match wins and says who asked")
    func lrclibExact() async throws {
        let fetcher = RouteFetcher([
            ("/api/get", LyricsFixtures.row(id: 1), 200),
            ("/api/search", "[]", 200),
        ])
        let result = try await LRCLIBProvider(http: fetcher).fetch(LyricsFixtures.query)
        guard case .synced(let lyrics) = result else { Issue.record("expected synced lyrics"); return }
        #expect(lyrics.lines.count == 6 && lyrics.lines[0].text == "Counting rooftops in the rain")
        let get = try #require(fetcher.requests.first { $0.url?.path == "/api/get" })
        let items = URLComponents(url: get.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "track_name", value: "Paper Lanterns")))
        #expect(items.contains(URLQueryItem(name: "duration", value: "192")))
        #expect(get.value(forHTTPHeaderField: "User-Agent")?.contains("Ahenk") == true)
    }

    @Test("LRCLIB: without an exact match the best-scored search row of the same length is taken")
    func lrclibSearch() async throws {
        let rows = [
            LyricsFixtures.row(id: 7, title: "Paper Lanterns (Live)", duration: 240),
            LyricsFixtures.row(id: 8, title: "Paper Lanterns", duration: 192.4),
            LyricsFixtures.row(id: 9, title: "Something Else", artist: "Nobody", duration: 191),
        ]
        let fetcher = RouteFetcher([
            ("/api/get", #"{"code":404,"name":"TrackNotFound"}"#, 404),
            ("/api/search", "[\(rows.joined(separator: ","))]", 200),
        ])
        let provider = LRCLIBProvider(http: fetcher)
        guard case .synced = try await provider.fetch(LyricsFixtures.query) else { Issue.record("expected synced"); return }
        let versions = try await provider.versions(for: LyricsFixtures.query)
        #expect(versions.first?.reference == "8", "the matching title and length come first")
        #expect(!versions.contains { $0.reference == "7" }, "a 48 s longer cut is another recording")
        #expect(versions.allSatisfy { $0.provider == "LRCLIB" && $0.lyrics != nil })
    }

    @Test("LRCLIB: plain and instrumental answers")
    func lrclibOtherKinds() async throws {
        let plain = RouteFetcher([("/api/get", LyricsFixtures.row(id: 2, synced: nil), 200), ("/api/search", "[]", 200)])
        #expect(try await LRCLIBProvider(http: plain).fetch(LyricsFixtures.query) == .plain("Counting rooftops in the rain"))
        let instrumental = RouteFetcher([("/api/get", LyricsFixtures.row(id: 3, synced: nil, plain: nil, instrumental: true), 200), ("/api/search", "[]", 200)])
        #expect(try await LRCLIBProvider(http: instrumental).fetch(LyricsFixtures.query) == .instrumental)
        let nothing = RouteFetcher([("/api/get", "{}", 404), ("/api/search", "[]", 200)])
        #expect(try await LRCLIBProvider(http: nothing).fetch(LyricsFixtures.query) == .notFound)
        let down = RouteFetcher()
        await #expect(throws: URLError.self) { try await LRCLIBProvider(http: down).fetch(LyricsFixtures.query) }
    }

    @Test("LRCLIB: three uploads vote a copy synced to another edit out")
    func lrclibVote() async throws {
        let late = LyricsFixtures.shiftedLRC(1.5)
        let fetcher = RouteFetcher([
            ("/api/get", LyricsFixtures.row(id: 1, synced: late), 200),
            ("/api/search", "[\(LyricsFixtures.row(id: 2)),\(LyricsFixtures.row(id: 3, duration: 191.5)),\(LyricsFixtures.row(id: 1, synced: late))]", 200),
        ])
        guard case .synced(let lyrics) = try await LRCLIBProvider(http: fetcher).fetch(LyricsFixtures.query) else {
            Issue.record("expected synced"); return
        }
        #expect(lyrics.lines[0].start == 5, "the majority's timing, not the exact row's late copy")
    }

    @Test("LRCLIB: a free search and loading a result by its ID")
    func lrclibSearchAndLoad() async throws {
        let fetcher = RouteFetcher([
            ("/api/search?q=lanterns", "[\(LyricsFixtures.row(id: 11, synced: nil))]", 200),
            ("/api/get/42", LyricsFixtures.row(id: 42), 200),
        ])
        let provider = LRCLIBProvider(http: fetcher)
        let found = try await provider.search(LyricsQuery(title: "lanterns", artist: ""))
        #expect(found.map(\.reference) == ["11"] && found.first?.kind == .plain)
        let version = LyricsVersion(provider: "LRCLIB", reference: "42", title: "Paper Lanterns", artist: "The Tin Orchard", kind: .unknown)
        guard case .synced = try await provider.lyrics(of: version) else { Issue.record("expected synced"); return }
    }

    static func macro(lrc: String?, plain: String?, track: [String: Any], status: Int = 200) -> String {
        var calls: [String: Any] = ["matcher.track.get": ["message": ["header": ["status_code": 200], "body": ["track": track]]]]
        if let lrc {
            calls["track.subtitles.get"] = ["message": ["body": ["subtitle_list": [["subtitle": ["subtitle_body": lrc]]]]]]
        }
        if let plain {
            calls["track.lyrics.get"] = ["message": ["body": ["lyrics": ["lyrics_body": plain]]]]
        }
        let json: [String: Any] = ["message": ["header": ["status_code": status], "body": ["macro_calls": calls]]]
        return String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    }

    static let token = #"{"message":{"header":{"status_code":200},"body":{"user_token":"invented-token-0123456789abcdef"}}}"#

    @Test("Musixmatch: synced lyrics, provenance and a Spotify recording match")
    func musixmatch() async throws {
        let track: [String: Any] = [
            "track_id": 314, "track_name": "Paper Lanterns", "artist_name": "The Tin Orchard", "track_length": 192,
            "track_spotify_id": "0123456789abcdefABCDEF",
        ]
        let fetcher = RouteFetcher([
            ("token.get", Self.token, 200),
            ("macro.subtitles.get", Self.macro(lrc: LyricsFixtures.lrc, plain: "words", track: track), 200),
        ])
        let provider = MusixmatchProvider(http: fetcher)
        let response = try await provider.fetchResponse(LyricsFixtures.query)
        guard case .synced(let lyrics) = response.result else { Issue.record("expected synced"); return }
        #expect(lyrics.lines.count == 6 && response.timingAuthority == .providerMatched && response.source == "Musixmatch")
        let spotify = LyricsQuery(title: "Paper Lanterns", artist: "The Tin Orchard", duration: 192, spotifyTrackID: "spotify:track:0123456789abcdefABCDEF")
        #expect(try await provider.fetchResponse(spotify).timingAuthority == .canonicalRecording)
        let macroRequest = try #require(fetcher.requests.last)
        #expect(macroRequest.url?.absoluteString.contains("track_spotify_id=0123456789abcdefABCDEF") == true)
        #expect(macroRequest.value(forHTTPHeaderField: "Cookie") != nil)
        let versions = try await provider.versions(for: LyricsFixtures.query)
        #expect(versions.first?.reference == "314" && versions.first?.kind == .synced)
    }

    @Test("Musixmatch: plain only, an expired token and broken answers are not lyrics")
    func musixmatchOther() async throws {
        let track: [String: Any] = ["track_id": 1, "track_name": "Elsewhere", "artist_name": "Someone"]
        let plain = RouteFetcher([("token.get", Self.token, 200), ("macro.subtitles.get", Self.macro(lrc: nil, plain: "Just words", track: track), 200)])
        let response = try await MusixmatchProvider(http: plain).fetchResponse(LyricsFixtures.query)
        #expect(response.result == .plain("Just words") && response.timingAuthority == .unverified)
        let expired = RouteFetcher([("token.get", Self.token, 200), ("macro.subtitles.get", Self.macro(lrc: LyricsFixtures.lrc, plain: nil, track: track, status: 401), 200)])
        #expect(try await MusixmatchProvider(http: expired).fetch(LyricsFixtures.query) == .notFound)
        let broken = RouteFetcher([("token.get", Self.token, 200), ("macro.subtitles.get", "<html>", 200)])
        #expect(try await MusixmatchProvider(http: broken).fetch(LyricsFixtures.query) == .notFound)
        let noToken = RouteFetcher([("token.get", #"{"message":{"body":{}}}"#, 200)])
        #expect(try await MusixmatchProvider(http: noToken).fetch(LyricsFixtures.query) == .notFound)
    }

    static func neteaseSongs(_ songs: [(Int, String, String, Double)]) -> String {
        let items = songs.map { #"{"id": \#($0.0), "name": "\#($0.1)", "artists": [{"name": "\#($0.2)"}], "album": {"name": "Rooftop Weather"}, "duration": \#($0.3)}"# }
        return #"{"result": {"songs": [\#(items.joined(separator: ","))]}}"#
    }

    @Test("NetEase: the matching title and artist, credits stripped")
    func netease() async throws {
        let withCredits = "[00:00.00] 作词 : Invented Writer\n[00:00.50] Mixed by : Invented Mixer\n" + LyricsFixtures.lrc
        let lyric = String(data: try JSONSerialization.data(withJSONObject: ["lrc": ["lyric": withCredits]]), encoding: .utf8)!
        let fetcher = RouteFetcher([
            ("/api/search/get", Self.neteaseSongs([(5, "Paper Lanterns", "Somebody Else", 192_000), (6, "Paper Lanterns", "The Tin Orchard", 192_300)]), 200),
            ("/api/song/lyric?id=6", lyric, 200),
        ])
        let provider = NetEaseProvider(http: fetcher)
        guard case .synced(let lyrics) = try await provider.fetch(LyricsFixtures.query) else { Issue.record("expected synced"); return }
        #expect(lyrics.lines.first?.text == "Counting rooftops in the rain", "credits are not lyrics")
        #expect(fetcher.requests.contains { $0.value(forHTTPHeaderField: "Referer") == "https://music.163.com" })
        let found = try await provider.search(LyricsFixtures.query)
        #expect(found.map(\.reference) == ["5", "6"] && found.allSatisfy { $0.kind == .unknown && $0.lyrics == nil })
        #expect(abs((found.first?.duration ?? 0) - 192) < 1e-9)
    }

    @Test("NetEase: never an unrelated song")
    func neteaseMismatch() async throws {
        let fetcher = RouteFetcher([("/api/search/get", Self.neteaseSongs([(5, "Another Song", "The Tin Orchard", 192_000)]), 200)])
        #expect(try await NetEaseProvider(http: fetcher).fetch(LyricsFixtures.query) == .notFound)
        #expect(NetEaseProvider.stripCredits("[00:00.00]作曲：X\n[00:01.00]Kept") == "[00:01.00]Kept")
    }

    @Test("Queries: cleaned titles, folded text, Spotify IDs and lengths")
    func queries() {
        let noisy = LyricsQuery(title: "Paper Lanterns (feat. Someone) - Remastered 2011", artist: "The Tin Orchard feat. Someone")
        #expect(noisy.sanitized.title == "Paper Lanterns" && noisy.sanitized.artist == "The Tin Orchard")
        #expect(LyricsQuery.matchText("KIRIK Çay, Işık!") == "kirik cay isik")
        #expect(LyricsQuery(title: "a", artist: "b", spotifyTrackID: "https://open.spotify.com/track/0123456789abcdefABCDEF?si=x").spotifyTrackID == "0123456789abcdefABCDEF")
        #expect(LyricsQuery(title: "a", artist: "b", spotifyTrackID: "spotify:local:x").spotifyTrackID == nil)
        let track = Track(id: "spotify:track:0123456789abcdefABCDEF", source: .spotify, title: "a", artist: "b", duration: 200)
        #expect(LyricsQuery(track: track).cacheKey.contains("0123456789abcdefABCDEF"))
        #expect(LyricsFixtures.query.durationMatches(193.9) && !LyricsFixtures.query.durationMatches(195))
    }
}
