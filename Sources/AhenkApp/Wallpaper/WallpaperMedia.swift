import AhenkKit
import AppKit
import AVFoundation
import QuartzCore

/// Why a candidate could not show.
enum WallpaperMediaFailure: Equatable {
    /// This video will not play (embedding disabled, removed, unreadable).
    case thisVideo(String)
    /// No video of this kind will play right now (offline, the embedded
    /// player refused the app's identity).
    case everyVideo(String)

    var detail: String {
        switch self {
        case .thisVideo(let text), .everyVideo(let text): text
        }
    }
}

/// One candidate on one display. Subclasses draw it; the controller adds it
/// to a display's stage, plays and pauses it, seeks it (the song's own
/// video) and lets it go.
@MainActor
class WallpaperMediaView: NSView {
    let candidate: WallpaperCandidate
    /// Called once, when there are frames to show.
    var onReady: (() -> Void)?
    var onFailure: ((WallpaperMediaFailure) -> Void)?
    private(set) var isReady = false
    private(set) var hasFailed = false

    init(candidate: WallpaperCandidate, frame: NSRect) {
        self.candidate = candidate
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WallpaperMediaView is never decoded")
    }

    /// The view takes no clicks (the window ignores them anyway).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPlaying(_ playing: Bool) {}
    /// Jumps to `seconds` (the song's own video, in step with the song).
    func seek(to seconds: TimeInterval) {}
    /// Loops on its own, or holds its last frame at the end.
    func setLoops(_ loops: Bool) {}
    /// The current position and length, when the media knows them.
    func position(_ answer: @escaping @MainActor (TimeInterval?, TimeInterval?) -> Void) { answer(nil, nil) }
    /// Resolution and frame rate for the power state.
    func apply(_ plan: WallpaperPowerPlan) {}
    /// Stops for good and lets everything go.
    func tearDown() {
        onReady = nil
        onFailure = nil
    }

    func markReady() {
        guard !isReady, !hasFailed else { return }
        isReady = true
        onReady?()
    }

    func fail(_ failure: WallpaperMediaFailure) {
        guard !hasFailed else { return }
        hasFailed = true
        onFailure?(failure)
    }
}

// MARK: - AVPlayer (motion artwork, web addresses, files)

/// One AVPlayer for one candidate, shared by every display that shows it
/// (one decode for all screens). Muted, never keeps the display awake,
/// never shown elsewhere (no AirPlay), never publishes Now Playing.
@MainActor
final class SharedVideoPlayer {
    let candidateID: String
    let player: AVQueuePlayer
    var loops = true
    var onFailure: ((WallpaperMediaFailure) -> Void)?
    /// Views showing it; released when the last one goes.
    var users = 0
    private let item: AVPlayerItem
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private let isFile: Bool

    init(candidate: WallpaperCandidate, url: URL, plan: WallpaperPowerPlan) {
        candidateID = candidate.id
        isFile = url.isFileURL
        let asset = AVURLAsset(url: url)
        item = AVPlayerItem(asset: asset)
        player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .none
        // A muted picture may stall for a moment; it should start quickly
        // and not buffer far ahead.
        player.automaticallyWaitsToMinimizeStalling = false
        item.preferredForwardBufferDuration = 4
        apply(plan)
        if isFile {
            // Seamless loops for files on this Mac.
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
        }
        failedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let failed = note.object as? AVPlayerItem, self.player.items().contains(failed) || failed === self.item else { return }
                self.onFailure?(.thisVideo("playback stopped"))
            }
        }
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            let failed = player.currentItem?.status == .failed
            let error = player.currentItem?.error?.localizedDescription ?? "unreadable"
            Task { @MainActor in
                guard failed, let self else { return }
                self.onFailure?(.thisVideo(error))
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        if playing {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
    }

    var currentTime: TimeInterval? {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    var duration: TimeInterval? {
        let seconds = player.currentItem?.duration.seconds ?? .nan
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    func apply(_ plan: WallpaperPowerPlan) {
        let side = CGFloat(plan.maximumVideoSide)
        for item in [item] + player.items() {
            item.preferredMaximumResolution = CGSize(width: side, height: side)
            item.preferredPeakBitRate = plan.peakBitRate
        }
    }

    func tearDown() {
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        endObserver = nil
        failedObserver = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        onFailure = nil
    }

    private func reachedEnd() {
        guard loops else { return }
        player.seek(to: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in self?.player.play() }
        }
    }
}

/// A display's view of a shared AVPlayer: one `AVPlayerLayer`, aspect-fill.
@MainActor
final class VideoPlayerMediaView: WallpaperMediaView {
    let shared: SharedVideoPlayer
    private let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    init(candidate: WallpaperCandidate, shared: SharedVideoPlayer, frame: NSRect) {
        self.shared = shared
        super.init(candidate: candidate, frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        playerLayer.frame = bounds
        playerLayer.player = shared.player
        layer?.addSublayer(playerLayer)
        shared.users += 1
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor in
                if ready { self?.markReady() }
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func setPlaying(_ playing: Bool) { shared.setPlaying(playing) }
    override func seek(to seconds: TimeInterval) { shared.seek(to: seconds) }
    override func setLoops(_ loops: Bool) { shared.loops = loops }
    override func apply(_ plan: WallpaperPowerPlan) { shared.apply(plan) }

    override func position(_ answer: @escaping @MainActor (TimeInterval?, TimeInterval?) -> Void) {
        answer(shared.currentTime, shared.duration)
    }

    override func tearDown() {
        super.tearDown()
        readyObservation = nil
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
        shared.users -= 1
    }
}
