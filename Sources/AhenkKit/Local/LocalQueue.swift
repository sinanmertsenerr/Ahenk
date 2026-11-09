import Foundation

/// The local player's queue: Ahenk's ``PlayQueue`` (Play Next, Add to
/// Queue, shuffle that can be undone) with the rules of a player that has
/// every song itself.
///
/// - A song that ends by itself: repeat one plays it again, repeat all
///   goes round, otherwise the next one; after the last the queue goes back
///   to its first song and stops.
/// - Next always moves on (also with repeat one); at the end it goes round
///   unless repeat is off.
/// - Previous restarts the song after 3 s, else goes to the one before
///   (round to the last with repeat all; the first song restarts).
/// - Shuffle stays on for a new list.
/// - A file that cannot be played leaves the queue.
public struct LocalQueue: Hashable, Sendable {
    /// Previous restarts the song once it has played this long.
    public static let restartThreshold: TimeInterval = 3

    public private(set) var queue = PlayQueue()

    public init() {}

    public var current: QueueEntry? { queue.current }
    public var upNext: [QueueEntry] { queue.upNext }
    public var entries: [QueueEntry] { queue.entries }
    public var isEmpty: Bool { queue.isEmpty }
    public var context: QueueContext? { queue.context }
    public var repeatMode: RepeatMode { queue.repeatMode }
    public var isShuffled: Bool { queue.isShuffled }

    /// What plays after the current song when it ends by itself (the item
    /// the player loads in advance, for a gapless change).
    public var following: QueueEntry? { queue.following }

    /// What Previous does at `position` seconds into the song.
    public enum BackStep: Equatable, Sendable {
        case restart
        case moved(QueueEntry)
    }

    // MARK: Starting and editing

    /// Plays `songs` from `index`; shuffle stays as it was.
    public mutating func start(_ songs: [CatalogSong], at index: Int, context: QueueContext?, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        let shuffled = queue.isShuffled
        queue.start(songs, at: index, context: context)
        if shuffled { queue.setShuffled(true, seed: seed) }
    }

    public mutating func playNext(_ songs: [CatalogSong]) {
        queue.playNext(songs)
    }

    public mutating func append(_ songs: [CatalogSong]) {
        queue.append(songs)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        queue.remove(id)
    }

    @discardableResult
    public mutating func moveToFront(_ id: UUID) -> Bool {
        queue.move(id, toUpNextPosition: 0)
    }

    public mutating func clearUpNext() {
        queue.clearUpNext()
    }

    public mutating func clear() {
        let mode = queue.repeatMode
        queue.clear()
        queue.repeatMode = mode
    }

    @discardableResult
    public mutating func jump(to id: UUID) -> QueueEntry? {
        queue.jump(to: id)
    }

    public mutating func setShuffled(_ on: Bool, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        queue.setShuffled(on, seed: seed)
    }

    public mutating func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
    }

    // MARK: Moving

    /// The song ended by itself. Returns what plays now; `nil` when the
    /// queue is over (it is then back at its first song, stopped).
    public mutating func songEnded() -> QueueEntry? {
        if let next = queue.advance() { return next }
        rewind()
        return nil
    }

    /// The player moved on by itself to the song it had loaded in advance.
    @discardableResult
    public mutating func advanced(to id: UUID) -> Bool {
        guard queue.following?.id == id else { return false }
        return queue.advance()?.id == id
    }

    /// Next. `nil` at the end with repeat off (the queue is then back at
    /// its first song, stopped).
    public mutating func skipForward() -> QueueEntry? {
        let mode = queue.repeatMode
        if mode == .one { queue.repeatMode = .all }
        defer { queue.repeatMode = mode }
        if let next = queue.advance() { return next }
        rewind()
        return nil
    }

    /// Previous, `position` seconds into the current song.
    public mutating func skipBack(position: TimeInterval) -> BackStep {
        if position > Self.restartThreshold { return .restart }
        if let previous = queue.retreat() { return .moved(previous) }
        return .restart
    }

    /// The current file cannot be played (or `id` up next): it leaves the
    /// queue. Returns what plays now; `nil` when nothing is left.
    @discardableResult
    public mutating func dropUnplayable(_ id: UUID) -> QueueEntry? {
        guard current?.id == id else {
            queue.remove(id)
            return current
        }
        return queue.removeCurrent(wrapping: queue.repeatMode == .all)
    }

    /// Back to the first song (the queue ended).
    public mutating func rewind() {
        if let first = queue.entries.first { queue.jump(to: first.id) }
    }
}
