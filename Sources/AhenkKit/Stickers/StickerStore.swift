import Foundation
import os

/// The user's stickers: the list in `Stickers.json` and one PNG per
/// cut-out, in `~/Library/Application Support/Ahenk/Stickers`. Nothing is
/// uploaded anywhere. The list's order is the stacking order (the last one
/// is in front).
///
/// `directory: nil` keeps everything in memory (the demo, smoke runs).
public final class StickerStore: Sendable {
    public static let listFileName = "Stickers.json"
    /// More than this many and the oldest are not added (each is a window).
    public static let capacity = 60

    public let directory: URL?
    private let state: OSAllocatedUnfairLock<State>
    private let writer = DispatchQueue(label: "com.sinanmertsener.Ahenk.stickers", qos: .utility)
    private static let log = AhenkLogger(category: "stickers")

    private struct State: Sendable {
        var stickers: [Sticker] = []
        /// The pictures, when nothing is kept on disk.
        var images: [UUID: Data] = [:]
        var continuations: [UUID: AsyncStream<[Sticker]>.Continuation] = [:]
    }

    private struct Document: Codable {
        var version: Int
        var stickers: [Sticker]
    }

    public enum StoreError: Error, Equatable {
        case full
        case unwritable(String)
    }

    /// `~/Library/Application Support/Ahenk/Stickers`.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk/Stickers", isDirectory: true)
    }

    public init(directory: URL?) {
        self.directory = directory
        state = OSAllocatedUnfairLock(initialState: State(stickers: directory.map(Self.load) ?? []))
    }

    public var stickers: [Sticker] { state.withLock { $0.stickers } }

    public func sticker(id: UUID) -> Sticker? {
        state.withLock { $0.stickers.first { $0.id == id } }
    }

    /// The list now and after every change.
    public func changes() -> AsyncStream<[Sticker]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[Sticker]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let current = state.withLock { state -> [Sticker] in
            state.continuations[key] = continuation
            return state.stickers
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    /// Adds a sticker in front of the others and stores its picture.
    @discardableResult
    public func add(_ sticker: Sticker, png: Data) throws -> Sticker {
        guard stickers.count < Self.capacity else { throw StoreError.full }
        if let directory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent(sticker.imageFileName), options: .atomic)
            } catch {
                throw StoreError.unwritable(error.localizedDescription)
            }
        }
        mutate { state in
            state.stickers.removeAll { $0.id == sticker.id }
            state.stickers.append(sticker)
            if self.directory == nil { state.images[sticker.id] = png }
        }
        return sticker
    }

    /// Changes one sticker (its place, size or turn).
    public func update(id: UUID, _ change: (inout Sticker) -> Void) {
        let sticker = state.withLock { $0.stickers.first { $0.id == id } }
        guard var sticker else { return }
        let before = sticker
        change(&sticker)
        guard sticker != before else { return }
        let updated = sticker
        mutate { state in
            if let index = state.stickers.firstIndex(where: { $0.id == id }) { state.stickers[index] = updated }
        }
    }

    /// Puts a sticker in front of the others.
    public func bringToFront(id: UUID) {
        mutate { state in
            guard let index = state.stickers.firstIndex(where: { $0.id == id }), index != state.stickers.count - 1 else { return }
            state.stickers.append(state.stickers.remove(at: index))
        }
    }

    /// Deletes a sticker and its picture.
    public func remove(id: UUID) {
        let existed = state.withLock { $0.stickers.contains { $0.id == id } }
        guard existed else { return }
        mutate { state in
            state.stickers.removeAll { $0.id == id }
            state.images[id] = nil
        }
        if let directory {
            let url = directory.appendingPathComponent("\(id.uuidString).png")
            writer.async { try? FileManager.default.removeItem(at: url) }
        }
    }

    public func removeAll() {
        for sticker in stickers { remove(id: sticker.id) }
    }

    /// The sticker's picture (PNG).
    public func imageData(for id: UUID) -> Data? {
        if let directory {
            return try? Data(contentsOf: directory.appendingPathComponent("\(id.uuidString).png"))
        }
        return state.withLock { $0.images[id] }
    }

    /// Waits for pending writes.
    public func flush() {
        writer.sync {}
    }

    // MARK: Persistence

    private func mutate(_ change: @Sendable (inout State) -> Void) {
        let (list, continuations) = state.withLock { state -> ([Sticker], [AsyncStream<[Sticker]>.Continuation]) in
            change(&state)
            return (state.stickers, Array(state.continuations.values))
        }
        save(list)
        continuations.forEach { $0.yield(list) }
    }

    private func save(_ stickers: [Sticker]) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(Self.listFileName)
        writer.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(Document(version: 1, stickers: stickers)).write(to: url, options: .atomic)
            } catch {
                Self.log.error("Could not save the stickers: \(error.localizedDescription)")
            }
        }
    }

    /// Reads the list leniently: a sticker that cannot be read, or whose
    /// picture is gone, is dropped; the others stay.
    private static func load(_ directory: URL) -> [Sticker] {
        let url = directory.appendingPathComponent(listFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        struct LenientDocument: Decodable {
            var stickers: [Sticker]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                var list = try container.nestedUnkeyedContainer(forKey: .stickers)
                var stickers: [Sticker] = []
                while !list.isAtEnd {
                    if let sticker = try? list.decode(Sticker.self) {
                        stickers.append(sticker)
                    } else {
                        _ = try? list.decode(Skip.self)
                    }
                }
                self.stickers = stickers
            }
            enum CodingKeys: String, CodingKey { case stickers }
            struct Skip: Decodable {
                init(from decoder: Decoder) throws {}
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(LenientDocument.self, from: data) else {
            log.error("The sticker list is unreadable; starting with none")
            return []
        }
        var seen: Set<UUID> = []
        return document.stickers.filter { sticker in
            seen.insert(sticker.id).inserted
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent(sticker.imageFileName).path)
        }
    }
}
