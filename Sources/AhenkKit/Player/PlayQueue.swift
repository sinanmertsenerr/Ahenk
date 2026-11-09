import Foundation

/// One song in Ahenk's queue. The same song can be queued twice, so
/// entries have their own identity.
public struct QueueEntry: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var song: CatalogSong
    /// Added with Play Next or Add to Queue, not part of the album or list
    /// that was started.
    public var isUserAdded: Bool

    public init(id: UUID = UUID(), song: CatalogSong, isUserAdded: Bool) {
        self.id = id
        self.song = song
        self.isUserAdded = isUserAdded
    }
}

/// What a queue was started from (shown in the queue panel).
public enum QueueContext: Hashable, Sendable, Codable {
    case album(id: String, title: String)
    case playlist(id: String, name: String)
    case artist(id: String, name: String)
    case continuePlaying
    case search
}

/// Ahenk's own play queue: what plays, what played before it and what is
/// up next. The music apps' scripting cannot read or change their own
/// queues, so Ahenk keeps one and starts each song itself when the one
/// before it ends (`QueueConductorPolicy`).
///
/// - Starting an album or a list keeps songs the user queued that have not
///   played yet: they come right after the new song, then the album goes on.
/// - Play Next puts songs right after the current one (the newest first, as
///   in Apple Music); Add to Queue puts them at the end.
/// - Shuffle reorders only what is up next and can be undone.
public struct PlayQueue: Hashable, Sendable, Codable {
    public private(set) var entries: [QueueEntry] = []
    public private(set) var currentIndex: Int?
    public private(set) var context: QueueContext?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false
    /// The up-next order before shuffling, to restore it.
    private var unshuffledOrder: [UUID]?

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public var current: QueueEntry? {
        currentIndex.map { entries[$0] }
    }

    /// Everything after the current entry.
    public var upNext: [QueueEntry] {
        guard let currentIndex else { return entries }
        return Array(entries[(currentIndex + 1)...])
    }

    /// Everything before the current entry.
    public var history: [QueueEntry] {
        guard let currentIndex else { return [] }
        return Array(entries[..<currentIndex])
    }

    public func index(of id: UUID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// The entry that `advance()` would move to.
    public var following: QueueEntry? {
        guard !entries.isEmpty else { return nil }
        if repeatMode == .one, let current { return current }
        guard let currentIndex else { return entries.first }
        if currentIndex + 1 < entries.count { return entries[currentIndex + 1] }
        return repeatMode == .all ? entries.first : nil
    }

    // MARK: Starting

    /// Plays `songs` from `index`. Songs the user queued that have not
    /// played yet follow the new song; the songs before `index` become the
    /// history (Previous goes back through them).
    public mutating func start(_ songs: [CatalogSong], at index: Int, context: QueueContext?) {
        guard !songs.isEmpty else { return }
        let start = min(max(0, index), songs.count - 1)
        let kept = upNext.filter(\.isUserAdded)
        let fresh = songs.map { QueueEntry(song: $0, isUserAdded: false) }
        entries = Array(fresh[..<start]) + [fresh[start]] + kept + Array(fresh[(start + 1)...])
        currentIndex = start
        self.context = context
        isShuffled = false
        unshuffledOrder = nil
    }

    // MARK: Editing

    /// Right after the current entry (or first, when nothing plays).
    public mutating func playNext(_ songs: [CatalogSong]) {
        guard !songs.isEmpty else { return }
        let added = songs.map { QueueEntry(song: $0, isUserAdded: true) }
        let position = currentIndex.map { $0 + 1 } ?? 0
        entries.insert(contentsOf: added, at: position)
        if var order = unshuffledOrder {
            order.insert(contentsOf: added.map(\.id), at: 0)
            unshuffledOrder = order
        }
    }

    /// At the end.
    public mutating func append(_ songs: [CatalogSong]) {
        guard !songs.isEmpty else { return }
        let added = songs.map { QueueEntry(song: $0, isUserAdded: true) }
        entries.append(contentsOf: added)
        unshuffledOrder?.append(contentsOf: added.map(\.id))
    }

    /// Removes an entry that is not playing; `false` for the current one or
    /// an unknown ID.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = index(of: id), index != currentIndex else { return false }
        entries.remove(at: index)
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        unshuffledOrder?.removeAll { $0 == id }
        return true
    }

    /// Moves an up-next entry to another place in the up-next list.
    @discardableResult
    public mutating func move(_ id: UUID, toUpNextPosition position: Int) -> Bool {
        guard let from = index(of: id), from != currentIndex else { return false }
        let base = currentIndex.map { $0 + 1 } ?? 0
        guard from >= base else { return false }
        let entry = entries.remove(at: from)
        let target = min(entries.count, base + max(0, position))
        entries.insert(entry, at: target)
        return true
    }

    /// Forgets what is up next (the current song plays on).
    public mutating func clearUpNext() {
        guard let currentIndex else {
            entries = []
            unshuffledOrder = nil
            return
        }
        entries.removeSubrange((currentIndex + 1)...)
        unshuffledOrder = isShuffled ? [] : nil
    }

    public mutating func clear() {
        self = PlayQueue()
    }

    // MARK: Moving

    /// To the next entry: with repeat all, from the last back to the
    /// first; with repeat one, the same entry again. `nil` at the end.
    @discardableResult
    public mutating func advance() -> QueueEntry? {
        guard !entries.isEmpty else { return nil }
        if repeatMode == .one, let current { return current }
        let next = (currentIndex ?? -1) + 1
        if next < entries.count {
            currentIndex = next
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            return nil
        }
        return current
    }

    /// To the entry before the current one (with repeat all, from the first
    /// to the last). `nil` at the start.
    @discardableResult
    public mutating func retreat() -> QueueEntry? {
        guard !entries.isEmpty, let currentIndex else { return nil }
        if currentIndex > 0 {
            self.currentIndex = currentIndex - 1
        } else if repeatMode == .all {
            self.currentIndex = entries.count - 1
        } else {
            return nil
        }
        return current
    }

    @discardableResult
    public mutating func jump(to id: UUID) -> QueueEntry? {
        guard let index = index(of: id) else { return nil }
        currentIndex = index
        return current
    }

    /// The source moved on by itself: makes the first up-next entry that is
    /// the playing song current. `true` when the current entry is that song.
    @discardableResult
    public mutating func follow(_ track: Track) -> Bool {
        if let current, SongMatching.matches(current.song, track) { return true }
        let start = (currentIndex ?? -1) + 1
        guard start < entries.count,
              let found = entries[start...].firstIndex(where: { SongMatching.matches($0.song, track) })
        else { return false }
        currentIndex = found
        return true
    }

    // MARK: Shuffle

    /// Shuffles (or restores) what is up next; the current song and the
    /// history stay where they are. The same seed gives the same order.
    public mutating func setShuffled(_ on: Bool, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        guard on != isShuffled else { return }
        let base = currentIndex.map { $0 + 1 } ?? 0
        let tail = Array(entries[base...])
        if on {
            unshuffledOrder = tail.map(\.id)
            var random = SplitMix64(seed: seed)
            entries.replaceSubrange(base..., with: tail.shuffled(using: &random))
        } else {
            let order = unshuffledOrder ?? []
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let restored = tail.enumerated().sorted { a, b in
                (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
            }.map(\.element)
            entries.replaceSubrange(base..., with: restored)
            unshuffledOrder = nil
        }
        isShuffled = on
    }
}

/// Is what plays the song Ahenk asked for? Across services the same song
/// is spelled differently ("Song (feat. X)" and "Song", "A & B" and "A"),
/// so this compares core titles and artists, not IDs.
public enum SongMatching {
    public static func matches(_ song: CatalogSong, _ track: Track) -> Bool {
        if let origin = song.origin, origin.source == track.source, origin.id == track.id { return true }
        if song.id == track.id { return true }
        let wanted = TrackMatching.coreTitle(song.title)
        guard !wanted.isEmpty, wanted == TrackMatching.coreTitle(track.title) else { return false }
        let artistA = TrackMatching.normalized(song.artistName)
        let artistB = TrackMatching.normalized(track.artist)
        if !artistA.isEmpty, !artistB.isEmpty, artistA != artistB,
           !contains(words: artistA, in: artistB), !contains(words: artistB, in: artistA) {
            return false
        }
        if song.duration > 0, track.duration > 0, abs(song.duration - track.duration) > 10 { return false }
        return true
    }

    private static func contains(words needle: String, in haystack: String) -> Bool {
        (" " + haystack + " ").contains(" " + needle + " ")
    }
}
