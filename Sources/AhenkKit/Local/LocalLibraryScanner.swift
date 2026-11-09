@preconcurrency import AVFoundation
import Foundation

/// A file's tags as AVFoundation reads them (ID3, iTunes, QuickTime,
/// Vorbis comments in FLAC).
public struct LocalTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var hasArtwork: Bool
    public var isPlayable: Bool

    public init(
        title: String? = nil, artist: String? = nil, albumArtist: String? = nil, album: String? = nil, trackNumber: Int? = nil,
        discNumber: Int? = nil, duration: TimeInterval = 0, hasArtwork: Bool = false, isPlayable: Bool = true
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.hasArtwork = hasArtwork
        self.isPlayable = isPlayable
    }
}

/// Reads song files: their tags, their length and their cover.
public enum LocalMetadata {
    /// The file's tags (empty fields when it has none).
    public static func tags(of url: URL) async -> LocalTags {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let (duration, playable, common, all) = try? await asset.load(.duration, .isPlayable, .commonMetadata, .metadata) else {
            return LocalTags(isPlayable: false)
        }
        var tags = LocalTags()
        tags.duration = duration.seconds.isFinite ? max(0, duration.seconds) : 0
        tags.isPlayable = playable
        let items = common + all
        tags.title = await string(items, common: .commonKeyTitle, identifiers: [.id3MetadataTitleDescription, .iTunesMetadataSongName, .quickTimeMetadataTitle])
        tags.artist = await string(items, common: .commonKeyArtist, identifiers: [.id3MetadataLeadPerformer, .iTunesMetadataArtist, .quickTimeMetadataArtist])
        tags.album = await string(items, common: .commonKeyAlbumName, identifiers: [.id3MetadataAlbumTitle, .iTunesMetadataAlbum, .quickTimeMetadataAlbum])
        tags.albumArtist = await string(items, common: nil, identifiers: [.iTunesMetadataAlbumArtist, .id3MetadataBand])
        tags.trackNumber = await number(items, identifiers: [.iTunesMetadataTrackNumber, .id3MetadataTrackNumber])
        tags.discNumber = await number(items, identifiers: [.iTunesMetadataDiscNumber, .id3MetadataPartOfASet])
        tags.hasArtwork = items.contains { $0.commonKey == .commonKeyArtwork || $0.identifier == .iTunesMetadataCoverArt || $0.identifier == .id3MetadataAttachedPicture }
        return tags
    }

    /// The cover inside the file, as encoded image bytes.
    public static func embeddedArtwork(of url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let (common, all) = try? await asset.load(.commonMetadata, .metadata) else { return nil }
        for item in common + all where item.commonKey == .commonKeyArtwork || item.identifier == .iTunesMetadataCoverArt || item.identifier == .id3MetadataAttachedPicture {
            if let data = try? await item.load(.dataValue), data.count > 64 { return data }
            if let value = try? await item.load(.value) as? Data, value.count > 64 { return value }
        }
        return nil
    }

    /// Picture files a folder of songs often has for its album.
    public static let folderArtworkNames = ["cover", "folder", "front", "album", "artwork", "albumart", "kapak"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]

    /// The album picture next to a song (`cover.jpg`, `folder.png`…).
    public static func folderArtwork(near url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let candidates = names.filter { name in
            let stem = ((name as NSString).deletingPathExtension).lowercased()
            return imageExtensions.contains((name as NSString).pathExtension.lowercased())
                && folderArtworkNames.contains(where: { stem == $0 || stem.hasPrefix($0 + " ") || stem.hasPrefix($0 + "_") })
        }
        let ranked = candidates.sorted { a, b in
            let ra = folderArtworkNames.firstIndex { a.lowercased().hasPrefix($0) } ?? 99
            let rb = folderArtworkNames.firstIndex { b.lowercased().hasPrefix($0) } ?? 99
            return ra == rb ? a < b : ra < rb
        }
        return ranked.first.map { folder.appendingPathComponent($0) }
    }

    /// The song's cover: inside the file, else the folder's picture.
    public static func artwork(of url: URL) async -> Data? {
        if let data = await embeddedArtwork(of: url) { return data }
        guard let picture = folderArtwork(near: url), let data = try? Data(contentsOf: picture), data.count > 64,
              data.count < 30_000_000
        else { return nil }
        return data
    }

    private static func string(_ items: [AVMetadataItem], common: AVMetadataKey?, identifiers: [AVMetadataIdentifier]) async -> String? {
        let matching = items.filter { item in
            (common != nil && item.commonKey == common) || (item.identifier.map(identifiers.contains) ?? false)
        }
        for item in matching {
            if let text = try? await item.load(.stringValue) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: "")
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func number(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> Int? {
        for item in items where item.identifier.map(identifiers.contains) ?? false {
            if let text = try? await item.load(.stringValue), let value = parseNumber(text) { return value }
            if let data = try? await item.load(.dataValue), let value = parseNumber(data) { return value }
            if let value = try? await item.load(.numberValue), value.intValue > 0 { return value.intValue }
        }
        return nil
    }

    /// "3", "3/12", " 03 / 12 " → 3.
    public static func parseNumber(_ text: String) -> Int? {
        let first = text.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let value = Int(first), value > 0, value < 10_000 else { return nil }
        return value
    }

    /// iTunes' binary `trkn`/`disk` atom: two reserved bytes, the number
    /// (big-endian 16 bits), the total.
    public static func parseNumber(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }
}

/// Finds songs in folders.
public enum LocalLibraryScanner {
    /// What AVFoundation plays on macOS 14 and later.
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "mp4a", "m4b"]
    /// A folder of more songs is cut here (the queue and lists stay quick).
    public static let maximumFiles = 4000

    /// Audio files in `folder` and its subfolders (hidden files and
    /// packages skipped), in a stable order: by folder, then by name in
    /// Finder's order ("2" before "10").
    public static func audioFiles(in folder: URL, limit: Int = maximumFiles) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found.append(url.standardizedFileURL)
            if found.count >= limit { break }
        }
        return found.sorted { a, b in
            let folderA = a.deletingLastPathComponent().path, folderB = b.deletingLastPathComponent().path
            if folderA != folderB { return folderA.localizedStandardCompare(folderB) == .orderedAscending }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    /// The song of one file: its tags, the file's name where they say
    /// nothing. `nil` for a file AVFoundation cannot play (DRM, damaged).
    public static func song(at url: URL, root: URL?) async -> LocalSong? {
        let tags = await LocalMetadata.tags(of: url)
        guard tags.isPlayable else { return nil }
        return song(at: url, root: root, tags: tags)
    }

    public static func song(at url: URL, root: URL?, tags: LocalTags) -> LocalSong {
        let guess = LocalFileNames.guess(fileName: url.lastPathComponent, folders: folders(of: url, root: root))
        let artist = tags.artist ?? tags.albumArtist ?? guess.artist
        return LocalSong(
            path: url.standardizedFileURL.path,
            title: tags.title ?? guess.title,
            artist: artist,
            album: tags.album ?? guess.album,
            duration: tags.duration,
            trackNumber: tags.trackNumber ?? guess.trackNumber,
            discNumber: tags.discNumber ?? guess.discNumber
        )
    }

    /// The folders from `root` (its own name first) down to the file's.
    static func folders(of url: URL, root: URL?) -> [String] {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard let root = root?.standardizedFileURL else { return [folder.lastPathComponent] }
        let rootComponents = root.pathComponents
        let components = folder.pathComponents
        guard components.count >= rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else {
            return [folder.lastPathComponent]
        }
        return [root.lastPathComponent] + components.dropFirst(rootComponents.count)
    }

    /// Every song in `folder`, tags read a few at a time, in album order:
    /// by folder, disc, track number, then name.
    public static func songs(in folder: URL, limit: Int = maximumFiles) async -> [LocalSong] {
        let files = audioFiles(in: folder, limit: limit)
        return await songs(of: files, root: folder)
    }

    /// The songs of these files (dropped on the list), in album order.
    public static func songs(of files: [URL], root: URL?) async -> [LocalSong] {
        var results: [(Int, LocalSong)] = []
        await withTaskGroup(of: (Int, LocalSong?).self) { group in
            var next = 0
            let width = 8
            func add() {
                guard next < files.count else { return }
                let index = next
                let url = files[index]
                next += 1
                group.addTask { (index, await song(at: url, root: root)) }
            }
            for _ in 0..<width { add() }
            while let (index, song) = await group.next() {
                if let song { results.append((index, song)) }
                add()
            }
        }
        let ordered = results.sorted { $0.0 < $1.0 }.map(\.1)
        return sortedForPlaying(ordered)
    }

    /// Album order: songs of one folder stay together in the folders'
    /// order; inside a folder by disc, track number, then file name.
    public static func sortedForPlaying(_ songs: [LocalSong]) -> [LocalSong] {
        var folderRank: [String: Int] = [:]
        for song in songs {
            let folder = (song.path as NSString).deletingLastPathComponent
            if folderRank[folder] == nil { folderRank[folder] = folderRank.count }
        }
        return songs.enumerated().sorted { a, b in
            let fa = folderRank[(a.element.path as NSString).deletingLastPathComponent] ?? 0
            let fb = folderRank[(b.element.path as NSString).deletingLastPathComponent] ?? 0
            if fa != fb { return fa < fb }
            let da = a.element.discNumber ?? 1, db = b.element.discNumber ?? 1
            if da != db { return da < db }
            switch (a.element.trackNumber, b.element.trackNumber) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = (a.element.path as NSString).lastPathComponent.localizedStandardCompare((b.element.path as NSString).lastPathComponent)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }
        }.map(\.element)
    }
}
