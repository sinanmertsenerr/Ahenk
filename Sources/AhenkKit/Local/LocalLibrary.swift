import Foundation
import os

/// A folder of songs the user gave Ahenk (dropped on Continue Playing or
/// picked with "Add Folder…").
public struct LocalFolder: Hashable, Sendable, Codable, Identifiable {
    public var path: String
    public var name: String
    public var addedAt: Date
    /// Finds the folder again after it was moved or renamed.
    public var bookmark: Data?

    public init(path: String, name: String? = nil, addedAt: Date = Date(), bookmark: Data? = nil) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.addedAt = addedAt
        self.bookmark = bookmark
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// The remembered folders, newest first, in
/// `~/Library/Application Support/Ahenk/LocalLibrary.json`. Only paths
/// (and bookmarks) are kept; the songs are read from the files each time.
///
/// `fileURL: nil` keeps the list in memory (demo, smoke).
public final class LocalLibraryStore: Sendable {
    public static let fileName = "LocalLibrary.json"
    public static let capacity = 40

    public let fileURL: URL?
    private let state: OSAllocatedUnfairLock<State>
    private let writer = DispatchQueue(label: "com.sinanmertsener.Ahenk.local-library", qos: .utility)
    private static let log = AhenkLogger(category: "local")

    private struct State: Sendable {
        var folders: [LocalFolder] = []
        var continuations: [UUID: AsyncStream<[LocalFolder]>.Continuation] = [:]
    }

    private struct Document: Codable {
        var version: Int
        var folders: [LocalFolder]
    }

    public static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ahenk", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        state = OSAllocatedUnfairLock(initialState: State(folders: fileURL.map(Self.load) ?? []))
    }

    public var folders: [LocalFolder] { state.withLock { $0.folders } }

    public func changes() -> AsyncStream<[LocalFolder]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[LocalFolder]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let current = state.withLock { state -> [LocalFolder] in
            state.continuations[key] = continuation
            return state.folders
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        continuation.yield(current)
        return stream
    }

    /// Remembers a folder (again at the top when it was known).
    @discardableResult
    public func add(_ url: URL, at date: Date = Date()) -> LocalFolder {
        let path = url.standardizedFileURL.path
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = LocalFolder(path: path, addedAt: date, bookmark: bookmark)
        mutate { folders in
            folders.removeAll { $0.path == path }
            folders.insert(folder, at: 0)
            if folders.count > Self.capacity { folders.removeLast(folders.count - Self.capacity) }
        }
        return folder
    }

    public func remove(path: String) {
        mutate { folders in folders.removeAll { $0.path == path } }
    }

    /// Where the folder is now: its path, or where its bookmark leads after
    /// a move (the record follows it); `nil` when it is gone.
    public func resolve(_ folder: LocalFolder) -> URL? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return folder.url
        }
        guard let bookmark = folder.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        let moved = url.standardizedFileURL.path
        let refreshed = stale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        mutate { folders in
            guard let index = folders.firstIndex(where: { $0.path == folder.path }) else { return }
            folders[index].path = moved
            folders[index].name = (moved as NSString).lastPathComponent
            if let refreshed { folders[index].bookmark = refreshed }
        }
        return url
    }

    public func flush() {
        writer.sync {}
    }

    private func mutate(_ change: @Sendable (inout [LocalFolder]) -> Void) {
        let (folders, continuations, changed) = state.withLock { state -> ([LocalFolder], [AsyncStream<[LocalFolder]>.Continuation], Bool) in
            let before = state.folders
            change(&state.folders)
            return (state.folders, Array(state.continuations.values), before != state.folders)
        }
        guard changed else { return }
        save(folders)
        continuations.forEach { $0.yield(folders) }
    }

    private func save(_ folders: [LocalFolder]) {
        guard let fileURL else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(Document(version: 1, folders: folders)).write(to: fileURL, options: .atomic)
            } catch {
                Self.log.error("Could not save the music folders: \(error.localizedDescription)")
            }
        }
    }

    private static func load(_ url: URL) -> [LocalFolder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            log.error("The music folder list is unreadable; starting with none")
            return []
        }
        var seen: Set<String> = []
        return document.folders.filter { seen.insert($0.path).inserted }.prefix(capacity).map { $0 }
    }
}
