import Foundation

/// Ahenk's best guess about a song a browser reports through the system's
/// Now Playing, which names the browser but not the page.
public struct WebPlaybackGuess: Sendable, Equatable {
    /// The site, or `.otherApp` when nothing in the metadata names it.
    public var source: MusicSource
    public var contentKind: ContentKind
    /// The title without a site suffix (" - YouTube Music").
    public var title: String
    /// The artist without YouTube's channel decorations (" - Topic", "VEVO").
    public var artist: String
    public var isSiteKnown: Bool { source != .otherApp }
}

/// Infers the music site behind browser playback from its metadata. The
/// signals are weak on purpose: a site is only named when the metadata says
/// so (a page-title suffix, a host name, the brand as the artist). Step 7's
/// browser extension reports the exact site and replaces this guess.
public enum WebSiteInference {
    public static func guess(title rawTitle: String, artist rawArtist: String, album: String, artworkAspectRatio: Double?) -> WebPlaybackGuess {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        var site: MusicSource?

        // 1. A brand suffix in the title: "Song - YouTube Music",
        //    "Stream … | Listen online for free on SoundCloud".
        if let (brand, stripped) = splitBrandSuffix(title) {
            site = brand
            title = stripped
        }
        // 2. A host name anywhere ("music.youtube.com" as the artist).
        if site == nil {
            site = hostMarker(in: [rawTitle, rawArtist, album])
        }
        // 3. The brand itself as the artist (browsers fall back to the
        //    site's name when a page sets no metadata).
        if site == nil, let brand = brand(named: artist) {
            site = brand
            artist = ""
        }

        let musicHints = youtubeMusicHints(title: title, artist: artist)
        artist = cleanedYouTubeArtist(artist)

        let kind: ContentKind
        switch site {
        case .youtube:
            kind = musicHints ? .music : .video
        case .some:
            kind = .music
        case nil:
            if let ratio = artworkAspectRatio, abs(ratio - 1) > 0.15 {
                // Video thumbnails are wide; album covers are square.
                kind = musicHints ? .music : .video
            } else if !artist.isEmpty, !album.isEmpty {
                kind = .music
            } else {
                kind = musicHints ? .music : .unknown
            }
        }
        return WebPlaybackGuess(source: site ?? .otherApp, contentKind: kind, title: title, artist: artist)
    }

    // MARK: Signals

    private static let brands: [(name: String, source: MusicSource)] = [
        ("YouTube Music", .youtubeMusic),
        ("YouTube", .youtube),
        ("Spotify – Web Player", .spotifyWeb),
        ("Spotify - Web Player", .spotifyWeb),
        ("Spotify", .spotifyWeb),
        ("SoundCloud", .soundCloud),
        ("Amazon Music", .amazonMusic),
        ("Deezer", .deezer),
        ("TIDAL", .tidal),
    ]

    private static let hosts: [(host: String, source: MusicSource)] = [
        ("music.youtube.com", .youtubeMusic),
        ("youtube.com", .youtube),
        ("youtu.be", .youtube),
        ("open.spotify.com", .spotifyWeb),
        ("soundcloud.com", .soundCloud),
        ("music.amazon.", .amazonMusic),
        ("deezer.com", .deezer),
        ("tidal.com", .tidal),
    ]

    /// "Title - Brand", "Title | Brand", "… on Brand"; returns the brand and
    /// the title without it.
    static func splitBrandSuffix(_ title: String) -> (MusicSource, String)? {
        let separators = [" - ", " – ", " — ", " | ", " · ", " • "]
        for (name, source) in brands {
            for separator in separators {
                let suffix = separator + name
                if title.count > suffix.count, title.range(of: suffix, options: [.caseInsensitive, .backwards, .anchored]) != nil {
                    let stripped = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    return (source, stripped)
                }
            }
            // "Stream X by Y | Listen online for free on SoundCloud",
            // "Song by Artist on TIDAL".
            let onBrand = " on " + name
            if title.range(of: onBrand, options: [.caseInsensitive, .backwards, .anchored]) != nil {
                var stripped = String(title.dropLast(onBrand.count))
                if let bar = stripped.range(of: " | ", options: .backwards) {
                    stripped = String(stripped[..<bar.lowerBound])
                }
                return (source, stripped.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func hostMarker(in fields: [String]) -> MusicSource? {
        for field in fields where !field.isEmpty {
            let lower = field.lowercased()
            for (host, source) in hosts where lower.contains(host) {
                return source
            }
        }
        return nil
    }

    static func brand(named text: String) -> MusicSource? {
        brands.first { $0.name.compare(text, options: .caseInsensitive) == .orderedSame }?.source
    }

    /// YouTube auto-generated music channels ("Artist - Topic"), label
    /// channels ("ArtistVEVO") and the usual title tags mark music.
    static func youtubeMusicHints(title: String, artist: String) -> Bool {
        if artist.hasSuffix(" - Topic") || artist.hasSuffix("VEVO") { return true }
        let lower = title.lowercased()
        let tags = ["official audio", "official music video", "official video", "lyric video", "(lyrics)", "[lyrics]", "(audio)", "visualizer", " ft. ", " feat. "]
        return tags.contains { lower.contains($0) }
    }

    static func cleanedYouTubeArtist(_ artist: String) -> String {
        if artist.hasSuffix(" - Topic") { return String(artist.dropLast(" - Topic".count)) }
        if artist.hasSuffix("VEVO"), artist.count > 4 { return String(artist.dropLast(4)) }
        return artist
    }
}
