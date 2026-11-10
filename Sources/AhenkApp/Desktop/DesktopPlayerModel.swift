import AhenkKit
import AppKit
import Observation
import SwiftUI

/// A value that loads.
enum Loadable<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool { self == .loading }
}

/// Colours of the widgets, from the playing song's cover.
struct PlayerTheme: Equatable {
    /// Highlights: the playing row, active buttons, the progress line.
    let accent: Color
    /// The glass's tint.
    let glass: Color
    /// The clock's colour.
    let clock: Color
    let palette: Palette

    init(palette: Palette) {
        self.palette = palette
        accent = Color(palette.vivid[0])
        glass = Color(palette.backdrop)
        clock = Color(palette.onDark[0].mixed(with: .white, amount: 0.55))
    }

    static let neutral = PlayerTheme(palette: .neutral)
}

/// What the Continue Playing widget lists.
enum ListSelection: Equatable {
    case continuePlaying
    case playlist(CatalogPlaylist)
    /// A folder of song files Ahenk plays itself.
    case folder(LocalFolder)
}

/// A page shown above the search field, over the cover flow.
enum PlayerPage: Equatable, Identifiable {
    case album(CatalogAlbum)
    case artist(CatalogArtist)

    var id: String {
        switch self {
        case .album(let album): "album:\(album.id)"
        case .artist(let artist): "artist:\(artist.id)"
        }
    }
}

/// What the page area shows: the queue (when it has no room beside the
/// player), a page, or the search results under them.
enum PageContent: Equatable {
    case queue
    case page(PlayerPage)
    case search
}

struct ArtistPageContent: Equatable {
    var albums: [CatalogAlbum]
    var topSongs: [CatalogSong]
}

/// Everything the desktop widgets show and do. Views read only what they
/// need, so a song change re-draws the bar and the list, not the clock; the
/// song's position is drawn by an AppKit view, never by SwiftUI.
@MainActor
@Observable
final class DesktopPlayerModel {
    private(set) var theme = PlayerTheme.neutral

    // Continue Playing and playlists
    private(set) var recent: [CatalogSong] = []
    var listSelection: ListSelection = .continuePlaying {
        didSet { if listSelection != oldValue { loadListSongs() } }
    }
    private(set) var playlistSongs: Loadable<[CatalogSong]> = .idle
    private(set) var playlists: PlaybackRouter.PlaylistsAnswer?

    // The artist's albums (cover flow)
    private(set) var artist: CatalogArtist?
    private(set) var albums: Loadable<[CatalogAlbum]> = .idle
    /// The album of the playing song, when the catalog has it.
    private(set) var playingAlbumID: String?

    // Pages
    private(set) var pages: [PlayerPage] = []
    private(set) var albumSongs: [String: Loadable<[CatalogSong]>] = [:]
    private(set) var artistContent: [String: Loadable<ArtistPageContent>] = [:]

    // Search
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var search: Loadable<CatalogSearchResults> = .idle
    /// The small player shows its search field.
    var isSearchOpen = false
    /// The field asks for keyboard focus (the search button, "Add Songs").
    private(set) var focusRequest = 0

    // Panels
    var isQueueOpen = false {
        didSet { if isQueueOpen != oldValue { refreshSiteQueue() } }
    }
    /// The music site's own queue, shown while Ahenk's queue is not playing.
    private(set) var siteQueue: BrowserQueue?
    /// The queue has no room beside the player and opens as a page (set by
    /// the controller from the widgets' places).
    var queueAsPage = false
    var isVolumeOpen = false {
        didSet { if isVolumeOpen { refreshVolume() } }
    }
    private(set) var volume: Double?

    private(set) var status: PlayerStatus?

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let nowPlaying: NowPlayingModel
    @ObservationIgnored let services: NowPlayingServices
    @ObservationIgnored let router: PlaybackRouter
    @ObservationIgnored let conductor: QueueConductor
    @ObservationIgnored let images: CoverImageStore
    @ObservationIgnored var catalog: any MusicCatalog { services.catalog }
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onResetLayout: (() -> Void)?
    /// Gives the keyboard back to the app the user works in.
    @ObservationIgnored var onReleaseKeyboard: (() -> Void)?
    /// Clear Desk (Step 9); `nil` while it is not available.
    @ObservationIgnored var clearDesk: (() -> DeskClearing)?
    /// The live wallpaper, for the picker dots above the player.
    @ObservationIgnored var wallpaper: WallpaperController?
    /// Files dropped on a widget (screen point of the drop); `true` when
    /// they were taken.
    @ObservationIgnored var onDropFiles: (([URL], DesktopWidget, CGPoint?) -> Bool)?
    /// "Add Sticker…" in the player's menu.
    @ObservationIgnored var onAddSticker: (() -> Void)?
    /// "Sound Effects…" in the player's menu.
    @ObservationIgnored var onOpenSoundEffects: (() -> Void)?
    /// Ahenk's own player for song files.
    @ObservationIgnored var local: LocalPlayer?
    /// The folders of song files the user gave Ahenk.
    @ObservationIgnored var library: LocalLibraryStore?
    /// The remembered folders, newest first.
    private(set) var localFolders: [LocalFolder] = []

    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var artistTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var siteQueueTask: Task<Void, Never>?
    @ObservationIgnored private var statusEnd: DispatchWorkItem?
    @ObservationIgnored private var artistKey: String?
    @ObservationIgnored private var pendingVolume: Double?
    @ObservationIgnored private var isStarted = false
    /// The widgets are on screen: catalog lookups only happen then.
    @ObservationIgnored private(set) var isPresented = false
    private let log = AhenkLogger(category: "player")

    init(settings: AppSettings, nowPlaying: NowPlayingModel, services: NowPlayingServices, demo: DemoProvider?) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.services = services
        router = PlaybackRouter(services: services, demo: demo)
        conductor = QueueConductor(router: router, nowPlaying: nowPlaying, services: services)
        images = CoverImageStore(services: services, demo: demo)
        conductor.onStatus = { [weak self] status in self?.show(status) }
    }

    // MARK: Lifecycle

    /// Follows the music (the queue keeps going while the widgets are hidden).
    func start() {
        guard !isStarted else { return }
        isStarted = true
        conductor.start()
        let nowPlaying = self.nowPlaying
        let settings = self.settings
        observers.append(ChangeObserver({ nowPlaying.artwork?.palette }) { [weak self] palette in
            guard let self, let palette else { return }
            self.theme = PlayerTheme(palette: palette)
        })
        if let palette = nowPlaying.artwork?.palette { theme = PlayerTheme(palette: palette) }
        observers.append(ChangeObserver({ nowPlaying.snapshot?.track }) { [weak self] track in
            self?.readCredit(of: track)
            self?.trackChanged(track)
            self?.refreshSiteQueue()
        })
        observers.append(ChangeObserver({ settings.player.listeningSource }) { [weak self] _ in
            self?.sourceChanged()
        })
        if let library {
            tasks.append(Task { [weak self] in
                for await folders in library.changes() {
                    guard let self else { return }
                    self.localFolders = folders
                    if case .folder(let shown) = self.listSelection, !folders.contains(where: { $0.path == shown.path }) {
                        self.listSelection = .continuePlaying
                    }
                }
            })
        }
        local?.onProblem = { [weak self] message in self?.show(PlayerStatus(text: message, kind: .problem)) }
        let store = services.recentlyPlayed
        tasks.append(Task { [weak self] in
            for await items in store.changes() {
                guard let self else { return }
                let songs = items.map { CatalogSong(playing: $0.track) }
                if songs != self.recent {
                    self.recent = songs
                    if self.artist == nil, nowPlaying.snapshot == nil { self.trackChanged(nil) }
                }
            }
        })
    }

    func stop() {
        isStarted = false
        isPresented = false
        conductor.stop()
        observers = []
        tasks.forEach { $0.cancel() }
        tasks = []
        [artistTask, searchTask, listTask, volumeTask, siteQueueTask].forEach { $0?.cancel() }
        statusEnd?.cancel()
    }

    /// The widgets appeared or went away.
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            artistKey = nil
            trackChanged(nowPlaying.snapshot?.track)
            refreshPlaylists()
        } else {
            artistTask?.cancel()
            isVolumeOpen = false
            images.trim()
        }
    }

    // MARK: Source

    /// Where picks play (the source picker).
    var listeningSource: MusicSource {
        if router.isDemo { return .demo }
        return ListeningSourceChoice.resolve(
            chosen: settings.player.listeningSource,
            playing: nowPlaying.snapshot?.track.source,
            isAvailable: { [router] in router.unavailableReason(for: $0) == nil }
        ) ?? .appleMusic
    }

    /// The sources the picker lists (the demo alone in demo mode).
    var sourceOptions: [MusicSource] {
        router.isDemo ? [.demo] + PlaybackRouter.listenable : PlaybackRouter.listenable
    }

    func unavailableReason(for source: MusicSource) -> String? {
        router.unavailableReason(for: source)
    }

    /// Picks where songs play (`nil`: follow what plays). With "pause the
    /// previous source" on, the other sources pause.
    func choose(_ source: MusicSource?) {
        let previous = listeningSource
        settings.player.listeningSource = source
        let current = listeningSource
        if current != previous, settings.sources.pauseOthersOnSwitch, !router.isDemo {
            services.pausePlayers(otherThan: current)
        }
    }

    private func sourceChanged() {
        if case .playlist = listSelection { listSelection = .continuePlaying }
        refreshPlaylists()
        if isSearching { queryChanged() }
    }

    // MARK: Now playing

    var snapshot: NowPlayingSnapshot? { nowPlaying.snapshot }

    var isPlaying: Bool { nowPlaying.isPlaying }

    /// Ahenk starts each song itself, so the transport acts on its queue.
    var drivesQueue: Bool { conductor.isActive }

    /// There is a queue the panel can show: Ahenk's own (started from a
    /// list, an album or "Play Next"), its player's for song files, or the
    /// playing site's. A music app such as Spotify keeps its queue to
    /// itself, so the queue button is hidden while one plays by itself.
    var hasQueueToShow: Bool {
        conductor.isActive || isLocalCurrent || snapshot?.track.source.isSite == true
    }

    /// The song that is starting (the bar shows it while it loads).
    var startingSong: CatalogSong? { conductor.startingSong }

    func togglePlayPause() {
        services.perform(.togglePlayPause)
    }

    func next() {
        if drivesQueue { conductor.next() } else { services.perform(.next) }
    }

    func previous() {
        if drivesQueue { conductor.previous() } else { services.perform(.previous) }
    }

    func seek(to seconds: TimeInterval) {
        services.perform(.seek(to: seconds))
    }

    var canPlayPause: Bool { snapshot?.capabilities.contains(.playPause) == true }
    var canSkip: Bool { drivesQueue || snapshot?.capabilities.contains(.skip) == true }

    var isShuffled: Bool {
        drivesQueue ? conductor.queue.isShuffled : (snapshot?.isShuffled ?? false)
    }

    var repeatMode: RepeatMode {
        drivesQueue ? conductor.queue.repeatMode : (snapshot?.repeatMode ?? .off)
    }

    var canShuffle: Bool { drivesQueue || snapshot?.capabilities.contains(.shuffle) == true }
    var canRepeat: Bool { drivesQueue || snapshot?.capabilities.contains(.repeatAll) == true }

    func toggleShuffle() {
        if drivesQueue {
            conductor.setShuffled(!conductor.queue.isShuffled)
        } else if let snapshot, snapshot.capabilities.contains(.shuffle) {
            services.perform(.setShuffle(!(snapshot.isShuffled ?? false)))
        }
    }

    func cycleRepeat() {
        if drivesQueue {
            conductor.cycleRepeat()
            return
        }
        guard let snapshot else { return }
        let next: RepeatMode
        switch snapshot.repeatMode ?? .off {
        case .off: next = .all
        case .all: next = snapshot.capabilities.contains(.repeatOne) ? .one : .off
        case .one: next = .off
        }
        services.perform(.setRepeat(next))
    }

    var canLike: Bool {
        guard let snapshot else { return false }
        return snapshot.capabilities.contains(.like) && snapshot.isLiked != nil
    }

    var isLiked: Bool { snapshot?.isLiked ?? false }

    func toggleLike() {
        guard let snapshot else { return }
        let command = PlaybackCommand.setLiked(!(snapshot.isLiked ?? false))
        guard snapshot.capabilities.supports(command) else { return }
        services.perform(command)
    }

    var lyricsOn: Bool { settings.lyrics.enabled }

    /// Step 6 shows the lyrics beside the cover when this is on.
    func toggleLyrics() {
        settings.lyrics.enabled.toggle()
    }

    // MARK: Playing picks

    func play(_ songs: [CatalogSong], at index: Int, context: QueueContext?) {
        guard songs.indices.contains(index) else { return }
        clearStatus()
        // A song file plays in Ahenk itself, with the list's other files.
        if LocalSong(songs[index]) != nil, let local {
            playLocally(songs, at: index, context: context, in: local)
            return
        }
        if settings.sources.pauseOthersOnSwitch { local?.pause() }
        // A music site's playlist plays in the site, in its own order.
        if case .playlist(let id, let name) = context, PlaybackRouter.isSitePlaylist(CatalogPlaylist(id: id, name: name)) {
            let source = listeningSource
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.router.playSitePlaylist(CatalogPlaylist(id: id, name: name), from: index, in: source)
                self.report(outcome)
            }
            return
        }
        conductor.play(songs, at: index, context: context, in: source(for: songs[index]))
    }

    /// A router answer as a message above the bar (nothing when it started).
    private func report(_ outcome: PlaybackRouter.Outcome) {
        switch outcome {
        case .started, .needsUser: break
        case .shown(let message): show(PlayerStatus(text: message, kind: .info))
        case .unavailable(let message), .failed(let message): show(PlayerStatus(text: message, kind: .problem))
        }
    }

    // MARK: The site's own queue

    /// Reads the playing site's queue while the queue panel is open and
    /// Ahenk's own queue is not playing.
    func refreshSiteQueue() {
        siteQueueTask?.cancel()
        guard isQueueOpen, !conductor.isActive, let source = nowPlaying.snapshot?.track.source, source.isSite else {
            if siteQueue != nil { siteQueue = nil }
            return
        }
        siteQueueTask = Task { [weak self] in
            // The site updates its list a moment after the song changes.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let queue = await self.router.siteQueue(of: source)
            guard !Task.isCancelled else { return }
            self.siteQueue = queue
        }
    }

    func playSiteQueueItem(_ item: BrowserQueue.Item) {
        guard let source = siteQueue?.site else { return }
        Task { [weak self] in
            guard let self else { return }
            if !(await self.router.playSiteQueueItem(item.index, in: source)) {
                self.show(PlayerStatus(text: "The site did not play this song.".l10n, kind: .problem))
            }
            self.refreshSiteQueue()
        }
    }

    func removeSiteQueueItem(_ item: BrowserQueue.Item) {
        guard let source = siteQueue?.site else { return }
        Task { [weak self] in
            guard let self else { return }
            if !(await self.router.removeSiteQueueItem(item.index, in: source)) {
                self.show(PlayerStatus(text: "The site did not remove this song.".l10n, kind: .problem))
            }
            self.refreshSiteQueue()
        }
    }

    /// Where a pick plays: the chosen source; with the picker on Automatic,
    /// a song that played before goes back to where it played.
    private func source(for song: CatalogSong) -> MusicSource {
        if !router.isDemo, settings.player.listeningSource == nil, let origin = song.origin?.source,
           ListeningSourceChoice.offered.contains(origin), router.unavailableReason(for: origin) == nil {
            return origin
        }
        return listeningSource
    }

    func playNext(_ songs: [CatalogSong]) {
        let (files, others) = split(songs)
        if let local, !files.isEmpty { local.playNext(files) }
        if !others.isEmpty { conductor.playNext(others) }
        show(PlayerStatus(text: songs.count == 1 ? "Plays next.".l10n : "These songs play next.".l10n, kind: .info))
    }

    func addToQueue(_ songs: [CatalogSong]) {
        let (files, others) = split(songs)
        if let local, !files.isEmpty { local.addToQueue(files) }
        if !others.isEmpty { conductor.addToQueue(others) }
        show(PlayerStatus(text: songs.count == 1 ? "Added to the queue.".l10n : "These songs were added to the queue.".l10n, kind: .info))
    }

    /// Song files go to Ahenk's own player's queue, the rest to Ahenk's
    /// queue for the other sources.
    private func split(_ songs: [CatalogSong]) -> (files: [CatalogSong], others: [CatalogSong]) {
        guard local != nil else { return ([], songs) }
        return (songs.filter { LocalSong($0) != nil }, songs.filter { LocalSong($0) == nil })
    }

    // MARK: Song files

    /// Plays song files in Ahenk itself: the other sources' queue steps
    /// back and (with "pause the previous source") the others pause.
    private func playLocally(_ songs: [CatalogSong], at index: Int, context: QueueContext?, in local: LocalPlayer) {
        conductor.release()
        local.play(songs, at: index, context: context)
        if settings.sources.pauseOthersOnSwitch, !router.isDemo || services.state.players.contains(where: { $0.id.source == .demo }) {
            services.pausePlayers(otherThan: .local)
        }
    }

    /// Ahenk's own player is the one that plays (or was last).
    var isLocalCurrent: Bool {
        snapshot?.track.source == .local && local?.hasSongs == true
    }

    /// Folders and song files dropped on the list or the player: folders
    /// are remembered, shown in the list and played; loose files play.
    func playDropped(_ urls: [URL]) {
        let folders = urls.filter(FileKinds.isFolder)
        let files = urls.filter { !FileKinds.isFolder($0) && FileKinds.isSong($0) }
        if let first = folders.first, let library {
            for folder in folders.reversed() { library.add(folder) }
            let folder = library.folders.first { $0.path == first.standardizedFileURL.path } ?? LocalFolder(path: first.standardizedFileURL.path)
            playFolder(folder)
        } else if !files.isEmpty {
            Task { [weak self] in
                let songs = await LocalLibraryScanner.songs(of: files, root: nil)
                guard let self, let local = self.local else { return }
                guard !songs.isEmpty else {
                    self.show(PlayerStatus(text: "Ahenk cannot play these files.".l10n, kind: .problem))
                    return
                }
                self.playLocally(songs.map(\.catalogSong), at: 0, context: .droppedSongs, in: local)
            }
        }
    }

    /// "Add Folder…": folders of song files picked in an open panel.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders of songs; Ahenk plays them itself.".l10n
        panel.prompt = "Add".l10n
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in self?.playDropped(urls) }
        }
    }

    /// Shows a folder's songs in the list and plays them.
    func playFolder(_ folder: LocalFolder) {
        listSelection = .folder(folder)
        Task { [weak self] in
            guard let self else { return }
            let songs = await self.folderSongs(folder)
            guard self.listSelection == .folder(folder) else { return }
            self.playlistSongs = .loaded(songs)
            guard let local = self.local else { return }
            guard !songs.isEmpty else {
                self.show(PlayerStatus(text: "This folder has no songs Ahenk can play.".l10n, kind: .problem))
                return
            }
            self.playLocally(songs, at: 0, context: .folder(path: folder.path, name: folder.name), in: local)
        }
    }

    func forgetFolder(_ folder: LocalFolder) {
        library?.remove(path: folder.path)
    }

    /// A folder's songs, read from the files (where it is now).
    private func folderSongs(_ folder: LocalFolder) async -> [CatalogSong] {
        guard let url = library?.resolve(folder) ?? (FileManager.default.fileExists(atPath: folder.path) ? folder.url : nil) else {
            show(PlayerStatus(text: "This folder is no longer there.".l10n, kind: .problem))
            return []
        }
        let songs = await Task.detached(priority: .userInitiated) { await LocalLibraryScanner.songs(in: url) }.value
        return songs.map(\.catalogSong)
    }

    /// Loads the album's songs, then plays, queues or shuffles them.
    func playAlbum(_ album: CatalogAlbum, mode: AlbumAction = .play) {
        Task { [weak self] in
            guard let self, let songs = await self.loadAlbumSongs(album), !songs.isEmpty else { return }
            let context = QueueContext.album(id: album.id, title: album.title)
            switch mode {
            case .play: self.play(songs, at: 0, context: context)
            case .shuffle:
                self.play(songs, at: Int.random(in: 0..<songs.count), context: context)
                self.conductor.setShuffled(true)
            case .playNext: self.playNext(songs)
            case .addToQueue: self.addToQueue(songs)
            }
        }
    }

    enum AlbumAction {
        case play
        case shuffle
        case playNext
        case addToQueue
    }

    /// The list's round button: pauses the list while it plays, resumes it
    /// while it is paused, else plays it from the top.
    func toggleList() {
        if isListPlaying {
            services.perform(.pause)
            return
        }
        // A paused song of this list resumes, wherever it was started.
        if isListSongCurrent, snapshot != nil {
            services.perform(.play)
            return
        }
        if case .folder(let folder) = listSelection, !isListCurrent {
            playFolder(folder)
            return
        }
        if isListCurrent, snapshot != nil {
            services.perform(.play)
            return
        }
        let songs = listSongs
        guard !songs.isEmpty else { return }
        play(songs, at: 0, context: listContext)
    }

    var listSongs: [CatalogSong] {
        switch listSelection {
        case .continuePlaying: recent
        case .playlist, .folder: playlistSongs.value ?? []
        }
    }

    var listContext: QueueContext {
        switch listSelection {
        case .continuePlaying: .continuePlaying
        case .playlist(let playlist): .playlist(id: playlist.id, name: playlist.name)
        case .folder(let folder): .folder(path: folder.path, name: folder.name)
        }
    }

    /// Ahenk's queue (or its own player's) was started from the list shown.
    private var isListCurrent: Bool {
        if isLocalCurrent, local?.queue.context == listContext { return true }
        return drivesQueue && conductor.queue.context == listContext
    }

    /// The song that plays (or is paused) is one of the list's rows, even
    /// when it was started in the music app and not from this list.
    private var isListSongCurrent: Bool {
        guard let track = snapshot?.track else { return false }
        return listSongs.contains { SongMatching.matches($0, track) }
    }

    /// The list is what plays right now: started from it, or the playing
    /// song is one of its rows. The round button then shows pause, in step
    /// with the player bar.
    var isListPlaying: Bool { isPlaying && (isListCurrent || isListSongCurrent) }

    /// The row of a list that plays.
    func isPlaying(_ song: CatalogSong) -> Bool {
        if let starting = startingSong { return starting.id == song.id }
        guard let track = snapshot?.track else { return false }
        return SongMatching.matches(song, track)
    }

    // MARK: Lists

    func refreshPlaylists() {
        let source = listeningSource
        listTask?.cancel()
        listTask = Task { [weak self] in
            guard let self else { return }
            let answer = await self.router.playlists(of: source)
            guard !Task.isCancelled else { return }
            self.playlists = answer
        }
    }

    private func loadListSongs() {
        if case .folder(let folder) = listSelection {
            playlistSongs = .loading
            Task { [weak self] in
                guard let self else { return }
                let songs = await self.folderSongs(folder)
                guard self.listSelection == .folder(folder) else { return }
                self.playlistSongs = .loaded(songs)
            }
            return
        }
        guard case .playlist(let playlist) = listSelection else {
            playlistSongs = .idle
            return
        }
        playlistSongs = .loading
        let source = listeningSource
        Task { [weak self] in
            guard let self else { return }
            let songs = await self.router.songs(of: playlist, in: source)
            guard self.listSelection == .playlist(playlist) else { return }
            self.playlistSongs = .loaded(songs)
        }
    }

    // MARK: The artist's albums

    /// The artist of the playing song (or the most recent one) and that
    /// song's album, looked up once per artist and album, only while the
    /// widgets are on screen.
    private func trackChanged(_ track: Track?) {
        guard isPresented else { return }
        guard let candidate = track ?? recent.first?.origin, !candidate.artist.isEmpty else { return }
        let key = TrackMatching.normalized(candidate.artist) + "|" + TrackMatching.normalized(candidate.album)
        guard key != artistKey else { return }
        artistKey = key
        artistTask?.cancel()
        let catalog = self.catalog
        artistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if self.artist == nil { self.albums = .loading }
            do {
                guard let match = try await catalog.artist(for: candidate) else {
                    guard !Task.isCancelled else { return }
                    self.playingAlbumID = nil
                    if self.artist == nil || self.albums.value == nil {
                        self.albums = .failed("The catalog does not know this artist.".l10n)
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                self.playingAlbumID = match.albumID
                if self.artist?.id != match.artist.id || self.albums.value == nil {
                    self.artist = match.artist
                    self.albums = .loading
                    let albums = try await catalog.albums(of: match.artist)
                    guard !Task.isCancelled else { return }
                    self.albums = .loaded(albums)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.artistKey = nil
                if self.albums.value == nil { self.albums = .failed(Self.message(for: error)) }
            }
        }
    }

    /// Looks the artist up again after a failure.
    func retryAlbums() {
        artistKey = nil
        albums = .idle
        trackChanged(nowPlaying.snapshot?.track)
    }

    // MARK: Pages

    /// What the page area shows (nil: the cover flow).
    var pageContent: PageContent? {
        if isQueueOpen && queueAsPage { return .queue }
        if let page = pages.last { return .page(page) }
        return isSearching ? .search : nil
    }

    var showsPage: Bool { pageContent != nil }

    /// A back button leads somewhere (an earlier page or the results).
    var canGoBack: Bool {
        if pageContent == .queue { return !pages.isEmpty || isSearching }
        return pages.count > 1 || (!pages.isEmpty && isSearching)
    }

    func open(_ page: PlayerPage) {
        // A page opened from the queue page replaces it.
        if pageContent == .queue { isQueueOpen = false }
        if pages.last != page { pages.append(page) }
        switch page {
        case .album(let album): Task { await self.loadAlbumSongs(album) }
        case .artist(let artist): loadArtist(artist)
        }
    }

    func back() {
        if pageContent == .queue {
            isQueueOpen = false
        } else if !pages.isEmpty {
            pages.removeLast()
        }
    }

    /// Closes every page, the queue page and the search.
    func closePages() {
        if queueAsPage { isQueueOpen = false }
        pages = []
        if isSearching { clearSearch() }
    }

    @discardableResult
    func loadAlbumSongs(_ album: CatalogAlbum) async -> [CatalogSong]? {
        if let songs = albumSongs[album.id]?.value { return songs }
        if albumSongs[album.id]?.isLoading != true { albumSongs[album.id] = .loading }
        do {
            let songs = try await catalog.songs(of: album)
            albumSongs[album.id] = .loaded(songs)
            return songs
        } catch {
            albumSongs[album.id] = .failed(Self.message(for: error))
            return nil
        }
    }

    func retryAlbumSongs(_ album: CatalogAlbum) {
        albumSongs[album.id] = nil
        Task { await self.loadAlbumSongs(album) }
    }

    private func loadArtist(_ artist: CatalogArtist) {
        if artistContent[artist.id]?.value != nil || artistContent[artist.id]?.isLoading == true { return }
        artistContent[artist.id] = .loading
        let catalog = self.catalog
        Task { [weak self] in
            do {
                async let albums = catalog.albums(of: artist)
                async let top = catalog.topSongs(of: artist, limit: 8)
                let content = ArtistPageContent(albums: try await albums, topSongs: try await top)
                self?.artistContent[artist.id] = .loaded(content)
            } catch {
                self?.artistContent[artist.id] = .failed(Self.message(for: error))
            }
        }
    }

    func retryArtist(_ artist: CatalogArtist) {
        artistContent[artist.id] = nil
        loadArtist(artist)
    }

    /// The artist page of the playing song's artist.
    func openPlayingArtist() {
        if let artist { open(.artist(artist)) }
    }

    /// The album page of the playing song.
    func openPlayingAlbum() {
        guard let album = playingAlbum else { return }
        open(.album(album))
    }

    var playingAlbum: CatalogAlbum? {
        guard let id = playingAlbumID else { return nil }
        return albums.value?.first { $0.id == id }
    }

    // MARK: The song's artists

    /// Everyone on the playing Spotify song, by track ID ("A, B, C"); the
    /// Spotify app itself names only the first.
    private(set) var credits: [String: String] = [:]
    @ObservationIgnored private lazy var spotifyArtists: SpotifyTrackArtists? = services.isDemo
        ? nil
        : SpotifyTrackArtists(fetcher: services.fetcher, cache: CatalogCache(directory: CatalogCache.standardDirectory))

    /// The artist line for `track`: everyone on it when known.
    func credit(for track: Track) -> String {
        credits[track.id] ?? track.artist
    }

    private func readCredit(of track: Track?) {
        guard let track, track.source == .spotify || track.source == .spotifyWeb, credits[track.id] == nil,
              let reader = spotifyArtists
        else { return }
        let id = track.id
        Task { [weak self] in
            guard let names = await reader.artists(of: id), names.count > 1 else { return }
            let credit = SpotifyTrackArtists.credit(names)
            guard let self, !credit.isEmpty else { return }
            if self.credits.count > 200 { self.credits.removeAll() }
            self.credits[id] = credit
        }
    }

    // MARK: Search

    func requestSearchFocus() {
        isSearchOpen = true
        focusRequest += 1
    }

    /// Empties the field, closes what it opened and gives the keyboard back.
    func clearSearch() {
        query = ""
        pages = []
        if settings.player.size == .small { isSearchOpen = false }
        onReleaseKeyboard?()
    }

    /// Return in the field: plays the first song found.
    func submitSearch() {
        guard let first = search.value?.songs.first else { return }
        play([first], at: 0, context: .search)
        onReleaseKeyboard?()
    }

    /// A song picked from the results plays alone; songs the user queued
    /// follow it.
    func playFromSearch(_ song: CatalogSong) {
        play([song], at: 0, context: .search)
        onReleaseKeyboard?()
    }

    private func queryChanged() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            search = .idle
            return
        }
        let catalog = self.catalog
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            if self.search.value == nil { self.search = .loading }
            do {
                let results = try await catalog.search(term, limit: 50)
                guard !Task.isCancelled else { return }
                self.search = .loaded(results)
            } catch {
                guard !Task.isCancelled else { return }
                self.search = .failed(Self.message(for: error))
            }
        }
    }

    func retrySearch() {
        search = .idle
        queryChanged()
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchPrompt: String { listeningSource.searchPrompt }

    // MARK: Volume

    var hasVolume: Bool {
        guard let source = snapshot?.track.source else { return false }
        return router.hasVolume(source)
    }

    func refreshVolume() {
        guard let source = snapshot?.track.source else { return }
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            guard let self else { return }
            let value = await self.router.volume(of: source)
            if self.pendingVolume == nil { self.volume = value }
        }
    }

    /// Sends at most ten changes a second while dragging.
    func setVolume(_ value: Double) {
        volume = value
        guard let source = snapshot?.track.source else { return }
        let first = pendingVolume == nil
        pendingVolume = value
        guard first else { return }
        Task { [weak self] in
            while let self, let value = self.pendingVolume {
                await self.router.setVolume(value, of: source)
                try? await Task.sleep(for: .milliseconds(100))
                if self.pendingVolume == value { self.pendingVolume = nil }
            }
        }
    }

    // MARK: Status

    func show(_ status: PlayerStatus) {
        self.status = status
        statusEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self, self.status == status else { return }
            self.status = nil
        }
        statusEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + (status.kind == .problem ? 7 : 3.5), execute: end)
    }

    func clearStatus() {
        status = nil
        statusEnd?.cancel()
    }

    // MARK: Layout and settings

    var size: PlayerSize { settings.player.size }

    /// What the player window must hold right now.
    var layoutState: PlayerLayoutState {
        let player = settings.player
        let wallpaper = settings.wallpaper
        return PlayerLayoutState(
            size: player.size, showsAlbums: player.showAlbums, showsSearch: player.showSearch,
            showsBar: player.showPlayerBar, showsPage: showsPage, isSearchOpen: isSearchOpen || isSearching,
            showsWallpaperPicker: self.wallpaper != nil && wallpaper.enabled && wallpaper.showPicker
        )
    }

    func setSize(_ size: PlayerSize) {
        settings.player.size = size
        if size == .large { isSearchOpen = false }
    }

    func toggleSize() {
        setSize(size == .large ? .small : .large)
    }

    var canClearDesk: Bool { clearDesk?().isAvailable == true }
    var isDeskCleared: Bool { clearDesk?().isActive == true }

    func toggleClearDesk() {
        clearDesk?().toggle()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func addSticker() {
        onAddSticker?()
    }

    func openSoundEffects() {
        onOpenSoundEffects?()
    }

    func resetLayout() {
        onResetLayout?()
    }

    func hidePlayer() {
        settings.player.enabled = false
    }

    // MARK: Helpers

    static func message(for error: Error) -> String {
        switch error as? CatalogError {
        case .rateLimited: "Too many requests to the catalog. Try again in a minute.".l10n
        case .offline: "The catalog cannot be reached. Check your connection.".l10n
        default: "The catalog did not answer.".l10n
        }
    }
}
