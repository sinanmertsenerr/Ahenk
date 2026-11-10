import Foundation
import os

/// One song in Continue Playing.
public struct RecentlyPlayedItem: Codable, Hashable, Sendable, Identifiable {
    public var track: Track
    /// The app it played in (a browser for web sources).
    public var bundleIdentifier: String?
    public var playedAt: Date

    public init(track: Track, bundleIdentifier: String?, playedAt: Date) {
        self.track = track
        self.bundleIdentifier = bundleIdentifier
        self.playedAt = playedAt
    }

    public var id: String { "\(track.source.rawValue):\(track.id)" }

    /// Where the pipeline keeps this song's cover on disk.
    public var artworkKey: String { ArtworkPipeline.coverKey(for: track) }
}

/// The songs played most recently, newest first, without duplicates, kept
/// in `~/Library/Application Support/Ahenk/RecentlyPlayed.json`.
///
/// A song that plays again moves to the top. The same song from two
/// providers (a persistent ID and a metadata key) counts once. Only music
/// (and players that do not say what they play) is recorded: no plain
/// videos, podcasts or adverts, and nothing without a title.
public final class RecentlyPlayedStore: Sendable {
    public static let capacity = 50
    public static let fileName = "RecentlyPlayed.json"

    /// `nil` keeps the list in memory only (demo, smoke).
    public let fileURL: URL?
    private let state: OSAllocatedUnfairLock<State>
    private let writer = DispatchQueue(label: "com.sinanmertsener.Ahenk.recently-played", qos: .utility)
    private static let log = AhenkLogger(category: "recently-played")

    private struct State: Sendable {
        var items: [RecentlyPlayedItem] = []
        var continuations: [UUID: AsyncStream<[RecentlyPlayedItem]>.Continuation] = [:]
    }

    private struct Document: Codable {
        var version: Int
        var items: [RecentlyPlayedItem]
    }

    /// `~/Library/Application Support/Ahenk/RecentlyPlayed.json`.
    public static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        state = OSAllocatedUnfairLock(initialState: State(items: fileURL.map(Self.load) ?? []))
    }

    public var items: [RecentlyPlayedItem] { state.withLock { $0.items } }

    /// The list now and after every change.
    public func changes() -> AsyncStream<[RecentlyPlayedItem]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[RecentlyPlayedItem]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let current = state.withLock { state -> [RecentlyPlayedItem] in
            state.continuations[key] = continuation
            return state.items
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    /// Notes that `snapshot` is playing. Cheap to call on every update:
    /// nothing changes while the same song stays on top.
    public func notePlaying(_ snapshot: NowPlayingSnapshot, at date: Date = Date()) {
        guard snapshot.isPlaying, snapshot.contentKind == .music || snapshot.contentKind == .unknown else { return }
        record(snapshot.track, bundleIdentifier: snapshot.bundleIdentifier, at: date)
    }

    public func record(_ track: Track, bundleIdentifier: String?, at date: Date) {
        guard !track.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let update = state.withLock { state -> ([RecentlyPlayedItem], [AsyncStream<[RecentlyPlayedItem]>.Continuation])? in
            if let top = state.items.first, top.track.source != .otherApp, track.source == .otherApp, TrackMatching.sameSong(top.track, track) {
                // Already on top from the music app: a browser tab playing
                // the same song changes nothing.
                return nil
            }
            if let top = state.items.first, top.track.isSameSong(as: track) {
                // Fill in details that arrived later (album, duration, cover URL).
                guard top.track != track, Self.isRicher(track, than: top.track) else { return nil }
                state.items[0].track = track
                return (state.items, Array(state.continuations.values))
            }
            // The same song heard elsewhere (Spotify, then a browser tab)
            // is one row: the music app's entry is kept, because it can be
            // played again from the list.
            var entry = RecentlyPlayedItem(track: track, bundleIdentifier: bundleIdentifier, playedAt: date)
            if track.source == .otherApp,
               let known = state.items.first(where: { $0.track.source != .otherApp && TrackMatching.sameSong($0.track, track) }) {
                entry = RecentlyPlayedItem(track: known.track, bundleIdentifier: known.bundleIdentifier, playedAt: date)
            }
            state.items.removeAll { item in
                item.track.isSameSong(as: track)
                    || ((item.track.source == .otherApp || track.source == .otherApp) && TrackMatching.sameSong(item.track, track))
            }
            state.items.insert(entry, at: 0)
            if state.items.count > Self.capacity { state.items.removeLast(state.items.count - Self.capacity) }
            return (state.items, Array(state.continuations.values))
        }
        guard let (items, continuations) = update else { return }
        save(items)
        continuations.forEach { $0.yield(items) }
    }

    public func remove(id: String) {
        let update = state.withLock { state -> ([RecentlyPlayedItem], [AsyncStream<[RecentlyPlayedItem]>.Continuation])? in
            let before = state.items.count
            state.items.removeAll { $0.id == id }
            return state.items.count == before ? nil : (state.items, Array(state.continuations.values))
        }
        guard let (items, continuations) = update else { return }
        save(items)
        continuations.forEach { $0.yield(items) }
    }

    public func removeAll() {
        let continuations = state.withLock { state -> [AsyncStream<[RecentlyPlayedItem]>.Continuation] in
            state.items = []
            return Array(state.continuations.values)
        }
        save([])
        continuations.forEach { $0.yield([]) }
    }

    /// Waits for pending writes.
    public func flush() {
        writer.sync {}
    }

    private static func isRicher(_ new: Track, than old: Track) -> Bool {
        (old.album.isEmpty && !new.album.isEmpty)
            || (old.duration == 0 && new.duration > 0)
            || (old.artworkURL == nil && new.artworkURL != nil)
    }

    // MARK: Persistence

    private func save(_ items: [RecentlyPlayedItem]) {
        guard let fileURL else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(Document(version: 1, items: items)).write(to: fileURL, options: .atomic)
            } catch {
                Self.log.error("Could not save Continue Playing: \(error.localizedDescription)")
            }
        }
    }

    /// Reads the file leniently: unreadable items are dropped, an unreadable
    /// file starts an empty list.
    private static func load(_ url: URL) -> [RecentlyPlayedItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        struct LenientDocument: Decodable {
            var items: [RecentlyPlayedItem]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                var list = try container.nestedUnkeyedContainer(forKey: .items)
                var items: [RecentlyPlayedItem] = []
                while !list.isAtEnd {
                    if let item = try? list.decode(RecentlyPlayedItem.self) {
                        items.append(item)
                    } else {
                        _ = try? list.decode(Skip.self)
                    }
                }
                self.items = items
            }
            enum CodingKeys: String, CodingKey { case items }
            struct Skip: Decodable {
                init(from decoder: Decoder) throws {}
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(LenientDocument.self, from: data) else {
            log.error("Continue Playing file is unreadable; starting a new list")
            return []
        }
        return Array(document.items.prefix(capacity))
    }
}
