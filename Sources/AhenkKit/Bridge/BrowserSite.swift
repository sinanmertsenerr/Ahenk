import Foundation

/// A music site the browser extension knows, and how its pages and songs map
/// onto Ahenk's sources and song IDs.
public enum BrowserSite: String, CaseIterable, Codable, Sendable {
    case youtubeMusic
    case youtube
    /// The Spotify Web Player (`open.spotify.com`).
    case spotify
    case soundCloud
    case amazonMusic
    case deezer
    case tidal

    public var source: MusicSource {
        switch self {
        case .youtubeMusic: .youtubeMusic
        case .youtube: .youtube
        case .spotify: .spotifyWeb
        case .soundCloud: .soundCloud
        case .amazonMusic: .amazonMusic
        case .deezer: .deezer
        case .tidal: .tidal
        }
    }

    public init?(source: MusicSource) {
        guard let site = Self.allCases.first(where: { $0.source == source }) else { return nil }
        self = site
    }

    /// The site of a page, from its host name (`nil` for anything else).
    public static func site(forHost rawHost: String) -> BrowserSite? {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("music.youtube.com") { return .youtubeMusic }
        if matches("youtube.com") || host == "youtu.be" || matches("youtube-nocookie.com") { return .youtube }
        if host == "open.spotify.com" { return .spotify }
        if matches("soundcloud.com") { return .soundCloud }
        if host.hasPrefix("music.amazon.") || host.contains(".music.amazon.") { return .amazonMusic }
        if matches("deezer.com") { return .deezer }
        if host == "listen.tidal.com" || host == "tidal.com" || host == "www.tidal.com" { return .tidal }
        return nil
    }

    public static func site(for url: URL) -> BrowserSite? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host else { return nil }
        return site(forHost: host)
    }

    /// The site a tab reports: its own ID when it is one of ours, checked
    /// against the page's host when there is one (a page cannot claim to be
    /// another site).
    public static func site(reported: String, url: String?) -> BrowserSite? {
        let named = BrowserSite(rawValue: reported)
        guard let url, let parsed = URL(string: url), let fromHost = site(for: parsed) else { return named }
        return fromHost
    }

    /// The song's ID in Ahenk's `Track.id` form: `spotify:track:<id>` for the
    /// Spotify Web Player (the lyrics' recording ID), the watch URL for
    /// YouTube and YouTube Music (the live wallpaper's video), the song's
    /// page elsewhere, `nil` when the site named nothing.
    public func trackIdentifier(trackID rawID: String?, trackURL: String?) -> String? {
        let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch self {
        case .spotify:
            if let id = id.flatMap(Self.spotifyTrackID) ?? trackURL.flatMap(Self.spotifyTrackID) {
                return "spotify:track:\(id)"
            }
            return nil
        case .youtubeMusic, .youtube:
            guard let video = id.flatMap(Self.youtubeVideoID) ?? trackURL.flatMap(Self.youtubeVideoID) else { return nil }
            return watchURL(videoID: video)?.absoluteString
        case .soundCloud, .amazonMusic, .deezer, .tidal:
            if let url = trackURL?.nilIfEmpty, let parsed = URL(string: url), Self.site(for: parsed) == self {
                return Self.canonical(parsed).absoluteString
            }
            return id.map { "\(rawValue):\($0)" }
        }
    }

    /// `https://music.youtube.com/watch?v=<id>` or `https://www.youtube.com/watch?v=<id>`.
    public func watchURL(videoID: String) -> URL? {
        switch self {
        case .youtubeMusic: URL(string: "https://music.youtube.com/watch?v=\(videoID)")
        case .youtube: URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        default: nil
        }
    }

    /// The 11-character video ID in a bare ID, a watch URL or a youtu.be link.
    public static func youtubeVideoID(_ text: String) -> String? {
        func valid(_ candidate: Substring) -> String? {
            candidate.count == 11 && candidate.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
                ? String(candidate) : nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bare = valid(trimmed[...]) { return bare }
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            return valid(components.path.dropFirst().split(separator: "/").first ?? "")
        }
        guard site(forHost: host) == .youtube || site(forHost: host) == .youtubeMusic else { return nil }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value { return valid(v[...]) }
        let parts = components.path.split(separator: "/")
        if parts.count >= 2, ["shorts", "embed", "live"].contains(String(parts[0])) { return valid(parts[1]) }
        return nil
    }

    /// The 22-character track ID in a bare ID, a `spotify:track:` URI or an
    /// `open.spotify.com/track/…` link (also `?highlight=spotify:track:…`).
    public static func spotifyTrackID(_ text: String) -> String? {
        if let found = LyricsQuery.normalizedSpotifyTrackID(text) { return found }
        guard let components = URLComponents(string: text),
              let highlight = components.queryItems?.first(where: { $0.name == "highlight" })?.value
        else { return nil }
        return LyricsQuery.normalizedSpotifyTrackID(highlight)
    }

    /// The URL without its query and fragment (playlist positions, tracking).
    static func canonical(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
