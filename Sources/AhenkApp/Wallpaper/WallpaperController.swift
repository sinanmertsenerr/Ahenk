import AhenkKit
import AppKit
import Observation

/// Where the live wallpaper looks things up. Live: Apple's catalog (the
/// player's own, shared cache and pace) for the album, the motion artwork
/// finder, the keyless YouTube search. Demo: nothing (generated motion).
struct WallpaperLookups {
    let catalog: (any MusicCatalog)?
    let videos: YouTubeVideoSearch?
    let motion: MotionArtworkFinder?
    let store: WallpaperSongStore

    var isOffline: Bool { catalog == nil && videos == nil && motion == nil }

    @MainActor
    static func live(services: NowPlayingServices) -> WallpaperLookups {
        let fetcher = URLSessionFetcher()
        let cache = CatalogCache(directory: CatalogCache.standardDirectory)
        let storefront = services.storefront
        return WallpaperLookups(
            catalog: services.catalog,
            videos: YouTubeVideoSearch(fetcher: fetcher, region: { storefront.code }, cache: cache),
            motion: MotionArtworkFinder(fetcher: fetcher, storefront: { storefront.code }, cache: cache),
            store: WallpaperSongStore(fileURL: WallpaperSongStore.standardURL)
        )
    }

    /// `--wallpaper-song` in demo mode: real lookups for one named song,
    /// with caches in memory only.
    static func online(storefront: String) -> WallpaperLookups {
        let fetcher = URLSessionFetcher()
        let cache = CatalogCache(directory: nil)
        return WallpaperLookups(
            catalog: ITunesCatalog(fetcher: fetcher, storefront: { storefront }, cache: cache),
            videos: YouTubeVideoSearch(fetcher: fetcher, region: { storefront }, cache: cache),
            motion: MotionArtworkFinder(fetcher: fetcher, storefront: { storefront }, cache: cache),
            store: WallpaperSongStore(fileURL: nil)
        )
    }

    static let offline = WallpaperLookups(catalog: nil, videos: nil, motion: nil, store: WallpaperSongStore(fileURL: nil))
}

/// One display's live wallpaper: its window, its stage (see
/// `WallpaperStage`) and the media on it.
@MainActor
final class WallpaperScreen {
    let id: String
    let displayID: CGDirectDisplayID
    private(set) var frame: CGRect
    /// The part apps can cover (without the menu bar and the Dock), in
    /// CoreGraphics' coordinates (top-left origin), as window lists use.
    var usableArea: CGRect = .zero
    let window: WallpaperWindow
    var stage = WallpaperStage()
    var media: [String: WallpaperMediaView] = [:]
    var ready: Set<String> = []
    /// The candidate brought to the front last.
    var front: String?
    var isOccluded = false
    var occlusion: NSObjectProtocol?

    init(id: String, displayID: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.displayID = displayID
        self.frame = frame
        window = WallpaperWindow(frame: frame)
    }

    var aspectRatio: Double {
        frame.height > 0 ? Double(frame.width / frame.height) : 16.0 / 10
    }

    func move(to frame: CGRect) {
        self.frame = frame
        if window.frame != frame { window.setFrame(frame, display: false) }
    }

    func close() {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        for view in media.values {
            view.tearDown()
            view.removeFromSuperview()
        }
        media = [:]
        ready = []
        window.orderOut(nil)
        window.close()
    }
}

/// Runs the live wallpaper on every display: a layer just above the desktop
/// picture that melts in while a song plays and back out to the user's own
/// wallpaper. What it shows, in the order Settings › Live Wallpaper prefers:
/// the album's motion artwork (Apple's catalog), the song's own music video
/// or another by the artist (YouTube's embedded player), the moving cover;
/// or a video from the user's list. The picker dots above the player choose
/// among them.
///
/// Inputs: the settings (and the menu bar's Live Wallpaper switch), the
/// followed song and its play state, the cover, power (lighter on battery,
/// in Optimized Mode; the cover only in Low Power Mode), the displays, and
/// whether each window can be seen (covered, asleep, locked, behind a
/// full-screen app): hidden media pauses and is let go after 20 s.
@MainActor
@Observable
final class WallpaperController {
    enum Status: Equatable, CustomStringConvertible {
        case off
        case waitingForMusic
        case looking
        case showing(WallpaperCandidate.Kind, LightFramePlan.Reason)
        case nothingToShow
        /// Covered, asleep, behind a full-screen app.
        case hidden
        /// Settings switch it off on every display.
        case everyDisplayOff

        var description: String {
            switch self {
            case .off: "off"
            case .waitingForMusic: "waiting for music"
            case .looking: "looking"
            case .showing(let kind, let reason): "showing \(kind.rawValue) (\(reason.rawValue))"
            case .nothingToShow: "nothing to show"
            case .hidden: "hidden"
            case .everyDisplayOff: "off on every display"
            }
        }
    }

    /// What the picker dots show.
    enum PickerPhase: Equatable {
        /// No song the wallpaper follows.
        case idle
        case looking
        case ready
        /// Nothing but the cover: the artist's name can be typed.
        case nothingFound
    }

    private(set) var status: Status = .off
    /// The picker dots, in order (the user's videos at the end).
    private(set) var offer: [WallpaperCandidate] = []
    /// What shows now (or is about to).
    private(set) var currentID: String?
    private(set) var phase: PickerPhase = .idle
    /// The artist name searched with (typed, or the player's).
    private(set) var artistName = ""
    /// The user typed the artist's name for this song's artist.
    private(set) var isArtistTyped = false

    /// Demo captures: keep playing while app windows cover the desktop.
    @ObservationIgnored static var drawsWhenCovered = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private let power: PowerMonitor
    @ObservationIgnored private let demo: DemoProvider?
    @ObservationIgnored private let lookups: WallpaperLookups
    @ObservationIgnored private let songOverride: (title: String, artist: String, duration: Double)?
    @ObservationIgnored private let forcedKind: WallpaperCandidate.Kind?
    @ObservationIgnored private let desktop = DesktopWatcher()
    @ObservationIgnored private var screens: [String: WallpaperScreen] = [:]
    @ObservationIgnored private var players: [String: SharedVideoPlayer] = [:]
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var isStarted = false

    // The song and its lookups.
    @ObservationIgnored private var request: WallpaperRequest?
    @ObservationIgnored private var requestIdentity: String?
    @ObservationIgnored private var found: [WallpaperCandidate] = []
    @ObservationIgnored private var pending: Set<WallpaperCandidate.Kind> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var embedChecked: Set<String> = []
    @ObservationIgnored private var embedChecking: Set<String> = []
    @ObservationIgnored private var lookupStarted = Date.distantPast
    @ObservationIgnored private var lookupTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var wanted: WallpaperCandidate?
    /// The choice before the embedding check (what the dots highlight).
    @ObservationIgnored private var chosenID: String?

    // Music.
    @ObservationIgnored private var music: WallpaperMusic = .stopped(since: .distantPast)
    @ObservationIgnored private var lastPosition: (elapsed: TimeInterval, at: Date)?

    // Visibility.
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var sessionLocked = false
    /// Displays whose desktop other apps' windows cover (see
    /// `WallpaperCoverage`), looked at while music plays.
    @ObservationIgnored private var coveredDisplays: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var coverageTimer: Timer?

    // Timers.
    @ObservationIgnored private var wake: DispatchWorkItem?
    @ObservationIgnored private var wakeAt: Date?
    @ObservationIgnored private var patience: DispatchWorkItem?
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var lastLook: (dimming: Double, blur: Double)?

    private static let log = AhenkLogger(category: "wallpaper")

    init(
        settings: AppSettings, nowPlaying: NowPlayingModel, power: PowerMonitor, demo: DemoProvider?, lookups: WallpaperLookups,
        songOverride: (title: String, artist: String, duration: Double)? = nil, forcedKind: WallpaperCandidate.Kind? = nil
    ) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.power = power
        self.demo = demo
        self.lookups = lookups
        self.songOverride = songOverride
        self.forcedKind = forcedKind
        status = settings.wallpaper.enabled ? .waitingForMusic : .off
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let settings = self.settings
        let nowPlaying = self.nowPlaying
        let power = self.power
        observers.append(ChangeObserver({ settings.wallpaper }) { [weak self] wallpaper in
            self?.settingsChanged(wallpaper)
        })
        observers.append(ChangeObserver({
            LightFrameInputs(
                optimizedMode: settings.general.optimizedMode, lighterOnBattery: settings.general.lighterOnBattery,
                isOnBattery: power.isOnBattery, isLowPowerMode: power.isLowPowerMode, isThermallyConstrained: power.isThermallyConstrained
            )
        }) { [weak self] _ in
            self?.refresh()
        })
        observers.append(ChangeObserver({ nowPlaying.snapshot }) { [weak self] _ in
            self?.snapshotChanged()
        })
        observers.append(ChangeObserver({ nowPlaying.artwork?.identifier }) { [weak self] _ in
            self?.coverChanged()
        })
        listen(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuildScreens() }
        let workspace = NSWorkspace.shared.notificationCenter
        listen(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.refresh() }
        listen(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.refresh() }
        listen(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionLocked = true; $0.refresh() }
        listen(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionLocked = false; $0.refresh() }
        let distributed = DistributedNotificationCenter.default()
        listen(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.sessionLocked = true; $0.refresh() }
        listen(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.sessionLocked = false; $0.refresh() }
        desktop.onChange = { [weak self] in
            self?.readCoverage()
            self?.refresh()
        }
        desktop.start()

        lastLook = nil
        rebuildScreens()
        snapshotChanged()
        Self.log.info("Live wallpaper \(settings.wallpaper.enabled ? "on" : "off")\(lookups.isOffline ? " (no lookups: demo)" : "")")
    }

    /// Closes every window and lets every player go (on quit). The user's
    /// own wallpaper was never changed, so there is nothing to restore.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        observers = []
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
        desktop.stop()
        lookupTasks.forEach { $0.cancel() }
        lookupTasks = []
        wake?.cancel()
        patience?.cancel()
        syncTimer?.invalidate()
        syncTimer = nil
        coverageTimer?.invalidate()
        coverageTimer = nil
        screens.values.forEach { $0.close() }
        screens = [:]
        players.values.forEach { $0.tearDown() }
        players = [:]
        lookups.store.flush()
    }

    private func listen(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (WallpaperController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    // MARK: The picker dots

    /// A dot was clicked: show it for this song (a video from the user's
    /// list is pinned until another dot is chosen).
    func choose(_ candidateID: String) {
        if candidateID.hasPrefix("user:") {
            settings.wallpaper.selectVideo(id: String(candidateID.dropFirst("user:".count)))
            return
        }
        settings.wallpaper.selectedVideoID = nil
        if let request { lookups.store.setPick(candidateID, forSong: request.songKey) }
        failed.remove(candidateID)
        refresh()
    }

    /// The artist's name typed in the picker: search again with it (also for
    /// later songs credited the same way).
    func searchArtist(_ name: String) {
        guard let request else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = request.reportedArtist.isEmpty ? request.title : request.reportedArtist
        lookups.store.setArtistName(clean.isEmpty || clean == request.reportedArtist ? nil : clean, for: original)
        requestIdentity = nil
        snapshotChanged()
    }

    var hasSong: Bool { request != nil && settings.wallpaper.enabled }

    // MARK: The user's videos

    /// Adds a YouTube link (or ID) or the web address of a video to the
    /// list and shows it; `false` when the text is neither. A YouTube
    /// video's title is asked of YouTube afterwards.
    @discardableResult
    func addVideo(fromAddress text: String) -> Bool {
        guard let video = WallpaperVideoInput.savedVideo(from: text), video.kind != .file else { return false }
        add(video)
        return true
    }

    /// Adds a video file from this Mac and shows it; `false` for a file
    /// type the list does not play.
    @discardableResult
    func addVideoFile(_ url: URL) -> Bool {
        guard url.isFileURL, let video = WallpaperVideoInput.fileVideo(path: url.path) else { return false }
        add(video)
        return true
    }

    private func add(_ video: SavedVideo) {
        let entry = settings.wallpaper.addVideo(video)
        settings.wallpaper.selectVideo(id: entry.id)
        Self.log.info("Added a \(entry.kind.rawValue) video to the wallpaper list")
        guard entry.kind == .youtube, entry.title == entry.reference, let search = lookups.videos else { return }
        Task { [weak self] in
            guard let title = await search.embedInfo(of: entry.reference)?.title else { return }
            self?.settings.wallpaper.renameVideo(id: entry.id, to: title)
        }
    }

    // MARK: Inputs

    private func settingsChanged(_ wallpaper: WallpaperSettings) {
        if !wallpaper.enabled, status != .off { Self.log.info("Live wallpaper off") }
        // Turning sources on or off, or the preference, looks again.
        let key = "\(wallpaper.useMotionArtwork)|\(wallpaper.useMusicVideos)|\(wallpaper.useArtworkFallback)"
        if key != sourcesKey {
            sourcesKey = key
            requestIdentity = nil
        }
        snapshotChanged()
    }

    @ObservationIgnored private var sourcesKey = ""

    private func snapshotChanged() {
        guard isStarted else { return }
        let now = Date()
        let snapshot = nowPlaying.snapshot
        let follows = snapshot.map(WallpaperRequest.follows) ?? false
        // Music state, with the time of each change (the pause grace).
        if let snapshot, follows, snapshot.isPlaying {
            music = .playing
        } else if snapshot != nil, follows {
            if case .paused = music {} else { music = .paused(since: now) }
        } else if case .stopped = music {} else {
            music = .stopped(since: now)
        }
        // A new song (or new terms) looks things up again.
        if let snapshot, follows, settings.wallpaper.enabled {
            let next = makeRequest(snapshot)
            let identity = [
                next.songKey, next.artist, next.source.rawValue, next.trackID, next.songVideoKind?.rawValue ?? "",
                settings.wallpaper.preferredSource.rawValue,
            ].joined(separator: "|")
            if identity != requestIdentity {
                requestIdentity = identity
                startLookup(next)
            }
        } else if snapshot == nil || !follows {
            if request != nil {
                request = nil
                requestIdentity = nil
                lookupTasks.forEach { $0.cancel() }
                pending = []
            }
        }
        // A seek or a resume brings a following video back in step.
        if let snapshot {
            let position = snapshot.elapsed(at: now)
            if let last = lastPosition {
                let expected = last.elapsed + (music == .playing ? now.timeIntervalSince(last.at) : 0)
                if abs(expected - position) > 1.5 { needsSync = true }
            }
            lastPosition = (position, now)
        }
        refresh()
    }

    @ObservationIgnored private var needsSync = false

    private func makeRequest(_ snapshot: NowPlayingSnapshot) -> WallpaperRequest {
        var song = snapshot
        if let songOverride {
            // `--wallpaper-song`: the demo plays, the lookups are for this song.
            song.track.title = songOverride.title
            song.track.artist = songOverride.artist
            song.track.source = .appleMusic
            song.track.id = "override:\(songOverride.artist)|\(songOverride.title)"
            // The demo song's length says nothing about the real one.
            song.track.duration = songOverride.duration
            song.songVideoKind = nil
        }
        let plain = WallpaperRequest(snapshot: song)
        let original = plain.reportedArtist.isEmpty ? plain.title : plain.reportedArtist
        guard let typed = lookups.store.artistName(for: original) else { return plain }
        return WallpaperRequest(snapshot: song, artistOverride: typed)
    }

    private func coverChanged() {
        for screen in screens.values {
            for case let view as CoverMotionView in screen.media.values {
                feedCover(view)
            }
        }
    }

    private func feedCover(_ view: CoverMotionView) {
        let artwork = nowPlaying.artwork
        let palette = artwork?.palette ?? demoSong?.palette ?? .neutral
        view.setCover(artwork?.image, palette: palette, key: artwork?.identifier ?? "palette:\(palette.colors.map(\.hex).joined())")
    }

    private var demoSong: DemoSong? {
        guard let demo, let track = nowPlaying.snapshot?.track else { return nil }
        return demo.song(for: track)
    }

    // MARK: Lookups

    private func startLookup(_ request: WallpaperRequest) {
        lookupTasks.forEach { $0.cancel() }
        lookupTasks = []
        self.request = request
        found = []
        failed = []
        pending = []
        lookupStarted = Date()
        artistName = request.artist
        isArtistTyped = request.artist != request.reportedArtist
        let wallpaper = settings.wallpaper
        if let song = demoSong, songOverride == nil {
            found = WallpaperDemo.candidates(for: song).filter { $0.kind != .artwork || wallpaper.useArtworkFallback }
        } else {
            if wallpaper.useMusicVideos, let tab = request.tabVideo { found.append(tab) }
            if wallpaper.useArtworkFallback { found.append(.artwork) }
            if wallpaper.useMotionArtwork, lookups.motion != nil, lookups.catalog != nil, request.isSearchable {
                pending.insert(.motionArtwork)
                lookupTasks.append(Task { [weak self] in await self?.findMotionArtwork(request) })
            }
            if wallpaper.useMusicVideos, lookups.videos != nil, request.isSearchable {
                pending.formUnion([.songVideo, .artistVideo])
                lookupTasks.append(Task { [weak self] in await self?.findVideos(request) })
            }
        }
        Self.log.info("Looking up the wallpaper for the playing song (\(pending.map(\.rawValue).sorted().joined(separator: ", ")))")
        patience?.cancel()
        if !pending.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            patience = work
            DispatchQueue.main.asyncAfter(deadline: .now() + WallpaperSelection.patience + 0.05, execute: work)
        }
    }

    private func findMotionArtwork(_ request: WallpaperRequest) async {
        defer { finish(.motionArtwork, for: request) }
        guard let catalog = lookups.catalog, let finder = lookups.motion else { return }
        let track = Track(id: request.trackID, source: request.source, title: request.title, artist: request.artist,
                          album: request.album, duration: request.duration)
        let match: CatalogArtistMatch?
        do {
            match = try await catalog.artist(for: track)
        } catch {
            Self.log.info("Motion artwork: the catalog did not answer (\(String(describing: error)))")
            return
        }
        guard let album = match?.albumID.flatMap(ITunesCatalog.number(in:)) else {
            Self.log.info("Motion artwork: the song's album is not in the catalog (\(match == nil ? "no match" : "artist only"))")
            return
        }
        guard !Task.isCancelled else { return }
        let lookup = await finder.artwork(albumID: album)
        switch lookup {
        case .found(let artwork):
            guard !Task.isCancelled, let url = artwork.url(forAspectRatio: mainAspectRatio) else { return }
            Self.log.info("Motion artwork found for the song's album")
            add([.motion(artwork, url: url)], for: request)
        case .none:
            Self.log.info("Motion artwork: the album has none")
        case .failed:
            Self.log.info("Motion artwork: the catalog did not answer")
        }
    }

    private func findVideos(_ request: WallpaperRequest) async {
        guard let search = lookups.videos else {
            finish(.songVideo, for: request)
            finish(.artistVideo, for: request)
            return
        }
        var songIDs: Set<String> = []
        if let tabID = request.tabVideoID { songIDs.insert(tabID) }
        do {
            let results = try await search.search(request.songQuery)
            guard !Task.isCancelled else { return }
            let ranked = VideoRanking.songVideos(results, title: request.title, artist: request.artist, duration: request.duration > 0 ? request.duration : nil)
            let videos = ranked.prefix(2).filter { !songIDs.contains($0.video.id) }.map { WallpaperCandidate.youtube($0.video, kind: .songVideo) }
            songIDs.formUnion(ranked.map(\.video.id))
            add(videos, for: request)
        } catch {
            Self.log.info("Video search for the song failed: \(String(describing: error))")
        }
        finish(.songVideo, for: request)
        do {
            let results = try await search.search(request.artistQuery)
            guard !Task.isCancelled else { return }
            let ranked = VideoRanking.artistVideos(results, artist: request.artist, excluding: songIDs, songTitle: request.title, limit: 4)
            add(ranked.map { WallpaperCandidate.youtube($0.video, kind: .artistVideo) }, for: request)
        } catch {
            Self.log.info("Video search for the artist failed: \(String(describing: error))")
        }
        finish(.artistVideo, for: request)
    }

    private func add(_ candidates: [WallpaperCandidate], for request: WallpaperRequest) {
        guard request == self.request, !candidates.isEmpty else { return }
        found.append(contentsOf: candidates)
        refresh()
    }

    private func finish(_ kind: WallpaperCandidate.Kind, for request: WallpaperRequest) {
        guard request == self.request, pending.remove(kind) != nil else { return }
        if pending.isEmpty {
            let videos = found.filter { $0.kind.isVideo }.count
            Self.log.info("Wallpaper lookups done: \(videos) video\(videos == 1 ? "" : "s") for the playing song")
        }
        refresh()
    }

    /// Whether YouTube allows the video in an embedded player (asked once
    /// per video, just before it would show; no answer means try it).
    private func checkEmbedding(_ candidate: WallpaperCandidate) {
        guard case .youtube(let id) = candidate.media, let search = lookups.videos else {
            embedChecked.insert(candidate.id)
            return
        }
        guard !embedChecking.contains(candidate.id) else { return }
        embedChecking.insert(candidate.id)
        Task { [weak self] in
            let info = await search.embedInfo(of: id)
            guard let self else { return }
            self.embedChecking.remove(candidate.id)
            self.embedChecked.insert(candidate.id)
            if let status = info?.status, status != .embeddable {
                Self.log.info("A wallpaper video does not allow embedding (\(status.rawValue)); trying the next")
                self.failed.insert(candidate.id)
            }
            self.refresh()
        }
    }

    // MARK: Choosing

    private var powerPlan: WallpaperPowerPlan {
        WallpaperPowerPolicy.plan(LightFrameInputs(
            optimizedMode: settings.general.optimizedMode, lighterOnBattery: settings.general.lighterOnBattery,
            isOnBattery: power.isOnBattery, isLowPowerMode: power.isLowPowerMode, isThermallyConstrained: power.isThermallyConstrained
        ))
    }

    private var userCandidates: [WallpaperCandidate] {
        settings.wallpaper.savedVideos.compactMap(WallpaperCandidate.user)
    }

    private func updateWanted(plan: WallpaperPowerPlan, now: Date) {
        let wallpaper = settings.wallpaper
        let ordered = WallpaperSelection.ordered(found + userCandidates, preference: wallpaper.preferredSource)
        let pinned = wallpaper.selectedVideoID.map { "user:\($0)" }
        var pick = request.flatMap { lookups.store.pick(forSong: $0.songKey) }
        if pick == nil, let forcedKind { pick = ordered.first { $0.kind == forcedKind }?.id }
        let waited = now.timeIntervalSince(lookupStarted) >= WallpaperSelection.patience
        var choice = request == nil && pinned == nil ? nil : WallpaperSelection.choose(
            ordered, preference: wallpaper.preferredSource, pinned: pinned, pick: pick, failed: failed,
            pending: pending, waited: waited, allowsVideo: plan.allowsVideo
        )
        // A YouTube video is asked about embedding before it loads.
        var gated: WallpaperCandidate?
        if let candidate = choice, candidate.isEmbedded, !embedChecked.contains(candidate.id) {
            checkEmbedding(candidate)
            gated = candidate
            choice = nil
        }
        if choice?.id != wanted?.id, let choice {
            Self.log.info("Wallpaper: \(choice.kind.rawValue)\(choice.title.isEmpty ? "" : " \u{201C}\(choice.title)\u{201D}")")
        }
        wanted = choice
        chosenID = gated?.id ?? choice?.id
        if offer != ordered { offer = ordered }
        let videos = ordered.contains { $0.kind.isVideo && $0.kind != .userVideo }
        let nextPhase: PickerPhase
        if request == nil {
            // No song: only the user's own videos can be chosen.
            nextPhase = pinned == nil ? .idle : .ready
        } else if !pending.isEmpty, !videos {
            nextPhase = .looking
        } else if !videos, pending.isEmpty, wallpaper.useMusicVideos, lookups.videos != nil {
            nextPhase = .nothingFound
        } else {
            nextPhase = .ready
        }
        if phase != nextPhase { phase = nextPhase }
    }

    private func candidate(_ id: String) -> WallpaperCandidate? {
        offer.first { $0.id == id } ?? (wanted?.id == id ? wanted : nil)
    }

    // MARK: Screens

    private func rebuildScreens() {
        var seen: Set<String> = []
        for nsScreen in NSScreen.screens {
            guard let id = DisplayIdentity.stableID(of: nsScreen), let displayID = DisplayIdentity.displayID(of: nsScreen) else { continue }
            seen.insert(id)
            let usable = Self.quartzRect(of: nsScreen.visibleFrame)
            if let existing = screens[id] {
                existing.move(to: nsScreen.frame)
                existing.usableArea = usable
                continue
            }
            let screen = WallpaperScreen(id: id, displayID: displayID, frame: nsScreen.frame)
            screen.usableArea = usable
            screen.occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: screen.window, queue: .main
            ) { [weak self, weak screen] _ in
                MainActor.assumeIsolated {
                    guard let self, let screen else { return }
                    let covered = screen.window.isVisible && !screen.window.occlusionState.contains(.visible)
                    guard covered != screen.isOccluded else { return }
                    screen.isOccluded = covered
                    self.refresh()
                }
            }
            screens[id] = screen
        }
        for (id, screen) in screens where !seen.contains(id) {
            screen.close()
            screens[id] = nil
        }
        lastLook = nil
        refresh()
    }

    private var mainAspectRatio: Double {
        let main = NSScreen.screens.first?.frame.size ?? CGSize(width: 16, height: 10)
        return main.height > 0 ? Double(main.width / main.height) : 1.6
    }

    private func isEnabled(on screen: WallpaperScreen) -> Bool {
        settings.wallpaper.isEnabled(onDisplay: screen.id)
    }

    private func isVisible(_ screen: WallpaperScreen) -> Bool {
        if screensAsleep || sessionLocked { return false }
        if desktop.fullScreenDisplays.contains(screen.displayID) { return false }
        if Self.drawsWhenCovered { return true }
        return !screen.isOccluded && !coveredDisplays.contains(screen.displayID)
    }

    /// AppKit's coordinates (bottom-left origin) → CoreGraphics' (top-left).
    private static func quartzRect(of rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Which displays other apps' windows cover (bounds, owners and levels
    /// only: no window contents, no permission).
    private func readCoverage() {
        guard !Self.drawsWhenCovered else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { info -> CGRect? in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowOwnerPID as String] as? Int32) != me,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                      let raw = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: raw)
                else { return nil }
                return bounds
            }
        let covered = Set(screens.values.filter { WallpaperCoverage.isHidden($0.usableArea, by: windows) }.map(\.displayID))
        guard covered != coveredDisplays else { return }
        coveredDisplays = covered
        Self.log.info("Desktop covered by app windows on \(covered.count) display(s)")
        refresh()
    }

    /// Windows move and resize without telling anyone: while music plays,
    /// look every 2 s (a millisecond of work).
    private func updateCoverageWatch() {
        let watching = music == .playing && settings.wallpaper.enabled && !Self.drawsWhenCovered
        if watching, coverageTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readCoverage() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            coverageTimer = timer
            readCoverage()
        } else if !watching, let timer = coverageTimer {
            timer.invalidate()
            coverageTimer = nil
            if !coveredDisplays.isEmpty { coveredDisplays = [] }
        }
    }

    // MARK: Applying

    private func refresh() {
        guard isStarted else { return }
        let now = Date()
        let plan = powerPlan
        updateWanted(plan: plan, now: now)
        applyLook()
        let wallpaper = settings.wallpaper
        var nextWake: Date?
        for screen in screens.values {
            let inputs = WallpaperStage.Inputs(
                isEnabled: isEnabled(on: screen), music: music, returnsOnPause: wallpaper.returnsOnPause, wanted: wanted?.id,
                ready: screen.ready, isVisible: isVisible(screen), crossfade: wallpaper.crossfadeDuration
            )
            let stagePlan = screen.stage.update(inputs, now: now)
            apply(stagePlan, to: screen, power: plan)
            if let at = stagePlan.wakeAt { nextWake = min(nextWake ?? at, at) }
        }
        for (id, player) in players where player.users <= 0 {
            player.tearDown()
            players[id] = nil
        }
        schedule(nextWake)
        updateSync()
        updateCoverageWatch()
        updateStatus(plan: plan)
        let shown = screens.values.compactMap { $0.stage.isShowing ? $0.front : nil }.first
        let current = request == nil && settings.wallpaper.selectedVideoID == nil ? nil : (chosenID ?? shown)
        if currentID != current { currentID = current }
    }

    private func applyLook() {
        let look = (settings.wallpaper.dimming, settings.wallpaper.blur)
        guard lastLook.map({ $0 != look }) ?? true else { return }
        lastLook = look
        for screen in screens.values {
            screen.window.content.setLook(dimming: look.0, blur: look.1)
        }
    }

    private func apply(_ plan: WallpaperStage.Plan, to screen: WallpaperScreen, power: WallpaperPowerPlan) {
        let fade = settings.wallpaper.crossfadeDuration
        // Let go of what is no longer needed.
        for (id, view) in screen.media where !plan.keep.contains(id) {
            view.tearDown()
            view.removeFromSuperview()
            screen.media[id] = nil
            screen.ready.remove(id)
            if screen.front == id { screen.front = nil }
        }
        // Create what is wanted.
        for id in plan.keep where screen.media[id] == nil {
            guard let candidate = candidate(id), !failed.contains(id) else { continue }
            guard let view = makeMedia(candidate, on: screen, power: power) else {
                failed.insert(id)
                continue
            }
            view.alphaValue = 0
            screen.media[id] = view
            screen.window.content.host(view)
        }
        if plan.isUp, !screen.window.isVisible {
            screen.window.alphaValue = 1
            screen.window.orderFrontRegardless()
        }
        screen.window.content.setOpacity(plan.opacity, duration: fade)
        // The front one on top: at once for the first picture (the whole
        // layer fades in), crossfading over the one before otherwise.
        if let front = plan.front, let view = screen.media[front] {
            if screen.front != front {
                let crossfades = screen.front != nil && plan.back != nil
                screen.window.content.bringToFront(view)
                if crossfades {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = fade
                        context.allowsImplicitAnimation = true
                        view.animator().alphaValue = 1
                    }
                } else {
                    view.alphaValue = 1
                }
                screen.front = front
            }
        } else {
            screen.front = nil
        }
        for (id, view) in screen.media where id != plan.front && id != plan.back {
            view.alphaValue = 0
        }
        if let back = plan.back { screen.media[back]?.alphaValue = 1 }
        for view in screen.media.values {
            view.apply(power)
            view.setPlaying(plan.playback == .play)
        }
        if !plan.isUp, screen.window.isVisible {
            screen.window.orderOut(nil)
        }
    }

    private func makeMedia(_ candidate: WallpaperCandidate, on screen: WallpaperScreen, power: WallpaperPowerPlan) -> WallpaperMediaView? {
        let frame = NSRect(origin: .zero, size: screen.frame.size)
        let follows = syncMode(of: candidate) == .followsSong
        let view: WallpaperMediaView
        switch candidate.media {
        case .youtube(let id):
            let start = follows ? startPosition(lead: 1.5, duration: candidate.duration) : 0
            view = YouTubeMediaView(candidate: candidate, videoID: id, start: start, loops: !follows, plan: power, frame: frame)
        case .stream(let url), .file(let url):
            let shared = players[candidate.id] ?? {
                let made = SharedVideoPlayer(candidate: candidate, url: url, plan: power)
                made.onFailure = { [weak self] failure in self?.mediaFailed(candidate.id, failure) }
                players[candidate.id] = made
                if follows { made.seek(to: startPosition(lead: 0.3, duration: candidate.duration)) }
                return made
            }()
            shared.loops = !follows
            view = VideoPlayerMediaView(candidate: candidate, shared: shared, frame: frame)
        case .artwork:
            let cover = CoverMotionView(candidate: candidate, plan: power, frame: frame)
            feedCover(cover)
            view = cover
        case .generated(let look):
            let palette = nowPlaying.artwork?.palette ?? demoSong?.palette ?? .neutral
            let generated = GeneratedMotionView(candidate: candidate, look: look, colors: WallpaperDemo.colors(look: look, palette: palette), plan: power, frame: frame)
            if follows { generated.seek(to: startPosition(lead: 0, duration: candidate.duration)) }
            view = generated
        }
        view.setLoops(!follows)
        if follows { Self.log.info("The song's video follows the song (\(candidate.media.kindName))") }
        let id = candidate.id
        let screenID = screen.id
        view.onReady = { [weak self] in self?.mediaReady(id, on: screenID) }
        view.onFailure = { [weak self] failure in self?.mediaFailed(id, failure) }
        return view
    }

    private func mediaReady(_ id: String, on screenID: String) {
        guard let screen = screens[screenID], screen.media[id] != nil else { return }
        screen.ready.insert(id)
        if syncMode(of: candidate(id)) == .followsSong { needsSync = true }
        refresh()
    }

    private func mediaFailed(_ id: String, _ failure: WallpaperMediaFailure) {
        Self.log.info("A wallpaper candidate failed (\(id.split(separator: ":").first ?? "?")): \(failure.detail)")
        failed.insert(id)
        if case .everyVideo = failure, id.hasPrefix("youtube:") {
            // Offline, or the embedded player refused the app: no other
            // YouTube video will do better right now.
            for other in offer where other.isEmbedded { failed.insert(other.id) }
        }
        refresh()
    }

    // MARK: Following the song

    private func syncMode(of candidate: WallpaperCandidate?) -> VideoSyncMode {
        guard let candidate, nowPlaying.snapshot != nil else { return .loops }
        return VideoSync.mode(
            isSongVideo: candidate.kind == .songVideo, syncEnabled: settings.wallpaper.followSong,
            songDuration: request?.duration ?? nowPlaying.snapshot?.track.duration, videoDuration: candidate.duration
        )
    }

    private func startPosition(lead: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard let snapshot = nowPlaying.snapshot else { return 0 }
        return VideoSync.startPosition(songPosition: snapshot.elapsed(at: Date()), lead: lead, videoDuration: duration)
    }

    /// While a following video shows and the song plays, compare the two
    /// every few seconds (and at once after a seek or a resume).
    private func updateSync() {
        let following = screens.values.contains { screen in
            guard let front = screen.front else { return false }
            return syncMode(of: candidate(front)) == .followsSong
        }
        let active = following && music == .playing
        if active, syncTimer == nil {
            let timer = Timer(timeInterval: VideoSync.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFollowingVideos() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            syncTimer = timer
        } else if !active, let timer = syncTimer {
            timer.invalidate()
            syncTimer = nil
        }
        if active, needsSync {
            needsSync = false
            syncFollowingVideos()
        }
    }

    private func syncFollowingVideos() {
        guard let snapshot = nowPlaying.snapshot else { return }
        for screen in screens.values {
            guard let front = screen.front, let view = screen.media[front], syncMode(of: view.candidate) == .followsSong else { continue }
            let duration = view.candidate.duration
            view.position { time, length in
                guard let time else { return }
                let song = snapshot.elapsed(at: Date())
                if let target = VideoSync.correction(songPosition: song, videoPosition: time, videoDuration: length ?? duration) {
                    Self.log.info("The song's video was \(String(format: "%.1f", time - song)) s off; moved to \(String(format: "%.1f", target)) s")
                    view.seek(to: target)
                }
            }
        }
    }

    // MARK: Timers and status

    private func schedule(_ date: Date?) {
        guard date != wakeAt else { return }
        wake?.cancel()
        wakeAt = date
        guard let date else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.wakeAt = nil
            self?.refresh()
        }
        wake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, date.timeIntervalSinceNow), execute: work)
    }

    private func updateStatus(plan: WallpaperPowerPlan) {
        let next: Status
        let shown = screens.values.compactMap { $0.stage.isShowing ? $0.front : nil }.first
        if !settings.wallpaper.enabled {
            next = .off
        } else if let shown, let candidate = candidate(shown) {
            next = .showing(candidate.kind, plan.reason)
        } else if music != .playing, settings.wallpaper.selectedVideoID == nil || nowPlaying.snapshot == nil {
            next = .waitingForMusic
        } else if !screens.values.contains(where: isEnabled(on:)) {
            next = .everyDisplayOff
        } else if !screens.values.contains(where: { isEnabled(on: $0) && isVisible($0) }) {
            next = .hidden
        } else if wanted != nil || !pending.isEmpty || !embedChecking.isEmpty {
            next = .looking
        } else if request == nil, music == .playing {
            next = .waitingForMusic
        } else {
            next = .nothingToShow
        }
        guard next != status else { return }
        status = next
        Self.log.info("Live wallpaper: \(next)")
    }

    // MARK: Checks

    /// The windows (smoke checks).
    var windows: [WallpaperWindow] { screens.values.map(\.window) }
}

extension WallpaperCandidate.Media {
    /// For the log: what plays it, never what it is.
    var kindName: String {
        switch self {
        case .youtube: "embedded player"
        case .stream: "stream"
        case .file: "file"
        case .artwork: "cover"
        case .generated: "generated"
        }
    }
}
