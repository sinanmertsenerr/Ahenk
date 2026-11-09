import CryptoKit
import Foundation

/// Lyrics fetched once load from disk afterwards: the network is asked only
/// the first time a song plays. Kept in `~/Library/Caches/Ahenk/Lyrics`,
/// one small JSON file per song (the name is a hash of the key), at most
/// `diskLimit` files, the oldest pruned first.
///
/// Misses (`instrumental`, `notFound`) are not stored, so lyrics uploaded
/// later are found on a later play.
public actor LyricsCache {
    /// `~/Library/Caches/Ahenk/Lyrics`.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk", isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
    }

    private let directory: URL
    private var memory: [String: LyricsResponse] = [:]
    /// Keys from the oldest to the newest use (memory LRU).
    private var accessOrder: [String] = []
    private let memoryLimit: Int
    private let diskLimit: Int
    private var didCreateDirectory = false

    public init(directory: URL = LyricsCache.standardDirectory, memoryLimit: Int = 64, diskLimit: Int = 600) {
        self.directory = directory
        self.memoryLimit = memoryLimit
        self.diskLimit = diskLimit
    }

    /// The stored lyrics for `key`: memory first, then disk.
    public func load(_ key: String) -> LyricsResponse? {
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let response = try? JSONDecoder().decode(LyricsResponse.self, from: data),
              response.result.hasLyrics
        else { return nil }
        memory[key] = response
        touch(key)
        return response
    }

    /// Stores lyrics for `key` (memory and disk); a result without lyrics
    /// is ignored.
    public func store(_ response: LyricsResponse, for key: String) {
        guard response.result.hasLyrics else { return }
        memory[key] = response
        touch(key)
        guard let data = try? JSONEncoder().encode(response) else { return }
        if !didCreateDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            didCreateDirectory = true
        }
        try? data.write(to: fileURL(for: key), options: .atomic)
        pruneIfNeeded()
    }

    public func remove(_ key: String) {
        memory[key] = nil
        accessOrder.removeAll { $0 == key }
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Forgets everything (Settings › Lyrics).
    public func removeAll() {
        memory = [:]
        accessOrder = []
        try? FileManager.default.removeItem(at: directory)
        didCreateDirectory = false
    }

    /// Number of files on disk.
    public func diskCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).count) ?? 0
    }

    private func touch(_ key: String) {
        if let index = accessOrder.firstIndex(of: key) { accessOrder.remove(at: index) }
        accessOrder.append(key)
        while memory.count > memoryLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            memory[oldest] = nil
        }
    }

    private func pruneIfNeeded() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ), files.count > diskLimit else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(dated.count - diskLimit) {
            try? manager.removeItem(at: url)
        }
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}
