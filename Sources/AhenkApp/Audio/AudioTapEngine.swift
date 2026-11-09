import AhenkKit
import AppKit
import Observation

/// Listening, as the rest of the app sees it.
///
/// - ``store`` is where every consumer reads the audio features
///   (`currentFeatures()` / `features(at:)`: lock-free, any thread, every
///   frame). It is also `services.features`, so the now-playing model and
///   later steps get it from there.
/// - ``ticker`` calls UI code on the main thread at display rate, only
///   while there is something to show.
/// - ``permission`` and ``status`` drive Settings › Sound and the menu.
///
/// Live mode listens to the followed player's app through a Core Audio
/// process tap (``AudioCaptureController``); `--demo` and `--smoke` play
/// the demo beat through the same analysis instead, with no permission.
@MainActor
@Observable
final class AudioTapEngine {
    private(set) var permission: AudioCapturePermission = .unknown
    private(set) var status = AudioEngineStatus()

    @ObservationIgnored let store = AudioFeatureStore()
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private(set) lazy var ticker = AudioFeatureTicker(store: store)
    @ObservationIgnored private let controller: AudioCaptureController
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isRequesting = false
    private static let log = AhenkLogger(category: "audio")

    init(demo: DemoProvider?) {
        isDemo = demo != nil
        controller = AudioCaptureController(store: store, demo: demo)
    }

    // MARK: Lifecycle

    /// Follows the hub's player and starts listening when music plays.
    func start(hub: NowPlayingHub, settings: AppSettings) {
        guard !isStarted else { return }
        isStarted = true
        controller.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.status = status }
        }
        controller.setSensitivity(settings.audio.sensitivity)
        observers.append(ChangeObserver({ settings.audio.sensitivity }) { [weak self] sensitivity in
            self?.controller.setSensitivity(sensitivity)
        })
        let controller = self.controller
        tasks.append(Task.detached(priority: .userInitiated) {
            for await snapshot in hub.snapshots() {
                controller.update(snapshot: snapshot)
            }
        })
        tasks.append(Task.detached(priority: .userInitiated) {
            for await event in hub.events() {
                if case .trackChanged = event { controller.trackChanged() }
            }
        })
        refreshPermission()
        // The permission may change in System Settings while Ahenk waits.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        Self.log.info(isDemo ? "Audio: demo beat through the analyzer" : "Audio: process taps when music plays")
    }

    /// Tears the tap down (on quit).
    func stop() {
        guard isStarted else { return }
        isStarted = false
        tasks.forEach { $0.cancel() }
        tasks = []
        observers = []
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        controller.stop()
    }

    // MARK: Permission

    /// Reads the system-audio permission without any prompt.
    func refreshPermission() {
        Task { [weak self] in
            let permission = await Task.detached(priority: .utility) { SystemAudioPermission.status() }.value
            self?.apply(permission)
        }
    }

    /// "Allow Listening…": the only place that may make macOS ask.
    func requestPermission() {
        guard !isRequesting else { return }
        Self.log.notice("Asking macOS for system audio access (the user pressed Allow Listening)")
        if permission == .unknown || !SystemAudioPermission.canRequest {
            // macOS cannot be asked directly: listen, and building the tap
            // lets macOS ask by itself.
            controller.allowListening()
            return
        }
        isRequesting = true
        SystemAudioPermission.request { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.isRequesting = false
                Self.log.notice("System audio access \(granted ? "granted" : "not granted")")
                self.refreshPermission()
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(SystemAudioPermission.settingsURL)
    }

    private func apply(_ permission: AudioCapturePermission) {
        if permission != self.permission {
            Self.log.info("System audio access: \(permission.rawValue)")
        }
        self.permission = permission
        controller.update(permission: permission)
    }

    /// Lends the analysed audio to automatic lyrics sync for one window
    /// (`nil` takes it back). Nothing is recorded: the capture lives in
    /// memory until it has been measured.
    func listen(forLyrics capture: LyricsSyncCapture?) {
        controller.setLyricsCapture(capture)
    }

    /// The analysis hears the followed player itself (a tap on its
    /// processes, or the demo), not every app at once.
    var hearsFollowedPlayer: Bool {
        status.isRunning && (isDemo || status.processCount > 0)
    }

    /// True when the menu should offer "Allow Listening…".
    var needsPermission: Bool {
        !isDemo && (permission == .notDetermined || permission == .unknown)
    }
}
