import AhenkKit
import AppKit
import Observation

/// The sound effects' switchboard: follows the player the hub follows and
/// applies `settings.effects` where that player's sound can be reached.
///
/// - **Ahenk's own player** (song files): the effects run inside the
///   player's audio chain (`LocalEffectsProcessor`), the speed is the
///   player's own rate.
/// - **Another app**: the audio capture's tap on that app is rebuilt muted
///   and Ahenk plays the app's sound through the effects (`ExternalEffects`).
///   A browser tab takes the speed through the extension; Apple Music,
///   Spotify and other apps have no speed, so there only the pitch moves.
/// - **The demo**: an invented player with nothing to hear; the effects
///   only show.
///
/// Whatever happens, no app is left muted: the effects are switched off
/// when another player is followed than the one they were switched on for,
/// the capture mutes only while Ahenk's output plays, and `stop()` (on
/// quit) takes everything back.
@MainActor
@Observable
final class SoundEffectsController {
    private(set) var route: SoundEffectRoute = .off
    private(set) var speedControl: SoundSpeedControl = .none
    /// The processed sound (or the changed speed) is what is heard now.
    private(set) var isApplied = false
    /// The effects engine for song files could not be made.
    private(set) var localFailure: String?

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private let audio: AudioTapEngine
    @ObservationIgnored private let localPlayer: LocalPlayer
    @ObservationIgnored private let bridge: BrowserBridgeServer?
    @ObservationIgnored private let external = ExternalEffects()
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var isStarted = false
    /// The player the effects were switched on for.
    @ObservationIgnored private var enabledFor: String?
    @ObservationIgnored private var localProcessor: LocalEffectsProcessor?
    @ObservationIgnored private var externalTarget: AudioTapTarget?
    @ObservationIgnored private var ratedTab: (key: String, rate: Double)?
    @ObservationIgnored private var rateWatch: Timer?
    @ObservationIgnored private var appliedDelay = 0.0
    private let log = AhenkLogger(category: "effects")

    init(settings: AppSettings, nowPlaying: NowPlayingModel, audio: AudioTapEngine, localPlayer: LocalPlayer, bridge: BrowserBridgeServer?) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.audio = audio
        self.localPlayer = localPlayer
        self.bridge = bridge
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let settings = self.settings
        let nowPlaying = self.nowPlaying
        let audio = self.audio
        external.onInterrupted = { [audio] in audio.effectsInterrupted() }
        observers.append(ChangeObserver({
            Inputs(
                effects: settings.effects, player: SoundEffectRouter.playerKey(nowPlaying.snapshot),
                instance: nowPlaying.snapshot?.instanceIdentifier, process: nowPlaying.snapshot?.processIdentifier,
                kind: nowPlaying.snapshot?.contentKind, permission: audio.permission,
                hearsEverything: audio.hearsEverything, playsEffects: audio.status.playsEffects
            )
        }) { [weak self] _ in
            self?.reconcile()
        })
        reconcile()
    }

    /// Takes every effect back and waits for nothing: the song files play
    /// at their own speed, the muted tap goes (the capture's own `stop()`
    /// removes it for good), a sped-up tab gets its speed back.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        observers = []
        applyLocal(nil)
        applyExternal(nil)
        applyTabRate(nil)
        route = .off
        isApplied = false
        updateDelay(.neutral)
    }

    private struct Inputs: Equatable {
        var effects: SoundEffectSettings
        var player: String?
        var instance: String?
        var process: Int32?
        var kind: ContentKind?
        var permission: AudioCapturePermission
        var hearsEverything: Bool
        var playsEffects: Bool
    }

    // MARK: For the UI

    func setEnabled(_ on: Bool) {
        settings.effects.enabled = on
    }

    func select(_ preset: SoundPreset) {
        settings.effects.select(preset)
        // Choosing a preset is asking for it.
        settings.effects.enabled = true
    }

    /// The chain that is asked for, as this player can carry it out.
    var chain: SoundEffectChain {
        SoundEffectChain(settings.effects).adapted(to: speedControl)
    }

    /// The speed in the settings cannot be given to this player.
    var speedIsIgnored: Bool {
        route.isAvailable && speedControl == .none && SoundEffectChain(settings.effects).changesSpeed
    }

    // MARK: Carrying it out

    private func reconcile() {
        guard isStarted else { return }
        let snapshot = nowPlaying.snapshot
        let key = SoundEffectRouter.playerKey(snapshot)
        if settings.effects.enabled {
            if SoundEffectRouter.mustSwitchOff(enabledFor: enabledFor, now: key) {
                // Effects belong to the player they were switched on for:
                // another player is never muted or sped up unasked.
                log.notice("Another player is followed; the sound effects are switched off")
                enabledFor = nil
                settings.effects.enabled = false
            } else if enabledFor == nil {
                enabledFor = key
            }
        } else {
            enabledFor = nil
        }
        let effects = settings.effects
        var tapsSupported = false
        if #available(macOS 14.2, *) { tapsSupported = true }
        let route = SoundEffectRouter.route(
            enabled: effects.enabled, snapshot: snapshot, permission: audio.permission, isDemo: audio.isDemo,
            tapsSupported: tapsSupported, hearsEverything: audio.hearsEverything
        )
        let tab = tabKey(of: snapshot)
        let control: SoundSpeedControl = route.isAvailable && route != .demo
            ? SoundEffectRouter.speedControl(for: snapshot, tabTakesRate: tab != nil)
            : .none
        let chain = SoundEffectChain(effects).adapted(to: control)
        if route != self.route {
            log.info("Sound effects: \(Self.describe(route))")
        }
        self.route = route
        speedControl = control

        switch route {
        case .ownPlayer:
            applyExternal(nil)
            applyTabRate(nil)
            applyLocal(chain)
            isApplied = localProcessor != nil || chain.changesSpeed
        case .tap(let target):
            applyLocal(nil)
            applyExternal(chain.processesSound ? (target, chain) : nil)
            applyTabRate(control == .browserTab && chain.changesSpeed ? tab.map { ($0, chain.speed) } : nil)
            isApplied = audio.status.playsEffects || ratedTab != nil
        case .demo:
            applyLocal(nil)
            applyExternal(nil)
            applyTabRate(nil)
            isApplied = !chain.isNeutral
        case .off, .unavailable:
            applyLocal(nil)
            applyExternal(nil)
            applyTabRate(nil)
            isApplied = false
        }
        updateDelay(chain)
    }

    /// The pitch stage holds the sound back; the light waits as long.
    private func updateDelay(_ chain: SoundEffectChain) {
        var delay = 0.0
        if let processor = localProcessor, processor.includesPitch {
            delay = Double(EffectsGraph.pitchDelayFrames) / (processor.sampleRate * max(0.25, localPlayer.speed))
        } else if case .tap = route, audio.status.playsEffects, chain.shiftsPitch, audio.status.sampleRate > 0 {
            delay = Double(EffectsGraph.pitchDelayFrames) / audio.status.sampleRate
        }
        guard delay != appliedDelay else { return }
        appliedDelay = delay
        audio.setEffectsDelay(delay)
    }

    /// The tab that plays, when its extension can change its speed.
    private func tabKey(of snapshot: NowPlayingSnapshot?) -> String? {
        guard let bridge, let snapshot, let instance = snapshot.instanceIdentifier else { return nil }
        let tab = bridge.currentTabs.first { $0.tabID == instance }
        return tab?.bridgeCapabilities.contains(.rate) == true ? instance : nil
    }

    // MARK: Ahenk's own player

    private func applyLocal(_ chain: SoundEffectChain?) {
        guard let chain else {
            if localPlayer.speed != 1 { localPlayer.setSpeed(1) }
            removeLocalProcessor()
            rateWatch?.invalidate()
            rateWatch = nil
            localFailure = nil
            return
        }
        localPlayer.setSpeed(chain.speed)
        guard chain.processesSound else {
            removeLocalProcessor()
            return
        }
        installLocalProcessor(chain)
        // A song file at another sample rate needs another engine; the
        // player says so only on its audio thread, so look now and then.
        if rateWatch == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followLocalRate() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            rateWatch = timer
        }
    }

    private func installLocalProcessor(_ chain: SoundEffectChain) {
        let rate = localPlayer.tap.sampleRate
        guard rate > 0 else { return }
        // The pitch stage is part of an engine or not (it delays the sound):
        // moving the pitch from or to zero takes another engine.
        if let processor = localProcessor, processor.sampleRate == rate, processor.includesPitch == chain.shiftsPitch {
            processor.apply(chain)
            return
        }
        removeLocalProcessor()
        do {
            let processor = try LocalEffectsProcessor(
                sampleRate: rate, maximumFrames: max(4096, localPlayer.tap.framesPerBuffer), includesPitch: chain.shiftsPitch
            )
            processor.apply(chain)
            localProcessor = processor
            localPlayer.tap.effectsHook.storePointer(UnsafeMutableRawPointer(processor.context), at: 0)
            localFailure = nil
            log.notice("Sound effects run in Ahenk's own player (\(Int(rate)) Hz)")
        } catch {
            localFailure = String(describing: error)
            log.error("The effects engine for song files could not be made: \(error)")
        }
    }

    private func removeLocalProcessor() {
        guard let processor = localProcessor else { return }
        localPlayer.tap.effectsHook.storePointer(nil, at: 0)
        localProcessor = nil
        // The audio thread may still be inside the buffer it had in hand.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = processor }
    }

    private func followLocalRate() {
        guard isStarted, route == .ownPlayer else { return }
        let chain = self.chain
        guard chain.processesSound else { return }
        let before = localProcessor != nil
        installLocalProcessor(chain)
        if before != (localProcessor != nil) { isApplied = localProcessor != nil || chain.changesSpeed }
        updateDelay(chain)
    }

    // MARK: Other apps

    private func applyExternal(_ wanted: (target: AudioTapTarget, chain: SoundEffectChain)?) {
        guard let wanted else {
            guard externalTarget != nil else { return }
            externalTarget = nil
            audio.setEffects(nil, for: nil)
            external.set(.neutral)
            return
        }
        external.set(wanted.chain)
        let isSameApp = externalTarget?.source == wanted.target.source && externalTarget?.bundleIdentifier == wanted.target.bundleIdentifier
        guard !isSameApp else { return }
        externalTarget = wanted.target
        audio.setEffects(external, for: wanted.target)
    }

    private func applyTabRate(_ wanted: (key: String, rate: Double)?) {
        let previous = ratedTab
        guard previous?.key != wanted?.key || previous?.rate != wanted?.rate else { return }
        ratedTab = wanted
        guard let bridge else { return }
        Task { [log] in
            if let previous, previous.key != wanted?.key {
                // The tab that was sped up gets the song's own speed back.
                _ = await bridge.setRate(1, forTab: previous.key)
            }
            if let wanted {
                let done = await bridge.setRate(wanted.rate, forTab: wanted.key)
                log.info("Asked the tab to play at \(String(format: "%.2f", wanted.rate))×: \(done ? "done" : "refused")")
            }
        }
    }

    private static func describe(_ route: SoundEffectRoute) -> String {
        switch route {
        case .off: "off"
        case .ownPlayer: "in Ahenk's own player"
        case .tap(let target): "through a muting tap on \(target)"
        case .demo: "shown for the demo (nothing to hear)"
        case .unavailable(let obstacle): "not possible (\(obstacle.rawValue))"
        }
    }
}
