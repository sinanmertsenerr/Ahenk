import Foundation

/// A song file Ahenk plays itself (the "Local" source).
public struct LocalSong: Hashable, Sendable, Codable, Identifiable {
    /// The file's path: the song's ID everywhere (`Track.id`).
    public var path: String
    public var title: String
    /// Empty when neither the tags nor the file's name say.
    public var artist: String
    public var album: String
    /// Seconds; 0 when unknown.
    public var duration: TimeInterval
    public var trackNumber: Int?
    public var discNumber: Int?

    public init(
        path: String, title: String, artist: String, album: String = "", duration: TimeInterval = 0,
        trackNumber: Int? = nil, discNumber: Int? = nil
    ) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    /// The song as the hub, Continue Playing and the lyrics see it.
    public var track: Track {
        Track(id: path, source: .local, title: title, artist: artist, album: album, duration: duration)
    }

    /// The song as the desktop player's lists and queue show it.
    public var catalogSong: CatalogSong {
        var song = CatalogSong(playing: track)
        song.trackNumber = trackNumber
        song.discNumber = discNumber
        return song
    }

    /// The file a list's song names, when it is a local song.
    public static func path(of song: CatalogSong) -> String? {
        guard let origin = song.origin, origin.source == .local, origin.id.hasPrefix("/") else { return nil }
        return origin.id
    }

    /// A local song back from a list's song (its file and its details).
    public init?(_ song: CatalogSong) {
        guard let path = Self.path(of: song) else { return nil }
        self.init(
            path: path, title: song.title, artist: song.artistName, album: song.albumTitle, duration: song.duration,
            trackNumber: song.trackNumber, discNumber: song.discNumber
        )
    }
}

/// What a file's name and folders say about a song without tags:
/// "01 - Title", "1-03 Title" (disc 1, track 3), "Artist - Title",
/// "01 - Artist - Title"; the folder is the album unless it is a generic
/// one (Music, Downloads…); with Artist/Album folders inside the chosen
/// folder, the outer one is the artist.
public enum LocalFileNames {
    public struct Guess: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var trackNumber: Int?
        public var discNumber: Int?
    }

    /// Folder names that never name an album (English and Turkish), folded
    /// as `fold` does.
    public static let genericFolders: Set<String> = [
        "music", "muzik", "downloads", "indirilenler", "desktop", "masaustu", "documents", "belgeler", "audio", "songs",
        "sarkilar", "mp3", "mp3s", "itunes", "itunes media", "media", "unknown album", "new folder", "yeni klasor",
        "untitled folder", "adsiz klasor",
    ]

    /// - Parameters:
    ///   - fileName: the file's name, with or without its extension.
    ///   - folders: the folders from the chosen folder (first) down to the
    ///     file's own folder (last).
    public static func guess(fileName: String, folders: [String]) -> Guess {
        var stem = (fileName as NSString).deletingPathExtension
        if stem.isEmpty { stem = fileName }
        stem = stem.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var trackNumber: Int?
        var discNumber: Int?

        // "1-03 Title", "103 Title" is too ambiguous; "01 Title", "01. Title", "01 - Title".
        if let match = stem.firstMatch(of: /^(\d{1,2})[-.](\d{1,3})(?:\s*[-.)]\s*|\s+)(.+)$/) {
            discNumber = Int(match.1)
            trackNumber = Int(match.2)
            stem = String(match.3)
        } else if let match = stem.firstMatch(of: /^(\d{1,3})(?:\s*[-.)]\s*|\s+)(.+)$/) {
            trackNumber = Int(match.1)
            stem = String(match.2)
        }
        var artist = ""
        var title = stem
        let parts = stem.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            if parts.count >= 3, trackNumber == nil, let number = Int(parts[parts.count - 2]), (1...999).contains(number) {
                // "Artist - Album - 01 - Title"
                trackNumber = number
                artist = parts[0]
                title = parts[parts.count - 1]
            } else {
                artist = parts[0]
                title = parts.dropFirst().joined(separator: " - ")
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = (fileName as NSString).deletingPathExtension }

        let usable = folders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var album = ""
        if let last = usable.last, !isGeneric(last) {
            album = last
            // Artist/Album inside the chosen folder: the outer one names the artist.
            if artist.isEmpty, usable.count >= 3, !isGeneric(usable[usable.count - 2]) {
                artist = usable[usable.count - 2]
            }
        }
        return Guess(title: title, artist: artist, album: album, trackNumber: trackNumber, discNumber: discNumber)
    }

    public static func isGeneric(_ folder: String) -> Bool {
        let folded = fold(folder)
        return folded.isEmpty || genericFolders.contains(folded)
    }

    /// Case, accents and the Turkish dotless ı folded, locale-neutrally
    /// ("İndirilenler" → "indirilenler", "Şarkılar" → "sarkilar").
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
