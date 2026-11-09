import Foundation
import os

/// Answers from public catalogs, kept in memory and (for answers that
/// change slowly) on disk in `~/Library/Caches/Ahenk/Catalog`, each with
/// the time it was stored so readers decide how old is too old.
public final class CatalogCache: Sendable {
    private struct Stored: Codable {
        var storedAt: Date
        var payload: Data
    }

    private let disk: ArtworkDiskCache?
    private let memory = OSAllocatedUnfairLock(initialState: MemoryLRU<Data>(countLimit: 300, costLimit: 12_000_000))

    /// `~/Library/Caches/Ahenk/Catalog`.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk/Catalog", isDirectory: true)
    }

    /// `directory: nil` keeps everything in memory (tests, demo).
    public init(directory: URL?) {
        disk = directory.map { ArtworkDiskCache(directory: $0, maximumBytes: 40_000_000, maximumAge: 45 * 86_400) }
    }

    /// The value stored under `key` within the last `maxAge` seconds.
    public func value<T: Decodable>(_ type: T.Type, forKey key: String, maxAge: TimeInterval, now: Date = Date()) -> T? {
        let encoded = memory.withLock { $0.value(forKey: key) } ?? disk?.data(forKey: key)
        guard let encoded, let stored = try? Self.decoder.decode(Stored.self, from: encoded),
              now.timeIntervalSince(stored.storedAt) <= maxAge,
              let value = try? Self.decoder.decode(T.self, from: stored.payload)
        else { return nil }
        memory.withLock { $0.insert(encoded, forKey: key, cost: encoded.count) }
        return value
    }

    /// Stores `value`; `onDisk` also writes it to the disk cache.
    public func store<T: Encodable>(_ value: T, forKey key: String, onDisk: Bool, now: Date = Date()) {
        guard let payload = try? Self.encoder.encode(value),
              let encoded = try? Self.encoder.encode(Stored(storedAt: now, payload: payload))
        else { return }
        memory.withLock { $0.insert(encoded, forKey: key, cost: encoded.count) }
        if onDisk { disk?.store(encoded, forKey: key) }
    }

    /// Waits for queued disk writes (tests).
    public func flush() {
        disk?.flush()
    }

    /// Deletes old files (at launch).
    public func prune() {
        disk?.prune()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
