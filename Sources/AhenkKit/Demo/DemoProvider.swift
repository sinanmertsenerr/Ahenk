import Foundation
import os

/// Feeds the invented demo songs through the same protocols the real sources
/// use: now playing, artwork, lyrics and audio features (`--demo`, `--smoke`).
///
/// The playlist loops forever. Playback is a pure function of an anchor
/// (song, position, date) and the injected clock, so tests can drive time
/// by hand; commands only move the anchor.
public final class DemoProvider: NowPlayingProvider, ArtworkProvider, LyricsProvider, AudioFeatureSource, Sendable {
    public let id = "demo"
    public let name = "demo"
    public let songs: [DemoSong]

    private let clock: @Sendable () -> Date
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
        /// Song indices in play order (sequential or shuffled).
        var order: [Int]
        /// Index into `order` of the song at the anchor.
        var anchorSlot = 0
        var anchorPosition: TimeInterval = 0
        var anchorDate: Date
        var isPlaying: Bool
        var isShuffled = false
        var repeatMode: RepeatMode = .all
        var liked: Set<String> = []
        /// The song most recently sent to the streams.
        var announcedTrackID: String?
        var announcedPlaying: Bool?
        var continuations: [UUID: AsyncStream<NowPlayingSnapshot?>.Continuation] = [:]
        var boundaryTask: Task<Void, Never>?
        var artworkCache: [String: Artwork] = [:]
    }

    public init(
        songs: [DemoSong] = DemoCatalog.songs,
        startPlaying: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(!songs.isEmpty, "The demo needs at least one song")
        self.songs = songs
        self.clock = clock
        self.state = OSAllocatedUnfairLock(initialState: State(
            order: Array(songs.indices),
            anchorDate: clock(),
            isPlaying: startPlaying
        ))
    }

    deinit {
        state.withLock { $0.boundaryTask?.cancel() }
    }

    // MARK: Timeline

    /// The song and position at `date` (defaults to now).
    public func snapshot(at date: Date? = nil) -> NowPlayingSnapshot {
        let now = date ?? clock()
        return state.withLock { makeSnapshot($0, now: now) }
    }

    public func song(for track: Track) -> DemoSong? {
        songs.first { $0.track.id == track.id }
    }

    private struct Resolved {
        var slot: Int
        var position: TimeInterval
    }

    private func duration(_ state: State, slot: Int) -> TimeInterval {
        max(1, songs[state.order[slot]].track.duration)
    }

    private func resolve(_ state: State, now: Date) -> Resolved {
        let count = state.order.count
        var slot = state.anchorSlot
        guard state.isPlaying else {
            return Resolved(slot: slot, position: min(state.anchorPosition, duration(state, slot: slot)))
        }
        var position = state.anchorPosition + max(0, now.timeIntervalSince(state.anchorDate))
        if state.repeatMode == .one {
            return Resolved(slot: slot, position: position.truncatingRemainder(dividingBy: duration(state, slot: slot)))
        }
        if position < duration(state, slot: slot) {
            return Resolved(slot: slot, position: position)
        }
        // Finish the anchor song, skip whole loops of the playlist, then walk.
        position -= duration(state, slot: slot)
        slot = (slot + 1) % count
        let total = state.order.indices.reduce(0) { $0 + duration(state, slot: $1) }
        position = position.truncatingRemainder(dividingBy: total)
        while position >= duration(state, slot: slot) {
            position -= duration(state, slot: slot)
            slot = (slot + 1) % count
        }
        return Resolved(slot: slot, position: position)
    }

    private func makeSnapshot(_ state: State, now: Date) -> NowPlayingSnapshot {
        let resolved = resolve(state, now: now)
        let track = songs[state.order[resolved.slot]].track
        return NowPlayingSnapshot(
            track: track,
            elapsedTime: resolved.position,
            playbackRate: state.isPlaying ? 1 : 0,
            timestamp: now,
            isShuffled: state.isShuffled,
            repeatMode: state.repeatMode,
            isLiked: state.liked.contains(track.id)
        )
    }

    // MARK: NowPlayingProvider

    public func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream<NowPlayingSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let first = state.withLock { state -> NowPlayingSnapshot in
            state.continuations[streamID] = continuation
            let snapshot = makeSnapshot(state, now: clock())
            state.announcedTrackID = snapshot.track.id
            state.announcedPlaying = snapshot.isPlaying
            return snapshot
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                state.continuations[streamID] = nil
                if state.continuations.isEmpty {
                    state.boundaryTask?.cancel()
                    state.boundaryTask = nil
                }
            }
        }
        continuation.yield(first)
        scheduleBoundary()
        return stream
    }

    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> Bool {
        let now = clock()
        state.withLock { state in
            // Re-anchor at the current point, then apply the command there.
            let resolved = resolve(state, now: now)
            state.anchorSlot = resolved.slot
            state.anchorPosition = resolved.position
            state.anchorDate = now
            let count = state.order.count
            switch command {
            case .play:
                state.isPlaying = true
            case .pause:
                state.isPlaying = false
            case .togglePlayPause:
                state.isPlaying.toggle()
            case .next:
                state.anchorSlot = (state.anchorSlot + 1) % count
                state.anchorPosition = 0
            case .previous:
                if resolved.position <= 3 {
                    state.anchorSlot = (state.anchorSlot + count - 1) % count
                }
                state.anchorPosition = 0
            case .seek(let target):
                let limit = duration(state, slot: state.anchorSlot) - 0.05
                state.anchorPosition = target.isFinite ? min(max(0, target), limit) : 0
            case .setShuffle(let on):
                Self.applyShuffle(on, to: &state)
            case .setRepeat(let mode):
                state.repeatMode = mode
            case .setLiked(let liked):
                let trackID = songs[state.order[state.anchorSlot]].track.id
                if liked { state.liked.insert(trackID) } else { state.liked.remove(trackID) }
            }
        }
        broadcast(force: true)
        scheduleBoundary()
        return true
    }

    private static func applyShuffle(_ on: Bool, to state: inout State) {
        let current = state.order[state.anchorSlot]
        if on {
            var others = state.order.indices.map { $0 }.filter { $0 != current }
            var random = SplitMix64(seed: 0xA4E2_5EED)
            others.shuffle(using: &random)
            state.order = [current] + others
            state.anchorSlot = 0
        } else {
            state.order = Array(state.order.indices)
            state.anchorSlot = current
        }
        state.isShuffled = on
    }

    /// Sends the current snapshot to every stream; unless `force`, only when
    /// the song or the play state differs from what was last sent.
    private func broadcast(force: Bool) {
        let (snapshot, targets) = state.withLock { state -> (NowPlayingSnapshot?, [AsyncStream<NowPlayingSnapshot?>.Continuation]) in
            let snapshot = makeSnapshot(state, now: clock())
            let changed = snapshot.track.id != state.announcedTrackID || snapshot.isPlaying != state.announcedPlaying
            guard force || changed else { return (nil, []) }
            state.announcedTrackID = snapshot.track.id
            state.announcedPlaying = snapshot.isPlaying
            return (snapshot, Array(state.continuations.values))
        }
        guard let snapshot else { return }
        for continuation in targets {
            continuation.yield(snapshot)
        }
    }

    /// Wakes up when the current song ends so the streams learn about the
    /// next one. Nothing is scheduled while paused or while nobody listens.
    private func scheduleBoundary() {
        let now = clock()
        state.withLock { state in
            state.boundaryTask?.cancel()
            state.boundaryTask = nil
            guard state.isPlaying, !state.continuations.isEmpty else { return }
            let resolved = resolve(state, now: now)
            let remaining = max(0.05, duration(state, slot: resolved.slot) - resolved.position) + 0.02
            state.boundaryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self else { return }
                // A repeated song restarts its position, so it is a change too.
                self.broadcast(force: self.state.withLock { $0.repeatMode == .one })
                self.scheduleBoundary()
            }
        }
    }

    // MARK: ArtworkProvider

    public func artwork(for track: Track, pixelSize: Int) async -> Artwork? {
        guard let song = song(for: track) else { return nil }
        let key = "\(song.track.id)@\(pixelSize)"
        if let cached = state.withLock({ $0.artworkCache[key] }) { return cached }
        guard let image = DemoArtwork.makeImage(palette: song.palette, seed: song.artworkSeed, pixelSize: pixelSize) else {
            return nil
        }
        let artwork = Artwork(image: image, palette: song.palette, identifier: key)
        state.withLock { $0.artworkCache[key] = artwork }
        return artwork
    }

    // MARK: LyricsProvider

    public func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        // Locale-neutral folding: with a Turkish locale, "I" folds to "ı" and
        // "DRIVE" would stop matching "Drive".
        func same(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: nil) == .orderedSame
        }
        let match = songs.first { same($0.track.title, query.title) && same($0.track.artist, query.artist) }
        guard let match else { return .notFound }
        return .synced(match.lyrics)
    }

    // MARK: AudioFeatureSource

    public func currentFeatures() -> AudioFeatures {
        let now = clock()
        return state.withLock { state in
            guard state.isPlaying else { return .silence }
            return DemoBeat.features(at: resolve(state, now: now).position)
        }
    }
}
