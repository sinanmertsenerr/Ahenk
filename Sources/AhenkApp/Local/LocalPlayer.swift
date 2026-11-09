import AhenkKit
import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// The hub's side of the local player: snapshots out, commands in.
final class LocalPlayerEngine: LocalPlaybackEngine, @unchecked Sendable {
    let broadcaster = SnapshotBroadcaster<NowPlayingSnapshot?>(nil)
    @MainActor weak var player: LocalPlayer?

    func snapshots() -> AsyncStream<NowPlayingSnapshot?> {
        broadcaster.stream()
    }

    func perform(_ command: PlaybackCommand) async -> Bool {
        await MainActor.run { player?.perform(command) ?? false }
    }
}

/// Ahenk plays song files itself: an `AVQueuePlayer` holding the current
/// song and the next one (so songs follow each other without a gap), the
/// queue's rules in `LocalQueue`, the sound handed to the analysis from
/// inside (`LocalAudioTap`), and, outside the demo, the system's Now
/// Playing and media keys.
///
/// Reported to the hub as the "Local" source (`LocalPlaybackProvider`), so
/// the light, the lyrics, the wallpaper, Continue Playing and the player
/// bar treat it like any other player.
@MainActor
@Observable
final class LocalPlayer {
    private(set) var queue = LocalQueue()
    private(set) var isPlaying = false
    /// How fast the songs play (the sound effects' speed); 1 is their own
    /// speed. The pitch stays where it is: shifting it is the effects' job.
    private(set) var speed = 1.0

    /// Says what went wrong (a file that cannot be played).
    @ObservationIgnored var onProblem: ((String) -> Void)?
    @ObservationIgnored let tap: OwnAudioTap
    @ObservationIgnored let engine = LocalPlayerEngine()
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private let publishesNowPlaying: Bool
    /// The current song's item first, then the next one's.
    @ObservationIgnored private var loaded: [(entry: UUID, item: AVPlayerItem)] = []
    @ObservationIgnored private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var cover: (path: String, data: Data?)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingPosition: TimeInterval = 0
    @ObservationIgnored private var failuresInARow = 0
    @ObservationIgnored private var commandsInstalled = false
    @ObservationIgnored private var leadSamples: [Double] = []
    @ObservationIgnored private var leadTimer: Timer?
    private let log = AhenkLogger(category: "local")

    /// Commands the local player takes (no favourites for files).
    static let capabilities: PlaybackCapabilities = [.playPause, .skip, .seek, .shuffle, .repeatAll, .repeatOne]
    /// After this many files in a row fail, the player stops trying.
    static let maximumFailures = 6

    /// - Parameters:
    ///   - publishesNowPlaying: show in the system's Now Playing and take
    ///     the media keys (not in demo and smoke runs).
    ///   - muted: silent (the smoke check).
    init(tap: OwnAudioTap, publishesNowPlaying: Bool, muted: Bool = false) {
        self.tap = tap
        self.publishesNowPlaying = publishesNowPlaying
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        if muted {
            player.isMuted = true
            player.volume = 0
        }
        engine.player = self
        playerObservations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.playStateChanged() }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    /// Something to play is loaded.
    var hasSongs: Bool { queue.current != nil }

    /// The song that plays (or is paused).
    var currentSong: LocalSong? { queue.current.flatMap { LocalSong($0.song) } }

    // MARK: Starting

    /// Plays `songs` (song files) from `index`; songs that are not files are
    /// left out.
    func play(_ songs: [CatalogSong], at index: Int, context: QueueContext?) {
        guard songs.indices.contains(index) else { return }
        let picked = songs[index]
        let files = songs.filter { LocalSong($0) != nil }
        guard let start = files.firstIndex(where: { $0.id == picked.id }) else { return }
        queue.start(files, at: start, context: context)
        failuresInARow = 0
        log.info("Playing \(files.count) song files from song \(start + 1)")
        startCurrent(playing: true)
    }

    func playNext(_ songs: [CatalogSong]) {
        let files = songs.filter { LocalSong($0) != nil }
        guard !files.isEmpty else { return }
        if queue.current == nil {
            play(files, at: 0, context: nil)
            return
        }
        queue.playNext(files)
        queueChanged()
    }

    func addToQueue(_ songs: [CatalogSong]) {
        let files = songs.filter { LocalSong($0) != nil }
        guard !files.isEmpty else { return }
        if queue.current == nil {
            play(files, at: 0, context: nil)
            return
        }
        queue.append(files)
        queueChanged()
    }

    func remove(_ id: UUID) {
        guard queue.remove(id) else { return }
        queueChanged()
    }

    func moveToFront(_ id: UUID) {
        guard queue.moveToFront(id) else { return }
        queueChanged()
    }

    func clearUpNext() {
        queue.clearUpNext()
        queueChanged()
    }

    func jump(to id: UUID) {
        guard queue.jump(to: id) != nil else { return }
        startCurrent(playing: true)
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        publish()
    }

    /// Plays `value` times as fast from now on (0.5…2), also the songs that
    /// follow. The snapshot reports the speed, so the lyrics and the
    /// progress keep up.
    func setSpeed(_ value: Double) {
        let speed = value.isFinite ? value.clamped(to: SoundEffectSettings.speedRange) : 1
        guard speed != self.speed else { return }
        self.speed = speed
        tap.playbackSpeed = speed
        // `play()` starts at the default rate; a playing song changes now.
        player.defaultRate = Float(speed)
        if player.rate != 0 { player.rate = Float(speed) }
        log.info("Song files play at \(String(format: "%.2f", speed))× speed")
        if isPlaying { measureLead() }
        publish()
    }

    /// Lets go of everything (on quit).
    func shutdown() {
        generation += 1
        player.pause()
        player.removeAllItems()
        loaded = []
        itemObservations = [:]
        leadTimer?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if publishesNowPlaying {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            removeRemoteCommands()
        }
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: PlaybackCommand) -> Bool {
        guard queue.current != nil else { return false }
        switch command {
        case .play:
            resume()
        case .pause:
            player.pause()
        case .togglePlayPause:
            if isPlaying { player.pause() } else { resume() }
        case .next:
            let playing = isPlaying || player.currentItem == nil
            if queue.skipForward() != nil {
                startCurrent(playing: playing)
            } else {
                startCurrent(playing: false)
            }
            return true
        case .previous:
            switch queue.skipBack(position: position) {
            case .restart: seek(to: 0)
            case .moved: startCurrent(playing: isPlaying || player.currentItem == nil)
            }
            return true
        case .seek(let target):
            seek(to: target)
            return true
        case .setShuffle(let on):
            queue.setShuffled(on)
            queueChanged()
            return true
        case .setRepeat(let mode):
            queue.setRepeat(mode)
            queueChanged()
            return true
        case .setLiked:
            return false
        }
        publish()
        return true
    }

    private func resume() {
        if player.currentItem == nil || loaded.first?.entry != queue.current?.id {
            startCurrent(playing: true, at: pendingPosition)
        } else {
            player.play()
        }
    }

    private func seek(to seconds: TimeInterval) {
        let duration = currentSong?.duration ?? 0
        let target = max(0, duration > 0 ? min(seconds, duration - 0.05) : seconds)
        pendingPosition = target
        guard player.currentItem != nil else {
            publish()
            return
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        publish()
    }

    private var position: TimeInterval {
        if loaded.first?.entry == queue.current?.id, player.currentItem != nil {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { return max(0, seconds) }
        }
        return pendingPosition
    }

    // MARK: Items

    /// Loads the queue's current song (and the next one) and plays it from
    /// `position`, or shows it paused there.
    private func startCurrent(playing: Bool, at position: TimeInterval = 0) {
        generation += 1
        let generation = self.generation
        loaded = []
        itemObservations = [:]
        player.removeAllItems()
        pendingPosition = position
        guard let entry = queue.current, let song = LocalSong(entry.song) else {
            isPlaying = false
            publish()
            return
        }
        isPlaying = playing
        loadCover(of: song)
        publish()
        Task {
            guard let item = await makeItem(song), generation == self.generation else {
                if generation == self.generation { failed(entry.id) }
                return
            }
            loaded = [(entry.id, item)]
            observe(item, entry: entry.id)
            player.insert(item, after: nil)
            if position > 0 {
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard generation == self.generation else { return }
            if playing {
                player.play()
                measureLead()
            } else {
                player.pause()
            }
            publish()
            await preloadFollowing(generation)
        }
    }

    private func makeItem(_ song: LocalSong) async -> AVPlayerItem? {
        guard FileManager.default.isReadableFile(atPath: song.path) else { return nil }
        let asset = AVURLAsset(url: song.url)
        let item = AVPlayerItem(asset: asset)
        // Faster or slower without moving the pitch (music, not speech).
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = await LocalAudioTap.audioMix(for: asset, tap: tap)
        return item
    }

    /// Loads the song that follows (the same one again with repeat one)
    /// behind the current one, replacing a stale one.
    private func preloadFollowing(_ generation: Int) async {
        guard generation == self.generation, let current = loaded.first else { return }
        let next = queue.following
        if loaded.count > 1, let next, loaded[1].entry == next.id { return }
        for stale in loaded.dropFirst() {
            player.remove(stale.item)
            itemObservations[ObjectIdentifier(stale.item)] = nil
        }
        loaded = [current]
        guard let next, let song = LocalSong(next.song) else { return }
        guard let item = await makeItem(song) else {
            if generation == self.generation, queue.following?.id == next.id {
                failed(next.id)
            }
            return
        }
        guard generation == self.generation, loaded.count == 1, loaded[0].item === current.item, queue.following?.id == next.id,
              player.canInsert(item, after: current.item)
        else { return }
        loaded.append((next.id, item))
        observe(item, entry: next.id)
        player.insert(item, after: current.item)
    }

    private func observe(_ item: AVPlayerItem, entry: UUID) {
        itemObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.failed(entry) }
        }
    }

    /// The queue changed what follows: the item loaded in advance follows.
    private func queueChanged() {
        let generation = self.generation
        Task { await preloadFollowing(generation) }
        publish()
    }

    private func currentItemChanged() {
        let current = player.currentItem
        if let current, loaded.first?.item === current { return }
        if let current, loaded.count > 1, loaded[1].item === current {
            // The player moved on to the next song by itself, without a gap.
            let ended = loaded.removeFirst()
            itemObservations[ObjectIdentifier(ended.item)] = nil
            let next = queue.songEnded()
            guard next?.id == loaded[0].entry else {
                startCurrent(playing: true)
                return
            }
            failuresInARow = 0
            pendingPosition = 0
            if let song = currentSong { loadCover(of: song) }
            measureLead()
            publish()
            let generation = self.generation
            Task { await preloadFollowing(generation) }
            return
        }
        guard current == nil, !loaded.isEmpty else { return }
        // The last song ended.
        loaded = []
        itemObservations = [:]
        if queue.songEnded() != nil {
            startCurrent(playing: true)
        } else {
            log.info("The song files' queue ended")
            startCurrent(playing: false)
        }
    }

    private func playStateChanged() {
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying || player.currentItem != nil else { return }
        if !playing { pendingPosition = position }
        isPlaying = playing
        publish()
    }

    private func failed(_ entry: UUID) {
        let name = queue.entries.first { $0.id == entry }.map { ($0.song.title) } ?? ""
        failuresInARow += 1
        log.notice("A song file could not be played (\(failuresInARow) in a row)")
        onProblem?(name.isEmpty ? "A song file could not be played.".l10n : L10n.format("\u{201C}%@\u{201D} could not be played.", name))
        let isCurrent = queue.current?.id == entry
        let next = queue.dropUnplayable(entry)
        guard failuresInARow < Self.maximumFailures else {
            log.notice("Too many song files failed; the local player stops")
            queue.clear()
            startCurrent(playing: false)
            return
        }
        if isCurrent {
            if next != nil { startCurrent(playing: true) } else { startCurrent(playing: false) }
        } else {
            queueChanged()
        }
    }

    // MARK: Cover and timing

    private func loadCover(of song: LocalSong) {
        guard cover?.path != song.path else { return }
        cover = (song.path, nil)
        let url = song.url
        let path = song.path
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { await LocalMetadata.artwork(of: url) }.value
            guard let self, self.cover?.path == path else { return }
            self.cover = (path, data)
            if data != nil { self.publish() }
        }
    }

    /// How far ahead of what is heard AVFoundation hands the audio to the
    /// tap: sampled four times a second for the first seconds of a song.
    private func measureLead() {
        leadTimer?.invalidate()
        leadSamples = []
        var ticks = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, ticks < 16 else {
                    timer.invalidate()
                    return
                }
                ticks += 1
                guard ticks > 2, let newest = self.tap.newestMediaTime else { return }
                let heard = self.player.currentTime().seconds
                // Media seconds ahead, as seconds of listening.
                let lead = (newest - heard) / self.speed
                if heard.isFinite, lead > 0.05, lead < 1.5 { self.leadSamples.append(lead) }
                if self.leadSamples.count >= 8 {
                    let mean = self.leadSamples.reduce(0, +) / Double(self.leadSamples.count)
                    self.tap.measuredLead = mean
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        leadTimer = timer
    }

    // MARK: Publishing

    func makeSnapshot(at now: Date = Date()) -> NowPlayingSnapshot? {
        guard let entry = queue.current, let song = LocalSong(entry.song) else { return nil }
        var track = song.track
        if track.duration == 0, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            track.duration = duration
        }
        let data = cover?.path == song.path ? cover?.data : nil
        return NowPlayingSnapshot(
            track: track, bundleIdentifier: KnownApps.ahenk, processIdentifier: ProcessInfo.processInfo.processIdentifier,
            elapsedTime: position, playbackRate: isPlaying ? speed : 0, timestamp: now, isShuffled: queue.isShuffled,
            repeatMode: queue.repeatMode, isLiked: nil, capabilities: Self.capabilities, contentKind: .music,
            artworkData: data, artworkIdentifier: data == nil ? nil : "local:\(song.path)"
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        engine.broadcaster.publish(snapshot)
        if publishesNowPlaying { updateSystemNowPlaying(snapshot) }
    }

    // MARK: System Now Playing

    private func updateSystemNowPlaying(_ snapshot: NowPlayingSnapshot?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let snapshot else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            removeRemoteCommands()
            return
        }
        installRemoteCommands()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.track.title,
            MPMediaItemPropertyArtist: snapshot.track.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.track.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let data = snapshot.artworkData, let image = NSImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        let pairs: [(MPRemoteCommand, PlaybackCommand)] = [
            (center.playCommand, .play), (center.pauseCommand, .pause), (center.togglePlayPauseCommand, .togglePlayPause),
            (center.nextTrackCommand, .next), (center.previousTrackCommand, .previous),
        ]
        for (remote, command) in pairs {
            remote.isEnabled = true
            remote.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.perform(command) }
                return .success
            }
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            DispatchQueue.main.async { self?.perform(.seek(to: time)) }
            return .success
        }
    }

    private func removeRemoteCommands() {
        guard commandsInstalled else { return }
        commandsInstalled = false
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand,
                        center.previousTrackCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
    }
}
