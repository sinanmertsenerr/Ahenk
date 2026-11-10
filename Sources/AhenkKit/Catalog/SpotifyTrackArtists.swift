import Foundation

/// Everyone who performs a Spotify song. The Spotify app tells other apps
/// only the first artist ("Jefe" for a song by Jefe and Motive), which
/// shows half the credit and searches for the wrong videos. The song's
/// public embed page (the player other sites put on their pages) lists
/// them all; it is read once per song, without an account, and kept.
public final class SpotifyTrackArtists: Sendable {
    static let lifetime: TimeInterval = 90 * 86_400
    static let missLifetime: TimeInterval = 86_400

    private struct Stored: Codable {
        var names: [String]
    }

    private let fetcher: any HTTPFetching
    private let cache: CatalogCache
    private let clock: @Sendable () -> Date

    public init(fetcher: any HTTPFetching, cache: CatalogCache = CatalogCache(directory: nil), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.cache = cache
        self.clock = clock
    }

    /// The song's artists in Spotify's order, or `nil` when they cannot be
    /// read. `identifier` is `spotify:track:…` or an open.spotify.com link.
    public func artists(of identifier: String) async -> [String]? {
        guard let id = SpotifyOEmbed.trackID(from: identifier) else { return nil }
        let key = "spotify-artists:v1:\(id)"
        if let stored = cache.value(Stored.self, forKey: key, maxAge: Self.lifetime, now: clock()) {
            if !stored.names.isEmpty { return stored.names }
            if cache.value(Stored.self, forKey: key, maxAge: Self.missLifetime, now: clock()) != nil { return nil }
        }
        guard let url = URL(string: "https://open.spotify.com/embed/track/\(id)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, status) = try? await fetcher.send(request), status == 200, data.count < 4_000_000,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        let names = Self.artists(inEmbedPage: html) ?? []
        cache.store(Stored(names: names), forKey: key, onDisk: true, now: clock())
        return names.isEmpty ? nil : names
    }

    /// The artists the embed page's data names, in order.
    public static func artists(inEmbedPage html: String) -> [String]? {
        guard let start = html.range(of: #"<script id="__NEXT_DATA__"[^>]*>"#, options: .regularExpression),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let props = (root["props"] as? [String: Any])?["pageProps"] as? [String: Any],
              let entity = ((props["state"] as? [String: Any])?["data"] as? [String: Any])?["entity"] as? [String: Any],
              let artists = entity["artists"] as? [[String: Any]]
        else { return nil }
        let names = artists.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    /// The names as one credit: "A, B, C". A name an earlier one already
    /// holds ("Duo" after "Duo & Friend") is said once.
    public static func credit(_ names: [String]) -> String {
        var kept: [String] = []
        for name in names {
            let plain = TrackMatching.normalized(name)
            guard !plain.isEmpty else { continue }
            let said = kept.contains { earlier in
                let other = TrackMatching.normalized(earlier)
                return other == plain || " \(other) ".contains(" \(plain) ")
            }
            if !said { kept.append(name) }
        }
        return kept.joined(separator: ", ")
    }
}
