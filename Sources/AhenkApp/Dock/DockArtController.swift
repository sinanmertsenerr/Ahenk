import AhenkKit
import AppKit
import Observation

/// The Dock icon: the playing song's cover with a ring that beats along
/// (Settings › Dock Art; the menu's quick toggle).
///
/// Every new tile is a bitmap the Dock process redraws, so the ring runs at
/// a few frames a second (`DockArtPolicy`), a frame that would look like
/// the one shown is never sent, a pause leaves one still tile, and with
/// nothing playing (or the setting off) the Dock shows Ahenk's own icon.
/// Without the system audio permission the ring swells softly every ~2 s
/// while music plays (like the edge light).
@MainActor
final class DockArtController {
    private let settings: AppSettings
    private let nowPlaying: NowPlayingModel
    private let features: any AudioFeatureSource
    private let power: PowerMonitor
    private var observers: [AnyObject] = []
    private var view: DockTileView?
    private var timer: Timer?
    private var motion = DockRingMotion()
    private var shown: DockArtFrame?
    private var coverIdentity: String?
    private(set) var mode: DockArtMode = .appIcon
    /// Tiles sent to the Dock since launch (measurements, the smoke check).
    private(set) var tilesSent = 0
    private var isStarted = false
    private let log = AhenkLogger(category: "dock")

    /// Soft swells while music plays but cannot be heard (no permission).
    static let softBeatPeriod = 1.9

    init(settings: AppSettings, nowPlaying: NowPlayingModel, features: any AudioFeatureSource, power: PowerMonitor) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.features = features
        self.power = power
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let settings = self.settings
        let nowPlaying = self.nowPlaying
        let power = self.power
        observers.append(ChangeObserver({ Self.inputs(settings: settings, nowPlaying: nowPlaying, power: power) }) { [weak self] _ in
            self?.apply()
        })
        observers.append(ChangeObserver({ nowPlaying.artwork?.identifier }) { [weak self] _ in
            self?.coverChanged()
        })
        coverChanged()
        apply()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observers = []
        stopTimer()
        removeTile()
    }

    // MARK: Mode

    static func inputs(settings: AppSettings, nowPlaying: NowPlayingModel, power: PowerMonitor) -> DockArtInputs {
        let snapshot = nowPlaying.snapshot
        let playing = snapshot.map { $0.isPlaying && AudioCapturePolicy.reactsTo($0) } ?? false
        return DockArtInputs(
            enabled: settings.dock.albumArtIcon, beatRing: settings.dock.beatRing,
            hasCover: snapshot != nil && nowPlaying.artwork != nil, isPlaying: playing,
            optimizedMode: settings.general.optimizedMode, lighterOnBattery: settings.general.lighterOnBattery,
            isOnBattery: power.isOnBattery, isLowPowerMode: power.isLowPowerMode, isThermallyConstrained: power.isThermallyConstrained
        )
    }

    private func apply() {
        let next = DockArtPolicy.mode(Self.inputs(settings: settings, nowPlaying: nowPlaying, power: power))
        let changed = next != mode
        mode = next
        switch next {
        case .appIcon:
            stopTimer()
            removeTile()
        case .still:
            stopTimer()
            showTile()
            send(.still(progress: progress(), turn: shown?.turn ?? 0), force: changed)
        case .animated(let fps):
            showTile()
            startTimer(framesPerSecond: fps)
            tick()
        }
        if changed { log.info("Dock icon: \(Self.describe(next))") }
    }

    private static func describe(_ mode: DockArtMode) -> String {
        switch mode {
        case .appIcon: "Ahenk's icon"
        case .still: "the cover, still"
        case .animated(let fps): "the cover with a beating ring, \(fps) fps"
        }
    }

    // MARK: The tile

    private func coverChanged() {
        guard let artwork = nowPlaying.artwork else {
            coverIdentity = nil
            view?.cover = nil
            return
        }
        guard artwork.identifier != coverIdentity else { return }
        coverIdentity = artwork.identifier
        let side = Int(NSApp.dockTile.size.width * 2)
        view?.cover = DockTileRenderer.roundCover(artwork.image, pixelSide: side)
        view?.colors = DockTileRenderer.ringColors(artwork.palette)
        shown = nil
        if mode != .appIcon { apply() }
    }

    private func showTile() {
        guard view == nil else { return }
        let tile = NSApp.dockTile
        let view = DockTileView(frame: NSRect(origin: .zero, size: tile.size))
        if let artwork = nowPlaying.artwork {
            view.cover = DockTileRenderer.roundCover(artwork.image, pixelSide: Int(tile.size.width * 2))
            view.colors = DockTileRenderer.ringColors(artwork.palette)
            coverIdentity = artwork.identifier
        }
        self.view = view
        tile.contentView = view
        shown = nil
    }

    private func removeTile() {
        guard view != nil else { return }
        view = nil
        shown = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        tilesSent += 1
    }

    private func send(_ frame: DockArtFrame, force: Bool = false) {
        guard let view, force || DockRingMotion.differs(frame, from: shown) else { return }
        view.state = frame
        view.needsDisplay = true
        NSApp.dockTile.display()
        shown = frame
        tilesSent += 1
    }

    // MARK: Frames

    private func startTimer(framesPerSecond: Int) {
        let interval = 1 / Double(max(1, framesPerSecond))
        if let timer, abs(timer.timeInterval - interval) < 0.001 { return }
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = AudioClock.now()
        var current = features.features(at: now)
        if current.isSilent {
            // Music plays but cannot be heard (no permission yet): soft swells.
            current = Self.softBeat(at: now)
        }
        send(motion.frame(features: current, at: now, progress: progress(), isPlaying: true))
    }

    private func progress() -> Double {
        nowPlaying.snapshot?.progress(at: Date()) ?? 0
    }

    /// A gentle made-up beat every `softBeatPeriod` seconds.
    static func softBeat(at time: Double) -> AudioFeatures {
        AudioFeatures(
            energy: 0.45, bands: .zero, spectrum: .zero, onset: 0, beat: 0.4, beatPhase: 0,
            beatIndex: Int(time / softBeatPeriod), bpm: 0, tempoConfidence: 0, isSilent: false
        )
    }
}
