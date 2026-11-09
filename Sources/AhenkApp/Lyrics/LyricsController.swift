import AhenkKit
import AppKit
import Observation

/// The lyrics of the song that plays, for the desktop widget, the menu and
/// Settings: found through the providers (or the demo), with the version
/// the user picked and the song's timing offsets, plus the "Other Lyrics"
/// and "Search Lyrics" lists.
///
/// Lyrics are looked up only while they are on, and only for music (and
/// players that do not say what they play), never for videos, podcasts or
/// adverts.
@MainActor
@Observable
final class LyricsController {
    enum Phase: Equatable {
        /// Nothing (or no music) plays.
        case idle
        case loading
        case synced
        /// Words without timing.
        case plain
        case instrumental
        case notFound
        /// The providers could not be reached.
        case failed
    }

    /// The widget's panel over the lines.
    enum Panel: Equatable {
        case versions
        case search
        /// The sound effects (the button beside the lyrics).
        case effects
        /// Timing plain lyrics against the song on this Mac (Beta).
        case align
    }

    private(set) var phase: Phase = .idle
    private(set) var lyrics: SyncedLyrics?
    private(set) var timeline: LyricsTimeline?
    private(set) var plainLines: [String] = []
    /// The provider that answered (`LyricsProvider.name`).
    private(set) var source: String?
    /// The version the user picked for this song, if any.
    private(set) var choice: LyricsVersion?
    private(set) var song: Track?
    private(set) var query: LyricsQuery?
    private(set) var timingAuthority: LyricsTimingAuthority = .unverified
    /// The user's nudge for this song (replaces the measured offset).
    private(set) var manualOffset: Double?
    /// Measured by automatic sync for these lyrics.
    private(set) var autoOffset: Double?

    var panel: Panel? {
        didSet {
            if panel == .versions, oldValue != .versions { loadVersions() }
            if panel == .search, oldValue != .search { prepareSearch() }
            if panel == .align, oldValue != .align { onFocusSearch?() }
            if panel == nil { onReleaseKeyboard?() }
        }
    }

    private(set) var versions: Loadable<[LyricsVersion]> = .idle
    private(set) var results: Loadable<[LyricsVersion]> = .idle
    var searchTitle = ""
    var searchArtist = ""
    /// The version being loaded after a pick.
    private(set) var choosing: String?
    /// A short message about the last action (a pick that failed).
    private(set) var notice: String?

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let nowPlaying: NowPlayingModel
    @ObservationIgnored private(set) var finder: LyricsFinder
    @ObservationIgnored private let makeChain: (Set<String>) -> LyricsChain
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var noticeEnd: DispatchWorkItem?
    @ObservationIgnored private var isStarted = false
    /// Gives the keyboard back (the widget's window).
    @ObservationIgnored var onReleaseKeyboard: (() -> Void)?
    /// Asks for the keyboard (the search fields).
    @ObservationIgnored var onFocusSearch: (() -> Void)?
    /// Asked by the hover menu.
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// The lyrics music sites loaded themselves (live only); they replace
    /// what is shown when they arrive for the song that plays.
    @ObservationIgnored var siteLyrics: BrowserLyricsProvider?
    @ObservationIgnored private var siteTask: Task<Void, Never>?
    private let log = AhenkLogger(category: "lyrics")

    /// Nudges move the timing this much (seconds).
    static let nudgeStep = 0.2

    init(settings: AppSettings, nowPlaying: NowPlayingModel, finder: LyricsFinder, makeChain: @escaping (Set<String>) -> LyricsChain) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.finder = finder
        self.makeChain = makeChain
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let nowPlaying = self.nowPlaying
        let settings = self.settings
        observers.append(ChangeObserver({ nowPlaying.snapshot.map(Self.identity) }) { [weak self] _ in
            self?.songChanged()
        })
        // Lyrics are looked up only while they are on: nothing about the
        // song leaves the Mac otherwise.
        observers.append(ChangeObserver({ settings.lyrics.enabled }) { [weak self] _ in
            self?.songChanged()
        })
        observers.append(ChangeObserver({ settings.lyrics.disabledProviders }) { [weak self] disabled in
            guard let self else { return }
            self.finder = self.finder.with(chain: self.makeChain(disabled))
        })
        if let siteLyrics {
            siteTask = Task { [weak self] in
                for await _ in siteLyrics.changes() { self?.siteLyricsArrived() }
            }
        }
        songChanged()
    }

    func stop() {
        isStarted = false
        observers = []
        siteTask?.cancel()
        siteTask = nil
        task?.cancel()
        listTask?.cancel()
        finder.songs.flush()
    }

    /// The song and whether it is music: a change of either looks again.
    private static func identity(_ snapshot: NowPlayingSnapshot) -> String {
        let track = snapshot.track
        return "\(track.source.rawValue)|\(track.title)|\(track.artist)|\(track.album)|\(Int(track.duration.rounded()))|\(wantsLyrics(snapshot))"
    }

    private static func wantsLyrics(_ snapshot: NowPlayingSnapshot) -> Bool {
        let kind = snapshot.contentKind
        return (kind == .music || kind == .unknown) && !snapshot.track.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func songChanged() {
        guard settings.lyrics.enabled, let snapshot = nowPlaying.snapshot, Self.wantsLyrics(snapshot) else {
            reset()
            return
        }
        let track = snapshot.track
        if let song, song.isSameSong(as: track), song.duration == track.duration || track.duration == 0, phase != .idle {
            self.song = track
            return
        }
        load(track)
    }

    private func reset() {
        task?.cancel()
        listTask?.cancel()
        song = nil
        query = nil
        phase = .idle
        lyrics = nil
        timeline = nil
        plainLines = []
        source = nil
        choice = nil
        manualOffset = nil
        autoOffset = nil
        versions = .idle
        results = .idle
        panel = nil
    }

    // MARK: Finding

    private func load(_ track: Track) {
        task?.cancel()
        listTask?.cancel()
        let query = LyricsQuery(track: track)
        song = track
        self.query = query
        phase = .loading
        lyrics = nil
        timeline = nil
        plainLines = []
        source = nil
        choice = nil
        versions = .idle
        results = .idle
        if panel == .versions { panel = nil }
        manualOffset = finder.songs.entry(for: query.cacheKey)?.manualOffset
        autoOffset = nil
        let finder = self.finder
        task = Task { [weak self] in
            let found = await finder.find(query) { [weak self] provisional in
                await self?.apply(provisional, choice: nil, for: query, provisional: true)
            }
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.apply(found.response, choice: found.choice, for: query, allFailed: found.allFailed, origin: found.origin)
        }
    }

    /// A site sent lyrics: when they are this song's, they replace what is
    /// shown (unless the user picked a version), even mid-lookup.
    private func siteLyricsArrived() {
        guard settings.lyrics.enabled, let query, choice == nil,
              BrowserLyricsProvider.site(ofSource: source ?? "") == nil,
              let found = siteLyrics?.lookup(query)
        else { return }
        task?.cancel()
        let response = LyricsResponse(
            result: .synced(found.lyrics), source: BrowserLyricsProvider.sourceName(for: found.site), timingAuthority: .canonicalRecording
        )
        apply(response, choice: nil, for: query, origin: .playingSource)
    }

    /// Tries the providers again (the failed state's button).
    func reload() {
        guard let song else { return }
        phase = .idle
        load(song)
    }

    private func apply(
        _ response: LyricsResponse, choice: LyricsVersion?, for query: LyricsQuery, allFailed: Bool = false,
        origin: LyricsFinder.Origin? = nil, provisional: Bool = false
    ) {
        guard self.query == query else { return }
        source = response.source
        self.choice = choice
        timingAuthority = response.timingAuthority
        switch response.result {
        case .synced(let lyrics):
            self.lyrics = lyrics
            timeline = LyricsTimeline(lyrics, duration: song.map { $0.duration > 0 ? $0.duration : nil } ?? nil)
            plainLines = []
            autoOffset = response.timingAuthority.allowsAutomaticCorrection
                ? finder.songs.autoOffset(for: query.cacheKey, fingerprint: lyrics.timingFingerprint)
                : nil
            phase = .synced
        case .plain(let text):
            lyrics = nil
            timeline = nil
            plainLines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            phase = plainLines.isEmpty ? .notFound : .plain
        case .instrumental:
            lyrics = nil
            timeline = nil
            plainLines = []
            phase = .instrumental
        case .notFound:
            guard !provisional else { return }
            lyrics = nil
            timeline = nil
            plainLines = []
            phase = allFailed ? .failed : .notFound
        }
        guard !provisional else { return }
        let lines = lyrics?.lines.count ?? plainLines.count
        let how = origin.map { " (\($0.rawValue))" } ?? ""
        log.info("Lyrics: \(Self.describe(phase)), \(lines) lines from \(response.source)\(how)")
    }

    private static func describe(_ phase: Phase) -> String {
        switch phase {
        case .idle: "nothing"
        case .loading: "loading"
        case .synced: "synced"
        case .plain: "plain"
        case .instrumental: "instrumental"
        case .notFound: "not found"
        case .failed: "providers unreachable"
        }
    }

    // MARK: Timing

    /// Seconds added to the song's position: the global offset plus this
    /// song's (the user's nudge replaces the measured value).
    var offset: Double { settings.lyrics.globalOffset + songOffset }

    var songOffset: Double { manualOffset ?? autoOffset ?? 0 }

    /// Lines earlier (positive) or later, from what is shown now.
    func nudge(by delta: Double) {
        guard let query else { return }
        let range = LyricsSongStore.offsetRange
        let value = min(range.upperBound, max(range.lowerBound, songOffset + delta))
        let rounded = (value * 100).rounded() / 100
        manualOffset = rounded == 0 ? nil : rounded
        finder.songs.setManualOffset(manualOffset, for: query.cacheKey)
        log.info("Lyrics offset for this song: \(String(format: "%+.2f", rounded)) s")
    }

    /// Back to the providers' timing (forgets the nudge and the measurement).
    func resetOffset() {
        guard let query else { return }
        manualOffset = nil
        autoOffset = nil
        finder.songs.setManualOffset(nil, for: query.cacheKey)
        finder.songs.setAutoOffset(nil, fingerprint: nil, for: query.cacheKey)
    }

    /// Automatic sync measured these lyrics (`fingerprint`) `value` seconds off.
    func applyMeasuredOffset(_ value: Double, fingerprint: String, for key: String) {
        finder.songs.setAutoOffset(value, fingerprint: fingerprint, for: key)
        guard key == query?.cacheKey, lyrics?.timingFingerprint == fingerprint else { return }
        autoOffset = value
    }

    /// The lyric line at `date` (Settings' demo card).
    func lyricLine(at date: Date) -> LyricLine? {
        guard let snapshot = nowPlaying.snapshot, let lyrics else { return nil }
        return lyrics.line(at: snapshot.elapsed(at: date) + offset)
    }

    // MARK: Other lyrics and search

    func loadVersions() {
        guard let query else { return }
        listTask?.cancel()
        versions = .loading
        let finder = self.finder
        listTask = Task { [weak self] in
            let found = await finder.versions(for: query)
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.versions = .loaded(found)
        }
    }

    private func prepareSearch() {
        if let song {
            searchTitle = LyricsQuery.cleanTitle(song.title)
            searchArtist = LyricsQuery.cleanArtist(song.artist)
        }
        results = .idle
        onFocusSearch?()
    }

    func search() {
        let title = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = searchArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !artist.isEmpty else { return }
        listTask?.cancel()
        results = .loading
        let finder = self.finder
        let query = LyricsQuery(title: title.isEmpty ? artist : title, artist: title.isEmpty ? "" : artist)
        listTask = Task { [weak self] in
            let found = await finder.search(query)
            guard let self, !Task.isCancelled else { return }
            self.results = .loaded(found)
        }
    }

    /// Makes `version` this song's lyrics (remembered for next time).
    func choose(_ version: LyricsVersion) {
        guard let query else { return }
        choosing = version.id
        let finder = self.finder
        Task { [weak self] in
            do {
                let response = try await finder.choose(version, for: query)
                guard let self, self.query == query else { return }
                // Another version has its own timing: the old nudge is gone.
                self.manualOffset = nil
                finder.songs.setManualOffset(nil, for: query.cacheKey)
                // A site's own lyrics are the automatic pick, not a choice.
                let isSite = BrowserLyricsProvider.site(ofSource: response.source) != nil
                self.apply(response, choice: isSite ? nil : version.withoutLyrics, for: query, origin: isSite ? .playingSource : nil)
                self.choosing = nil
                // Words without timing: offer to time them on this Mac.
                self.panel = self.phase == .plain && self.settings.lyrics.localAlignment ? .align : nil
            } catch {
                guard let self else { return }
                self.choosing = nil
                self.show("These lyrics could not be loaded.".l10n)
            }
        }
    }

    /// Makes lyrics that were timed on this Mac the song's lyrics (kept
    /// like a picked version). They are shown at once when `query` is
    /// still the song that plays.
    func adoptAligned(_ aligned: SyncedLyrics, for query: LyricsQuery) async {
        let adopted = await finder.adopt(aligned, for: query)
        guard self.query == query else { return }
        // Their own timing: an old nudge does not belong to them.
        manualOffset = nil
        finder.songs.setManualOffset(nil, for: query.cacheKey)
        apply(adopted.response, choice: adopted.version, for: query, origin: .choice)
    }

    /// The words to time for the song that plays: the plain lyrics that
    /// were found, or the lines of the lyrics shown.
    var wordsToAlign: [String] {
        if !plainLines.isEmpty { return plainLines }
        return lyrics?.lines.map(\.text).filter { LyricsTimeline.isSung($0) } ?? []
    }

    /// Forgets the pick: the providers choose again.
    func useAutomatic() {
        guard let query, let song else { return }
        let finder = self.finder
        Task { [weak self] in
            await finder.clearChoice(for: query)
            guard let self, self.query == query else { return }
            self.panel = nil
            self.phase = .idle
            self.load(song)
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Forgets every cached lyric (Settings).
    func clearCache() {
        let finder = self.finder
        Task {
            await finder.clearCache()
        }
    }

    // MARK: For the widget

    /// What the stage draws for the current phase.
    var stagePhase: LyricsStagePhase {
        switch phase {
        case .idle: .message("", symbol: nil)
        case .loading: .loading
        case .synced: timeline.map { $0.isEmpty ? .message("No lyrics for this song".l10n, symbol: "text.badge.xmark") : .lyrics } ?? .loading
        case .plain: .plain(plainLines)
        case .instrumental: .message("Instrumental".l10n, symbol: "music.note")
        case .notFound: .message("No lyrics for this song".l10n, symbol: "text.badge.xmark")
        case .failed: .message("The lyrics could not be loaded".l10n, symbol: "wifi.exclamationmark")
        }
    }

    /// True while a song with lyrics to look for plays (the widget shows).
    var hasSong: Bool { phase != .idle }

    /// "LRCLIB", "Musixmatch", "NetEase", "Demo", or the site whose own
    /// lyrics these are ("YouTube Music").
    static func displayName(ofProvider name: String) -> String {
        if let site = BrowserLyricsProvider.site(ofSource: name) { return site.source.title }
        if name == BrowserLyricsProvider.providerName { return "Music Site".l10n }
        if name == LyricsFinder.alignedSource { return "Timed on This Mac".l10n }
        return name == "demo" ? "Demo".l10n : name
    }
}
