import Foundation

/// Text normalization and song comparison shared by the hub (is this the
/// same song?), Continue Playing (deduplication) and catalog lookups (does
/// this search result match?).
public enum TrackMatching {
    /// Lower-cased, accent- and width-folded, punctuation turned into
    /// spaces, whitespace collapsed. Folding is locale-neutral, and the
    /// Turkish dotless ı is folded to i, so "IŞIK", "ışık" and "Isik" match.
    public static func normalized(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "&", with: " and ")
        var result = ""
        result.reserveCapacity(folded.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// The title without decorations that differ between services:
    /// "(feat. …)", "[Remastered 2011]", "- Radio Edit", "- 2015 Remaster".
    public static func coreTitle(_ title: String) -> String {
        var text = title
        // Bracketed parts: "(feat. X)", "[Live]", "(Remastered)".
        let bracketed = #"\s*[\(\[][^\)\]]*[\)\]]"#
        text = text.replacingOccurrences(of: bracketed, with: "", options: .regularExpression)
        // A trailing " - something" (remaster, edit, version, mix, live).
        let dashed = #"\s+[-–—]\s+.*(remaster|edit|version|mix|live|mono|stereo|demo|acoustic|bonus).*$"#
        text = text.replacingOccurrences(of: dashed, with: "", options: [.regularExpression, .caseInsensitive])
        // "feat." / "ft." without brackets.
        let featured = #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#
        text = text.replacingOccurrences(of: featured, with: "", options: [.regularExpression, .caseInsensitive])
        let core = normalized(text)
        return core.isEmpty ? normalized(title) : core
    }

    /// A stable identifier built from the metadata, for sources that do not
    /// name their songs.
    public static func metadataKey(title: String, artist: String, album: String) -> String {
        "meta:" + [title, artist, album].map(normalized).joined(separator: "|")
    }

    /// Same song by metadata: equal titles and artists (an empty artist is a
    /// half-loaded update and matches), compatible albums and durations.
    public static func sameSong(_ a: Track, _ b: Track) -> Bool {
        let titleA = normalized(a.title)
        guard !titleA.isEmpty, titleA == normalized(b.title) else { return false }
        let artistA = normalized(a.artist)
        let artistB = normalized(b.artist)
        guard artistA.isEmpty || artistB.isEmpty || artistA == artistB else { return false }
        let albumA = normalized(a.album)
        let albumB = normalized(b.album)
        guard albumA.isEmpty || albumB.isEmpty || albumA == albumB else { return false }
        if a.duration > 0, b.duration > 0, abs(a.duration - b.duration) > 3 { return false }
        return true
    }
}

extension Track {
    /// True for the same song from the same source: the same identifier, or
    /// matching metadata when two providers identify it differently.
    public func isSameSong(as other: Track) -> Bool {
        guard source == other.source else { return false }
        if id == other.id { return true }
        return TrackMatching.sameSong(self, other)
    }
}
