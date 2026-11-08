import AhenkKit
import AppKit
import Observation

/// Runs the edge light: one overlay window per screen, the render loop, and
/// every input that decides whether, where and how the light shines:
///
/// - the settings (Settings › Edge Light, the menu bar's Edge Light switch,
///   Optimized Mode and "run lighter on battery" in General);
/// - the music: the followed player plays music, or the analysis hears it;
/// - the cover's palette, crossfaded when the song changes;
/// - power (battery, Low Power Mode, heat) for the frame rate and quality;
/// - screens coming and going, their notch and resolution;
/// - what is in front ("only on the desktop", full-screen apps);
/// - each window's visibility (occlusion, sleep, another Space).
///
/// Changing how the light looks while nothing plays shows it for a few
/// seconds with the demo beat, so the change can be seen.
@MainActor
@Observable
final class EdgeLightController {
    enum Status: Equatable, CustomStringConvertible {
        case off
        case starting
        case waitingForMusic
        case glowing(LightFramePlan.Reason)
        /// Every display is off or steps aside right now.
        case steppedAside
        /// The shader could not be compiled (no Metal device, missing file).
        case unavailable

        var description: String {
            switch self {
            case .off: "off"
            case .starting: "starting"
            case .waitingForMusic: "waiting for music"
            case .glowing(let reason): "glowing (\(reason.rawValue))"
            case .steppedAside: "stepped aside"
            case .unavailable: "unavailable"
            }
        }
    }

    private struct PowerInputs: Equatable, Sendable {
        var optimizedMode: Bool
        var lighterOnBattery: Bool
        var isOnBattery: Bool
        var isLowPowerMode: Bool
        var isHot: Bool
    }

    private(set) var status: Status = .off
    /// What the light is drawn with now (the Settings previews use it too).
    private(set) var colors = LightColors(colors: Palette.neutral.vivid)

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private let features: AudioFeatureStore
    @ObservationIgnored private let power: PowerMonitor
    @ObservationIgnored private let desktop = DesktopWatcher()
    @ObservationIgnored private var loop: EdgeLightRenderLoop?
    @ObservationIgnored private var overlays: [String: EdgeLightOverlay] = [:]
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var activity: AudioActivityObservation?
    @ObservationIgnored private var lastLight: LightSettings
    @ObservationIgnored private var isPlayingMusic = false
    @ObservationIgnored private var featuresActive = false
    @ObservationIgnored private var albumPalette: Palette?
    @ObservationIgnored private var previewUntil = Date.distantPast
    @ObservationIgnored private var pendingPreview = false
    @ObservationIgnored private var previewEnd: DispatchWorkItem?
    @ObservationIgnored private var teardown: DispatchWorkItem?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isUnavailable = false
    private static let log = AhenkLogger(category: "light")

    /// How long a changed setting shows the light when nothing plays.
    static let previewSeconds = 3.5

    init(settings: AppSettings, nowPlaying: NowPlayingModel, features: AudioFeatureStore, power: PowerMonitor) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.features = features
        self.power = power
        lastLight = settings.light
        status = settings.light.enabled ? .starting : .off
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let settings = self.settings
        let nowPlaying = self.nowPlaying
        let power = self.power
        observers.append(ChangeObserver({ settings.light }) { [weak self] light in
            self?.lightChanged(light)
        })
        observers.append(ChangeObserver({
            PowerInputs(
                optimizedMode: settings.general.optimizedMode, lighterOnBattery: settings.general.lighterOnBattery,
                isOnBattery: power.isOnBattery, isLowPowerMode: power.isLowPowerMode, isHot: power.isThermallyConstrained
            )
        }) { [weak self] _ in
            self?.refreshScreens()
        })
        observers.append(ChangeObserver({ Self.playsMusic(nowPlaying.snapshot) }) { [weak self] playing in
            self?.isPlayingMusic = playing
            self?.musicChanged()
        })
        observers.append(ChangeObserver({ nowPlaying.artwork?.identifier }) { [weak self] _ in
            self?.artworkChanged()
        })
        activity = features.observeActivity { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                self.featuresActive = active
                self.musicChanged()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreens() }
        }
        desktop.onChange = { [weak self] in self?.refreshScreens() }
        desktop.start()

        isPlayingMusic = Self.playsMusic(nowPlaying.snapshot)
        featuresActive = features.isActive
        albumPalette = nowPlaying.artwork?.palette
        colors = resolveColors()
        if settings.light.enabled {
            startLight()
        }
        updateStatus()
    }

    /// Closes every window and stops drawing (on quit).
    func stop() {
        guard isStarted else { return }
        isStarted = false
        observers = []
        activity = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        desktop.stop()
        previewEnd?.cancel()
        teardown?.cancel()
        tearDownLight()
    }

    // MARK: Light on and off

    private func startLight() {
        teardown?.cancel()
        teardown = nil
        if loop != nil {
            rebuildScreens()
            return
        }
        guard !isUnavailable else { return }
        EdgeLightShader.shared.load { [weak self] renderer in
            guard let self, self.isStarted else { return }
            guard let renderer else {
                self.isUnavailable = true
                self.updateStatus()
                return
            }
            guard self.settings.light.enabled, self.loop == nil else { return }
            self.loop = EdgeLightRenderLoop(renderer: renderer, features: self.features, colors: self.colors) { [weak self] id in
                self?.screenWentIdle(id)
            }
            self.loop?.setSpeed(self.settings.light.speed)
            self.loop?.setMusic(self.musicActive)
            self.rebuildScreens()
            if self.pendingPreview {
                self.pendingPreview = false
                self.preview()
            }
        }
    }

    /// Fades every screen out quickly, then closes the windows.
    private func stopLight() {
        guard loop != nil else {
            tearDownLight()
            return
        }
        refreshScreens()
        teardown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.settings.light.enabled else { return }
            self.tearDownLight()
            self.updateStatus()
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func tearDownLight() {
        loop?.shutDown()
        loop = nil
        overlays.values.forEach { $0.close() }
        overlays = [:]
    }

    // MARK: Inputs

    private func lightChanged(_ light: LightSettings) {
        let old = lastLight
        lastLight = light
        guard light.enabled else {
            if old.enabled { Self.log.info("Edge light off") }
            stopLight()
            updateStatus()
            return
        }
        if !old.enabled {
            Self.log.info("Edge light on")
            startLight()
            preview()
            updateStatus()
            return
        }
        loop?.setSpeed(light.speed)
        if old.colorSource != light.colorSource || old.customColors != light.customColors {
            updateColors()
        }
        refreshScreens()
        let looksDifferent = old.style != light.style || old.position != light.position || old.thickness != light.thickness
            || old.glow != light.glow || old.intensity != light.intensity || old.speed != light.speed
            || old.colorSource != light.colorSource || old.customColors != light.customColors
            || old.disabledDisplays != light.disabledDisplays
        if looksDifferent, !musicActive {
            preview()
        }
    }

    private var musicActive: Bool { isPlayingMusic || featuresActive }

    private var wantsLight: Bool { musicActive || Date() < previewUntil }

    private func musicChanged() {
        if musicActive { showAllowedOverlays() }
        loop?.setMusic(musicActive)
        updateStatus()
    }

    /// Music the light reacts to plays (not a video, a podcast or an advert).
    static func playsMusic(_ snapshot: NowPlayingSnapshot?) -> Bool {
        guard let snapshot, snapshot.isPlaying else { return false }
        return AudioCapturePolicy.reactsTo(snapshot)
    }

    private func artworkChanged() {
        // Between songs the cover is briefly missing: keep the last palette.
        if let palette = nowPlaying.artwork?.palette { albumPalette = palette }
        updateColors()
    }

    private func resolveColors() -> LightColors {
        LightColors.resolve(source: settings.light.colorSource, album: albumPalette, custom: settings.light.customColors)
    }

    private func updateColors() {
        let next = resolveColors()
        guard next != colors else { return }
        colors = next
        loop?.setColors(next)
    }

    /// Shows the light for a few seconds even without music.
    private func preview() {
        guard settings.light.enabled else { return }
        guard let loop else {
            pendingPreview = true
            return
        }
        previewUntil = Date().addingTimeInterval(Self.previewSeconds)
        showAllowedOverlays()
        loop.preview(seconds: Self.previewSeconds)
        previewEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.updateStatus() }
        previewEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewSeconds + 0.1, execute: end)
        updateStatus()
    }

    // MARK: Screens

    private func rebuildScreens() {
        guard let loop, settings.light.enabled else { return }
        let current = LightScreen.current()
        let ids = Set(current.map(\.0.id))
        for (id, overlay) in overlays where !ids.contains(id) {
            overlay.close()
            overlays[id] = nil
            loop.remove(screenID: id)
        }
        for (screen, nsScreen) in current {
            let overlay: EdgeLightOverlay
            if let existing = overlays[screen.id] {
                overlay = existing
                overlay.update(screen: screen)
            } else {
                overlay = EdgeLightOverlay(screen: screen)
                overlay.onVisibilityChange = { [weak self, weak overlay] _ in
                    guard let self, let overlay else { return }
                    self.configure(overlay)
                }
                overlays[screen.id] = overlay
            }
            configure(overlay, link: loop.makeLink(for: nsScreen, id: screen.id))
        }
        Self.log.info("Edge light on \(current.count) screen(s): \(current.map { "\($0.0.name) \(Int($0.0.frame.width))×\(Int($0.0.frame.height))\($0.0.shape.notch == nil ? "" : ", notch")" }.joined(separator: "; "))")
        updateStatus()
    }

    private func refreshScreens() {
        for overlay in overlays.values {
            configure(overlay)
        }
        updateStatus()
    }

    private func frameInputs(for screen: LightScreen) -> LightFrameInputs {
        LightFrameInputs(
            optimizedMode: settings.general.optimizedMode, lighterOnBattery: settings.general.lighterOnBattery,
            isOnBattery: power.isOnBattery, isLowPowerMode: power.isLowPowerMode,
            isThermallyConstrained: power.isThermallyConstrained, isVisible: true,
            maximumFramesPerSecond: screen.maximumFramesPerSecond
        )
    }

    /// Enabled on this display and not stepping aside.
    private func isAllowed(_ screen: LightScreen) -> Bool {
        let light = settings.light
        guard light.isEnabled(onDisplay: screen.id) else { return false }
        if light.onlyOnDesktop, !desktop.isDesktopInFront { return false }
        if light.stepAsideInFullScreen, desktop.fullScreenDisplays.contains(screen.displayID) { return false }
        return true
    }

    /// Hands one screen's current state to the render loop.
    private func configure(_ overlay: EdgeLightOverlay, link: CADisplayLink? = nil) {
        guard let loop else { return }
        let light = settings.light
        let screen = overlay.screen
        let look = LightLook(settings: light)
        let metrics = EdgeMetrics(shape: screen.shape, band: look.band)
        let plan = LightFramePolicy.plan(frameInputs(for: screen))
        overlay.window.setShowsOverFullScreenApps(!light.stepAsideInFullScreen)
        overlay.layout(EdgeLayout.strips(for: metrics, position: look.position), resolutionScale: plan.resolutionScale)
        let allowed = isAllowed(screen)
        if allowed, wantsLight { overlay.show() }
        loop.update(
            EdgeLightScreenState(
                id: screen.id, metrics: metrics, look: look,
                atlas: overlay.atlas, layers: overlay.strips.map(\.layer), plan: plan, seed: screen.seed,
                isAllowed: allowed && light.enabled, isVisible: overlay.isVisible
            ),
            link: link
        )
    }

    private func showAllowedOverlays() {
        for overlay in overlays.values where isAllowed(overlay.screen) {
            overlay.show()
        }
    }

    /// The render loop finished a fade-out on a screen and stopped drawing
    /// there; take the window off the screen unless it is wanted again.
    private func screenWentIdle(_ id: String) {
        guard let overlay = overlays[id] else { return }
        if !(wantsLight && isAllowed(overlay.screen) && settings.light.enabled) {
            overlay.hide()
        }
        updateStatus()
    }

    // MARK: Status

    private func updateStatus() {
        let next: Status
        if !settings.light.enabled {
            next = .off
        } else if isUnavailable {
            next = .unavailable
        } else if loop == nil {
            next = .starting
        } else if !wantsLight {
            next = .waitingForMusic
        } else if let screen = overlays.values.map(\.screen).first(where: isAllowed) {
            next = .glowing(LightFramePolicy.plan(frameInputs(for: screen)).reason)
        } else {
            next = .steppedAside
        }
        guard next != status else { return }
        status = next
        Self.log.info("Edge light: \(next)")
    }
}
