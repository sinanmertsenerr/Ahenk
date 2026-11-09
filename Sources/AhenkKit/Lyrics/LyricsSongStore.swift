import Foundation
import os

/// What Ahenk remembers about one song's lyrics.
public struct LyricsSongEntry: Codable, Equatable, Sendable {
    /// The user's timing nudge, in seconds; positive shows the lines
    /// earlier. Replaces (never adds to) the automatic value.
    public var manualOffset: Double?
    /// Measured by automatic sync for the timeline `autoFingerprint`.
    public var autoOffset: Double?
    public var autoFingerprint: String?
    /// The version the user picked ("Other Lyrics", "Search Lyrics"),
    /// kept without its lyrics (those live in the cache).
    public var choice: LyricsVersion?
    public var updatedAt: Date

    public init(manualOffset: Double? = nil, autoOffset: Double? = nil, autoFingerprint: String? = nil, choice: LyricsVersion? = nil, updatedAt: Date = Date()) {
        self.manualOffset = manualOffset
        self.autoOffset = autoOffset
        self.autoFingerprint = autoFingerprint
        self.choice = choice
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool { manualOffset == nil && autoOffset == nil && choice == nil }
}

/// Per-song lyrics data — timing offsets (the user's nudge and the
/// measured one) and the chosen version — in
/// `~/Library/Application Support/Ahenk/LyricsSongs.json`, keyed by
/// `LyricsQuery.cacheKey`. At most `capacity` songs, the ones changed
/// longest ago dropped first.
public final class LyricsSongStore: Sendable {
    public static let capacity = 2_000
    public static let fileName = "LyricsSongs.json"
    /// Offsets beyond this are typing errors, not timing.
    public static let offsetRange: ClosedRange<Double> = -10...10

    /// `nil` keeps everything in memory (demo, smoke, tests).
    public let fileURL: URL?
    /// Songs kept; the ones changed longest ago go first.
    public let capacity: Int
    private let state: OSAllocatedUnfairLock<[String: LyricsSongEntry]>
    private let writer = DispatchQueue(label: "com.sinanmertsener.Ahenk.lyrics-songs", qos: .utility)
    private static let log = AhenkLogger(category: "lyrics")

    private struct Document: Codable {
        var version: Int
        var songs: [String: LyricsSongEntry]
    }

    /// `~/Library/Application Support/Ahenk/LyricsSongs.json`.
    public static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public init(fileURL: URL?, capacity: Int = LyricsSongStore.capacity) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        state = OSAllocatedUnfairLock(initialState: fileURL.map(Self.load) ?? [:])
    }

    public func entry(for key: String) -> LyricsSongEntry? {
        state.withLock { $0[key] }
    }

    public var count: Int { state.withLock { $0.count } }

    /// The user's offset for the song; `nil` or 0 removes it.
    public func setManualOffset(_ value: Double?, for key: String, at date: Date = Date()) {
        let clean = value.flatMap { $0.isFinite && $0 != 0 ? $0.clamped(to: Self.offsetRange) : nil }
        update(key, at: date) { $0.manualOffset = clean }
    }

    /// The measured offset for the timeline with `fingerprint`; `nil`
    /// forgets it.
    public func setAutoOffset(_ value: Double?, fingerprint: String?, for key: String, at date: Date = Date()) {
        let clean = value.flatMap { $0.isFinite ? $0.clamped(to: Self.offsetRange) : nil }
        update(key, at: date) { entry in
            entry.autoOffset = clean
            entry.autoFingerprint = clean == nil ? nil : fingerprint
        }
    }

    /// The measured offset, only if it was measured for this timeline.
    public func autoOffset(for key: String, fingerprint: String) -> Double? {
        state.withLock { songs in
            guard let entry = songs[key], entry.autoFingerprint == fingerprint else { return nil }
            return entry.autoOffset
        }
    }

    /// The picked version (stored without lyrics); `nil` goes back to the
    /// automatic choice.
    public func setChoice(_ version: LyricsVersion?, for key: String, at date: Date = Date()) {
        update(key, at: date) { $0.choice = version?.withoutLyrics }
    }

    /// Waits for pending writes.
    public func flush() {
        writer.sync {}
    }

    private func update(_ key: String, at date: Date, _ change: @Sendable (inout LyricsSongEntry) -> Void) {
        guard !key.isEmpty else { return }
        let capacity = self.capacity
        let snapshot = state.withLock { songs -> [String: LyricsSongEntry] in
            var entry = songs[key] ?? LyricsSongEntry(updatedAt: date)
            change(&entry)
            entry.updatedAt = date
            songs[key] = entry.isEmpty ? nil : entry
            if songs.count > capacity {
                let oldest = songs.sorted { ($0.value.updatedAt, $0.key) < ($1.value.updatedAt, $1.key) }
                    .prefix(songs.count - capacity).map(\.key)
                oldest.forEach { songs[$0] = nil }
            }
            return songs
        }
        save(snapshot)
    }

    private func save(_ songs: [String: LyricsSongEntry]) {
        guard let fileURL else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(Document(version: 1, songs: songs)).write(to: fileURL, options: .atomic)
            } catch {
                Self.log.error("Could not save the lyrics offsets: \(error.localizedDescription)")
            }
        }
    }

    /// Reads leniently: an unreadable entry is dropped, an unreadable file
    /// starts empty.
    private static func load(_ url: URL) -> [String: LyricsSongEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        struct LenientDocument: Decodable {
            var songs: [String: LyricsSongEntry] = [:]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let nested = try container.nestedContainer(keyedBy: AnyKey.self, forKey: .songs)
                for key in nested.allKeys {
                    if let entry = try? nested.decode(LyricsSongEntry.self, forKey: key) { songs[key.stringValue] = entry }
                }
            }
            enum CodingKeys: String, CodingKey { case songs }
            struct AnyKey: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(LenientDocument.self, from: data) else {
            log.error("The lyrics offsets file is unreadable; starting empty")
            return [:]
        }
        return document.songs
    }
}
