import Foundation
import os

/// What the user chose for the live wallpaper, kept across launches in
/// `~/Library/Application Support/Ahenk/WallpaperSongs.json`:
///
/// - per song, the picker dot they chose (a candidate's ID);
/// - per artist name as players report it, the name they typed when the
///   artist could not be found (used for every song with that artist).
///
/// At most `capacity` entries of each, the ones changed longest ago dropped
/// first.
public final class WallpaperSongStore: Sendable {
    public static let capacity = 1_000
    public static let fileName = "WallpaperSongs.json"

    public struct Entry: Codable, Equatable, Sendable {
        public var value: String
        public var updatedAt: Date
    }

    private struct Document: Codable {
        var version: Int
        var picks: [String: Entry]
        var artists: [String: Entry]
    }

    /// `nil` keeps everything in memory (demo, smoke, tests).
    public let fileURL: URL?
    public let capacity: Int
    private let state: OSAllocatedUnfairLock<(picks: [String: Entry], artists: [String: Entry])>
    private let writer = DispatchQueue(label: "com.sinanmertsener.Ahenk.wallpaper-songs", qos: .utility)
    private static let log = AhenkLogger(category: "wallpaper")

    /// `~/Library/Application Support/Ahenk/WallpaperSongs.json`.
    public static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public init(fileURL: URL?, capacity: Int = WallpaperSongStore.capacity) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        let loaded = fileURL.map(Self.load) ?? ([:], [:])
        state = OSAllocatedUnfairLock(initialState: loaded)
    }

    /// The key of a song: its artist and core title, normalized.
    public static func songKey(title: String, artist: String) -> String {
        TrackMatching.normalized(artist) + "|" + TrackMatching.coreTitle(title)
    }

    public func pick(forSong key: String) -> String? {
        state.withLock { $0.picks[key]?.value }
    }

    /// The dot chosen for the song; `nil` goes back to Ahenk's choice.
    public func setPick(_ candidateID: String?, forSong key: String, at date: Date = Date()) {
        guard !key.isEmpty else { return }
        let capacity = self.capacity
        let snapshot = state.withLock { state -> (picks: [String: Entry], artists: [String: Entry]) in
            state.picks[key] = candidateID.flatMap { $0.isEmpty ? nil : Entry(value: $0, updatedAt: date) }
            state.picks = Self.trimmed(state.picks, to: capacity)
            return state
        }
        save(snapshot)
    }

    /// The name the user typed for an artist as players name it.
    public func artistName(for artist: String) -> String? {
        let key = TrackMatching.normalized(artist)
        return state.withLock { $0.artists[key]?.value }
    }

    /// Remembers what to search for instead of `artist`; `nil` or a blank
    /// name forgets it.
    public func setArtistName(_ name: String?, for artist: String, at date: Date = Date()) {
        let key = TrackMatching.normalized(artist)
        guard !key.isEmpty else { return }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capacity = self.capacity
        let snapshot = state.withLock { state -> (picks: [String: Entry], artists: [String: Entry]) in
            state.artists[key] = clean.flatMap { $0.isEmpty ? nil : Entry(value: $0, updatedAt: date) }
            state.artists = Self.trimmed(state.artists, to: capacity)
            return state
        }
        save(snapshot)
    }

    /// Waits for pending writes.
    public func flush() {
        writer.sync {}
    }

    private static func trimmed(_ entries: [String: Entry], to capacity: Int) -> [String: Entry] {
        guard entries.count > capacity else { return entries }
        let oldest = entries.sorted { ($0.value.updatedAt, $0.key) < ($1.value.updatedAt, $1.key) }
            .prefix(entries.count - capacity).map(\.key)
        var kept = entries
        oldest.forEach { kept[$0] = nil }
        return kept
    }

    private func save(_ snapshot: (picks: [String: Entry], artists: [String: Entry])) {
        guard let fileURL else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(Document(version: 1, picks: snapshot.picks, artists: snapshot.artists)).write(to: fileURL, options: .atomic)
            } catch {
                Self.log.error("Could not save the wallpaper choices: \(error.localizedDescription)")
            }
        }
    }

    /// Reads leniently: an unreadable entry is dropped, an unreadable file
    /// starts empty.
    private static func load(_ url: URL) -> (picks: [String: Entry], artists: [String: Entry]) {
        guard let data = try? Data(contentsOf: url) else { return ([:], [:]) }
        struct LenientDocument: Decodable {
            var picks: [String: Entry] = [:]
            var artists: [String: Entry] = [:]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                picks = Self.entries(container, .picks)
                artists = Self.entries(container, .artists)
            }
            static func entries(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: Entry] {
                guard let nested = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) else { return [:] }
                var result: [String: Entry] = [:]
                for entryKey in nested.allKeys {
                    if let entry = try? nested.decode(Entry.self, forKey: entryKey), !entry.value.isEmpty {
                        result[entryKey.stringValue] = entry
                    }
                }
                return result
            }
            enum CodingKeys: String, CodingKey { case picks, artists }
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
            log.error("The wallpaper choices file is unreadable; starting empty")
            return ([:], [:])
        }
        return (document.picks, document.artists)
    }
}
