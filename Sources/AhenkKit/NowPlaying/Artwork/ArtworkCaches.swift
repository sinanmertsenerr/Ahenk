import Foundation
import os

/// Cover bytes on disk, in `~/Library/Caches/Ahenk/Artwork`: one file per
/// key (named by its hash), least recently used files pruned first.
///
/// macOS may delete the Caches folder at any time; everything here can be
/// fetched again.
public final class ArtworkDiskCache: Sendable {
    public let directory: URL
    public let maximumBytes: Int
    public let maximumAge: TimeInterval
    private let queue = DispatchQueue(label: "com.sinanmertsener.Ahenk.artwork-disk", qos: .utility)
    private static let log = AhenkLogger(category: "artwork")

    /// `~/Library/Caches/Ahenk/Artwork`.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk/Artwork", isDirectory: true)
    }

    public init(directory: URL = ArtworkDiskCache.standardDirectory, maximumBytes: Int = 200_000_000, maximumAge: TimeInterval = 60 * 86_400) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
    }

    public func url(forKey key: String) -> URL {
        directory.appendingPathComponent(ArtworkDigest.hex(of: key) + ".bin")
    }

    /// The stored bytes, refreshing the file's date (it is now recently used).
    public func data(forKey key: String) -> Data? {
        let url = url(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        queue.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return data
    }

    public func contains(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forKey: key).path)
    }

    /// Writes in the background; a failed write only costs a refetch.
    public func store(_ data: Data, forKey key: String) {
        let url = url(forKey: key)
        let directory = self.directory
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("Could not cache artwork: \(error.localizedDescription)")
            }
        }
    }

    public func remove(_ key: String) {
        let url = url(forKey: key)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Waits for queued writes (tests, quitting).
    public func flush() {
        queue.sync {}
    }

    /// Deletes files older than `maximumAge`, then the least recently used
    /// ones until the folder fits in `maximumBytes`.
    public func prune(now: Date = Date()) {
        queue.async { [self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            var entries: [(url: URL, date: Date, size: Int)] = []
            for file in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                let date = values?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(date) > maximumAge {
                    try? fm.removeItem(at: file)
                } else {
                    entries.append((file, date, values?.fileSize ?? 0))
                }
            }
            var total = entries.reduce(0) { $0 + $1.size }
            for entry in entries.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
                try? fm.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }
}

/// A small least-recently-used cache in memory, bounded by entry count and
/// by an approximate cost (bytes of decoded pixels).
struct MemoryLRU<Value: Sendable>: Sendable {
    private var entries: [String: (value: Value, cost: Int)] = [:]
    private var order: [String] = []
    private(set) var totalCost = 0
    let countLimit: Int
    let costLimit: Int

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    mutating func value(forKey key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    mutating func insert(_ value: Value, forKey key: String, cost: Int) {
        if let old = entries[key] { totalCost -= old.cost }
        entries[key] = (value, cost)
        totalCost += cost
        touch(key)
        while (entries.count > countLimit || totalCost > costLimit), let oldest = order.first, oldest != key {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { totalCost -= removed.cost }
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// HTTP GET for covers and catalog lookups; injectable for tests.
public protocol HTTPFetching: Sendable {
    /// The body and status code of a GET request.
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

/// `URLSession` without its own cache (Ahenk caches covers itself).
public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Ahenk (macOS; github.com/sinanmertsenerr/Ahenk)"]
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
