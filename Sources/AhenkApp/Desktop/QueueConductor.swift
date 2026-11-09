import AhenkKit
import AppKit
import Observation

/// A short message above the player bar.
struct PlayerStatus: Equatable, Identifiable {
    enum Kind: Equatable {
        case info
        case problem
    }

    let id = UUID()
    var text: String
    var kind: Kind

    static func == (a: PlayerStatus, b: PlayerStatus) -> Bool { a.id == b.id }
}

/// Plays Ahenk's queue in a source that only knows one song at a time: it
/// starts the current entry through the router, shows a loading state until
/// the source plays it, starts the next entry a moment before the current
/// one ends (`QueueConductorPolicy`), follows the source when it moves on by
/// itself and steps back when the user plays something else there.
///
/// Nothing runs between those moments: one timer is set for the end of the
/// song, and changes of what plays arrive from the hub.
@MainActor
@Observable
final class QueueConductor {
    private(set) var queue = PlayQueue()
    /// The song Ahenk asked for and whether it plays yet.
    private(set) var attempt: PlaybackAttempt?
    /// Ahenk starts each song itself (next, previous, shuffle and repeat act
    /// on its queue).
    private(set) var isActive = false
    /// The loading state is on screen (shown only after a short delay, then
    /// for a moment at least, so it never flickers).
    private(set) var isStarting = false
    /// The source the queue plays in.
    private(set) var source: MusicSource = .appleMusic

    @ObservationIgnored var onStatus: ((PlayerStatus) -> Void)?
    @ObservationIgnored private let router: PlaybackRouter
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private let services: NowPlayingServices
    @ObservationIgnored private var observer: ChangeObserver<NowPlayingSnapshot?>?
    @ObservationIgnored private var lastOwn: NowPlayingSnapshot?
    @ObservationIgnored private var wake: DispatchWorkItem?
    @ObservationIgnored private var loadingStart: DispatchWorkItem?
    @ObservationIgnored private var loadingShownAt: Date?
    /// The source shows the song and waits for the user to press Play.
    @ObservationIgnored private var waitsForUser = false
    @ObservationIgnored private var requestCount = 0
    /// Songs skipped in a row because only the user could start them.
    @ObservationIgnored private var skipped = 0
    private let log = AhenkLogger(category: "player")

    /// The queue gives up after skipping this many songs in a row.
    static let maximumSkips = 8

    /// Shown no sooner than this after a request…
    static let loadingDelay: TimeInterval = 0.15
    /// …and then for at least this long.
    static let loadingMinimum: TimeInterval = 0.45

    init(router: PlaybackRouter, nowPlaying: NowPlayingModel, services: NowPlayingServices) {
        self.router = router
        self.nowPlaying = nowPlaying
        self.services = services
    }

    func start() {
        guard observer == nil else { return }
        let nowPlaying = self.nowPlaying
        observer = ChangeObserver({ nowPlaying.snapshot }) { [weak self] _ in
            self?.evaluate()
        }
    }

    func stop() {
        observer = nil
        wake?.cancel()
        loadingStart?.cancel()
    }

    /// The song the bar shows while it starts.
    var startingSong: CatalogSong? {
        isStarting ? attempt?.song : nil
    }

    // MARK: Queue editing

    func play(_ songs: [CatalogSong], at index: Int, context: QueueContext?, in source: MusicSource) {
        guard !songs.isEmpty else { return }
        queue.start(songs, at: index, context: context)
        self.source = source
        playCurrent(userAsked: true)
    }

    func playNext(_ songs: [CatalogSong]) {
        queue.playNext(songs)
    }

    func addToQueue(_ songs: [CatalogSong]) {
        queue.append(songs)
    }

    func remove(_ id: UUID) {
        queue.remove(id)
    }

    func moveToFront(_ id: UUID) {
        queue.move(id, toUpNextPosition: 0)
    }

    func clearUpNext() {
        queue.clearUpNext()
    }

    /// Plays an entry of the queue now.
    func jump(to id: UUID, in source: MusicSource) {
        guard queue.jump(to: id) != nil else { return }
        self.source = source
        playCurrent(userAsked: true)
    }

    // MARK: Transport while Ahenk drives

    func next() {
        guard queue.advance() != nil else {
            isActive = false
            return
        }
        playCurrent(userAsked: true)
    }

    /// Back to the start of the song after 3 s, else to the song before.
    func previous() {
        if let snapshot = nowPlaying.snapshot, snapshot.elapsed(at: Date()) > 3 {
            services.perform(.seek(to: 0))
            return
        }
        if queue.retreat() != nil {
            playCurrent(userAsked: true)
        } else {
            services.perform(.seek(to: 0))
        }
    }

    func setShuffled(_ on: Bool) {
        queue.setShuffled(on)
    }

    func cycleRepeat() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
    }

    // MARK: Driving

    private func playCurrent(userAsked: Bool) {
        guard let entry = queue.current else { return }
        if userAsked { skipped = 0 }
        requestCount += 1
        let request = requestCount
        attempt = PlaybackAttempt(entryID: entry.id, song: entry.song, source: source, requestedAt: Date())
        isActive = true
        waitsForUser = false
        lastOwn = nil
        beginLoading()
        scheduleWake()
        let router = self.router
        let source = self.source
        let context = queue.context
        Task { [weak self] in
            // The demo takes a moment to "start" a song, as real sources do.
            let outcome = await router.play(
                entry.song, in: source, context: context, startDelay: userAsked ? 0.9 : 0.3, interactive: userAsked
            )
            guard let self, self.requestCount == request else { return }
            self.handle(outcome)
        }
    }

    private func handle(_ outcome: PlaybackRouter.Outcome) {
        switch outcome {
        case .started:
            evaluate()
        case .shown(let message):
            // The user starts it in the source's app; give them time.
            waitsForUser = true
            attempt?.startTimeout = QueueConductorPolicy.userStartTimeout
            endLoading()
            scheduleWake()
            onStatus?(PlayerStatus(text: message, kind: .info))
        case .needsUser:
            skipped += 1
            if skipped <= Self.maximumSkips, queue.advance() != nil {
                log.info("Skipping a queued song only the user can start")
                playCurrent(userAsked: false)
            } else {
                onStatus?(PlayerStatus(text: "The queue stopped: the next song cannot be started from Ahenk.".l10n, kind: .problem))
                standDown()
            }
        case .unavailable(let message), .failed(let message):
            onStatus?(PlayerStatus(text: message, kind: .problem))
            standDown()
        }
    }

    /// Looks at what plays now (a hub change or the timer) and acts.
    private func evaluate() {
        let now = Date()
        let snapshot = nowPlaying.snapshot
        if let attempt, attempt.isConfirmed, let snapshot, SongMatching.matches(attempt.song, snapshot.track) {
            lastOwn = snapshot
        }
        switch QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: snapshot, lastOwn: lastOwn, now: now) {
        case .none:
            break
        case .confirmed:
            attempt?.confirmedAt = now
            lastOwn = snapshot
            waitsForUser = false
            skipped = 0
            endLoading()
        case .followed(let id):
            queue.jump(to: id)
            if let entry = queue.current {
                attempt = PlaybackAttempt(entryID: entry.id, song: entry.song, source: source, requestedAt: now, confirmedAt: now)
            }
            lastOwn = snapshot
        case .advance:
            if queue.advance() != nil {
                playCurrent(userAsked: false)
                return
            }
            standDown()
        case .startFailed:
            if !waitsForUser {
                onStatus?(PlayerStatus(text: "The song did not start.".l10n, kind: .problem))
            }
            standDown()
        case .takenOver:
            log.info("Something else plays now; Ahenk's queue steps back")
            standDown()
        }
        scheduleWake()
    }

    private func standDown() {
        attempt = nil
        isActive = false
        waitsForUser = false
        lastOwn = nil
        endLoading()
        wake?.cancel()
        wake = nil
    }

    private func scheduleWake() {
        wake?.cancel()
        wake = nil
        guard let time = QueueConductorPolicy.wakeTime(attempt: attempt, snapshot: nowPlaying.snapshot, now: Date()) else { return }
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        wake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, time.timeIntervalSinceNow), execute: work)
    }

    private func beginLoading() {
        loadingStart?.cancel()
        guard !isStarting else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attempt?.isConfirmed == false, !self.waitsForUser else { return }
            self.loadingShownAt = Date()
            self.isStarting = true
        }
        loadingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadingDelay, execute: work)
    }

    private func endLoading() {
        loadingStart?.cancel()
        loadingStart = nil
        guard isStarting else { return }
        let shown = loadingShownAt.map { Date().timeIntervalSince($0) } ?? Self.loadingMinimum
        let remaining = Self.loadingMinimum - shown
        guard remaining > 0 else {
            isStarting = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.attempt?.isConfirmed != false else { return }
            self.isStarting = false
        }
    }
}
