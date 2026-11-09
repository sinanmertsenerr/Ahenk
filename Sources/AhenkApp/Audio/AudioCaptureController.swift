import AhenkKit
import CoreAudio
import Foundation

/// What Settings and the menu show about listening.
struct AudioEngineStatus: Equatable, Sendable {
    var state: AudioCaptureState = .idle
    /// A process tap or the demo synthesizer feeds the analysis.
    var isRunning = false
    /// Process objects in the running tap (0 for a tap on everything).
    var processCount = 0
    var sampleRate: Double = 0
    /// Seconds the features wait for the output (Bluetooth headphones).
    var presentationDelay: Double = 0
    var lastFailure: String?
    /// The analysis hears Ahenk's own player (song files), from inside.
    var isOwnPlayback = false
    /// The sound effects are on for the tapped app: its own sound is muted
    /// and Ahenk plays it, processed.
    var playsEffects = false
}

/// Carries out ``AudioCapturePolicy``: builds, retargets and tears down the
/// process tap (or the demo feed) and runs the analysis pump.
///
/// Two serial queues and nothing else:
/// - **control**: the policy, every HAL call (tap, aggregate device,
///   listeners) and the grace/backoff timer;
/// - **analysis**: a 100 Hz pump, only while a tap or the demo runs, that
///   drains the ring into the analyzer and publishes to the store.
/// The tap's IOProc runs on Core Audio's own real-time thread. While nothing
/// plays there is no tap, no timer and no listener.
///
/// Sound effects for another app (``setEffects(_:for:)``): the tap on that
/// app is built muted and its stereo sound goes to the effects' output,
/// which is started first and stopped last, so the app is never silent
/// without Ahenk playing it. What may be muted is `SoundEffectTapRule`'s
/// decision: one app's processes, never the tap on everything.
final class AudioCaptureController: @unchecked Sendable {
    let pipeline: AudioAnalysisPipeline
    /// Called on the control queue when the status changes.
    var onStatus: ((AudioEngineStatus) -> Void)?

    private let demo: DemoProvider?
    /// Ahenk's own player's audio (the Local source), when there is one.
    private let ownAudio: OwnAudioTap?
    private let control = DispatchQueue(label: "com.sinanmertsener.Ahenk.audio.control", qos: .userInitiated)
    private let analysis = DispatchQueue(label: "com.sinanmertsener.Ahenk.audio.analysis", qos: .userInteractive)
    private let ownPID = getpid()
    private let log = AhenkLogger(category: "audio")

    // Control queue.
    private var policy: AudioCapturePolicy
    private var session: AnyObject?
    private var built: (request: AudioTapRequest, scope: TapScope?)?
    /// The sound effects and the app they were asked for.
    private var effects: (sink: EffectsTapSink, target: AudioTapTarget)?
    /// The sink that plays the running (muted) tap's sound.
    private var playingSink: EffectsTapSink?
    /// Whether the running tap was built for the effects' wish as it is now
    /// (a tap that could not be muted is not rebuilt over and over).
    private var builtForEffects = false
    /// When the effects' output was last interrupted (see `effectsInterrupted`).
    private var interruptions: [Double] = []
    /// The player the running analysis belongs to; a new tap for the same
    /// player keeps the analysis (and its tempo) going.
    private var analysisTarget: AudioTapTarget?
    private var appliedGeneration = 0
    private var deadline: DispatchSourceTimer?
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var pendingHardwareChange: DispatchWorkItem?
    private var forceRebuild = false
    private var status = AudioEngineStatus()
    private var isStopped = false

    // Analysis queue.
    private var pump: DispatchSourceTimer?
    private var demoFeed: DemoAudioFeed?
    private var ownPacer: OwnAudioPacer?
    /// What the features wait for the output, and what they wait on top
    /// for the sound effects (their pitch stage holds the sound back).
    private var baseDelay = 0.0
    private var effectsDelay = 0.0
    private var ticks = 0
    private var lastSamplesAt = 0.0
    private var stallReported = false

    init(store: AudioFeatureStore, demo: DemoProvider?, ownAudio: OwnAudioTap? = nil) {
        self.demo = demo
        self.ownAudio = ownAudio
        pipeline = AudioAnalysisPipeline(store: store)
        policy = AudioCapturePolicy(requiresPermission: demo == nil)
    }

    // MARK: Inputs (any thread)

    func update(snapshot: NowPlayingSnapshot?) {
        control.async { [self] in
            policy.update(snapshot: snapshot, now: AudioClock.now())
            apply()
        }
    }

    func update(permission: AudioCapturePermission) {
        control.async { [self] in
            policy.update(permission: permission, now: AudioClock.now())
            apply()
        }
    }

    /// The user allowed listening while macOS could not tell the state.
    func allowListening() {
        control.async { [self] in
            policy.allowListening(now: AudioClock.now())
            apply()
        }
    }

    /// A new song: the tempo starts over.
    func trackChanged() {
        analysis.async { [pipeline] in pipeline.resetTempo() }
    }

    func setSensitivity(_ sensitivity: Double) {
        analysis.async { [pipeline] in pipeline.sensitivity = Float(sensitivity) }
    }

    /// The sound effects hold the sound back by this long: the features
    /// wait as much, so the light stays with what is heard.
    func setEffectsDelay(_ seconds: Double) {
        analysis.async { [self] in
            effectsDelay = seconds.isFinite ? max(0, seconds) : 0
            pipeline.presentationDelay = baseDelay + effectsDelay
        }
    }

    /// Automatic lyrics sync listens along with the analysis (`nil` stops).
    func setLyricsCapture(_ capture: LyricsSyncCapture?) {
        analysis.async { [pipeline] in pipeline.lyricsCapture = capture }
    }

    /// Sound effects for `target`'s sound (`nil` ends them): the tap on that
    /// app is rebuilt muted with its sound handed to `sink`, or rebuilt
    /// unmuted.
    func setEffects(_ sink: EffectsTapSink?, for target: AudioTapTarget?) {
        control.async { [self] in
            if let sink, let target {
                effects = (sink, target)
            } else {
                effects = nil
            }
            interruptions = []
            guard !isStopped, wantsEffects != builtForEffects || (playingSink != nil && playingSink !== effects?.sink) else { return }
            if session != nil { forceRebuild = true }
            apply()
        }
    }

    /// The effects' output stopped by itself (a new output device): build
    /// the tap again, and the output with it.
    func effectsInterrupted() {
        control.async { [self] in
            guard !isStopped, playingSink != nil else { return }
            // An output that keeps stopping must not keep an app muted on
            // and off: after three times in ten seconds the app gets its
            // own sound back until the effects are asked for again.
            let now = AudioClock.now()
            interruptions = interruptions.filter { now - $0 < 10 } + [now]
            if interruptions.count >= 3 {
                log.error("The effects' output keeps being interrupted; the app keeps its own sound")
                effects = nil
            } else {
                log.notice("The effects' output was interrupted; building the tap again")
            }
            forceRebuild = true
            apply()
        }
    }

    /// The effects are asked for the app the running tap hears.
    private var wantsEffects: Bool {
        guard let built, case .processes = built.scope else { return false }
        return SoundEffectTapRule.wantsMute(request: built.request, tapsProcesses: true, effectsFor: effects?.target)
    }

    /// Takes the lyrics capture back before it is full and says when the
    /// analysis has let go of it (only then may its samples be read).
    func endLyricsCapture(then completion: @escaping @Sendable () -> Void) {
        analysis.async { [pipeline] in
            pipeline.lyricsCapture = nil
            completion()
        }
    }

    /// Tears everything down and waits for it (on quit).
    func stop() {
        control.sync {
            isStopped = true
            deadline?.cancel()
            deadline = nil
            pendingHardwareChange?.cancel()
            teardown()
        }
        analysis.sync {}
    }

    // MARK: Carrying out the policy (control queue)

    private func apply() {
        guard !isStopped else { return }
        // Carrying out a request can change it (no process found yet, a
        // failure), so settle it in a few rounds.
        for _ in 0..<4 {
            let before = (policy.request, policy.resolveGeneration)
            carryOut()
            if policy.request == before.0, policy.resolveGeneration == before.1 { break }
        }
        let gate = policy.isGateOpen
        analysis.async { [pipeline] in pipeline.setGate(open: gate, at: AudioClock.now()) }
        scheduleDeadline()
        report()
    }

    private func carryOut() {
        let now = AudioClock.now()
        let request = policy.request
        appliedGeneration = policy.resolveGeneration
        if forceRebuild {
            forceRebuild = false
            // A new output: a new aggregate device, the same analysis.
            if session != nil { stopTap() }
        }
        switch request {
        case nil:
            if built != nil || !listeners.isEmpty {
                log.info("Stopped listening")
                teardown()
            }
        case .demo:
            guard built?.request != .demo else { return }
            teardownSession()
            startDemo(now: now)
        case .own(let target):
            guard built?.request != request else { return }
            teardownSession()
            startOwn(target, now: now)
        case .app(let target):
            guard let scope = resolve(target) else {
                // The app's audio process may still be starting: watch the
                // process list; the policy falls back after a moment.
                if built?.request != request, built != nil { teardownSession() }
                installListeners()
                policy.noteUnresolved(now: now)
                return
            }
            policy.noteResolved(now: now)
            if let built, built.request == .app(target), built.scope == scope, wantsEffects == builtForEffects { return }
            build(.app(target), scope: scope, now: now)
        case .everything(let target):
            let scope = TapScope.everythingExcept(ahenkObjects())
            if let built, built.request == .everything(target), built.scope == scope { return }
            build(.everything(target), scope: scope, now: now)
        }
    }

    private func resolve(_ target: AudioTapTarget) -> TapScope? {
        let processes = CoreAudioQueries.processes()
        let matched = AudioProcessMatcher.processes(
            for: target, appPIDs: CoreAudioQueries.appPIDs(target.bundleIdentifier), in: processes, ownPID: ownPID
        )
        guard !matched.isEmpty else { return nil }
        return .processes(matched.map(\.objectID).sorted())
    }

    private func ahenkObjects() -> [AudioObjectID] {
        var objects = Set(AudioProcessMatcher.ahenkProcesses(in: CoreAudioQueries.processes(), ownPID: ownPID).map(\.objectID))
        if let own = CoreAudioQueries.processObject(of: ownPID) { objects.insert(own) }
        return objects.sorted()
    }

    private func build(_ request: AudioTapRequest, scope: TapScope, now: Double) {
        // Same player, new processes or a new output: swap the tap only.
        let keepsAnalysis = analysisTarget != nil && analysisTarget == request.target
        stopTap()
        if !keepsAnalysis { stopAnalysis() }
        guard #available(macOS 14.2, *) else {
            status.lastFailure = "process taps need macOS 14.2"
            stopAnalysis()
            policy.noteTapFailed(now: now)
            return
        }
        // Sound effects for this app: Ahenk's output plays first, then the
        // tap mutes the app. Without the output the tap stays unmuted.
        var tapsProcesses = false
        if case .processes = scope { tapsProcesses = true }
        var stereo: AudioRingBuffer?
        var sink: EffectsTapSink?
        let clockRate = CoreAudioQueries.clockDevice().flatMap(CoreAudioQueries.nominalSampleRate(of:))
        if SoundEffectTapRule.wantsMute(request: request, tapsProcesses: tapsProcesses, effectsFor: effects?.target),
           let effects, let clockRate, let ring = effects.sink.startOutput(sampleRate: clockRate) {
            stereo = ring
            sink = effects.sink
        }
        do {
            var session = try ProcessTapSession(
                scope: scope, ring: pipeline.ring,
                effects: SoundEffectTapRule.mutes(request: request, tapsProcesses: tapsProcesses, effectsFor: effects?.target, outputRuns: stereo != nil) ? stereo : nil
            )
            if session.isMuted, session.sampleRate != clockRate {
                // The output plays at another rate than the tap delivers:
                // the app keeps its own sound.
                log.notice("The tap runs at \(Int(session.sampleRate)) Hz, not the output's rate; no effects for this app")
                session.stop()
                sink?.stopOutput()
                sink = nil
                session = try ProcessTapSession(scope: scope, ring: pipeline.ring)
            }
            if !session.isMuted, let unused = sink {
                unused.stopOutput()
                sink = nil
            }
            playingSink = sink
            self.session = session
            built = (request, scope)
            builtForEffects = wantsEffects
            status.lastFailure = nil
            policy.noteTapStarted(now: now)
            startAnalysis(sampleRate: session.sampleRate, delay: session.outputLatency, feed: nil, target: request.target)
            installListeners()
            let what: String
            switch scope {
            case .processes(let objects): what = "\(request.target?.description ?? "?") (\(objects.count) process\(objects.count == 1 ? "" : "es"))"
            case .everythingExcept: what = "every app but Ahenk (for \(request.target?.description ?? "?"))"
            }
            let mode = session.isMuted ? ", muted and played with effects" : ""
            log.notice("Listening to \(what), \(Int(session.sampleRate)) Hz, output latency \(Int(session.outputLatency * 1000)) ms, clock \(session.clockDeviceUID)\(mode)")
        } catch {
            sink?.stopOutput()
            playingSink = nil
            built = nil
            builtForEffects = false
            stopAnalysis()
            status.lastFailure = String(describing: error)
            log.error("Could not start listening to \(request.target?.description ?? "?"): \(error)")
            policy.noteTapFailed(now: now)
        }
    }

    private func startDemo(now: Double) {
        guard let demo else { return }
        built = (.demo, nil)
        policy.noteTapStarted(now: now)
        startAnalysis(sampleRate: DemoAudioFeed.sampleRate, delay: 0, feed: DemoAudioFeed(provider: demo), target: nil)
        log.info("Listening to the demo beat")
    }

    /// Ahenk's own player: no tap, its audio comes from inside Ahenk and is
    /// paced into the analysis like a tap's.
    private func startOwn(_ target: AudioTapTarget, now: Double) {
        guard let ownAudio else {
            status.lastFailure = "no player of Ahenk's own to listen to"
            policy.noteTapFailed(now: now)
            return
        }
        built = (.own(target), nil)
        policy.noteTapStarted(now: now)
        let rate = ownAudio.analysisRate > 0 ? ownAudio.analysisRate : 44_100
        let pacer = OwnAudioPacer(source: ownAudio.ring)
        pacer.reset()
        startAnalysis(sampleRate: rate, delay: Self.ownDelay(ownAudio), feed: nil, target: target, own: pacer)
        log.notice("Listening to Ahenk's own player (\(Int(rate)) Hz, \(Int(Self.ownDelay(ownAudio) * 1000)) ms ahead of the sound)")
    }

    /// How long the analysed audio waits for the sound: the player's lead
    /// over what is heard, less what the pacer keeps waiting.
    private static func ownDelay(_ ownAudio: OwnAudioTap) -> Double {
        max(0, ownAudio.measuredLead - OwnAudioPacer.targetBacklog)
    }

    /// Stops the tap (or the demo feed's slot) but leaves the analysis.
    private func stopTap() {
        if #available(macOS 14.2, *), let tap = session as? ProcessTapSession {
            tap.stop()
        }
        session = nil
        built = nil
        builtForEffects = false
        // The app has its own sound back (the tap is gone); only now does
        // Ahenk stop playing it.
        playingSink?.stopOutput()
        playingSink = nil
    }

    /// Stops the pump and publishes silence.
    private func stopAnalysis() {
        analysisTarget = nil
        analysis.async { [self] in
            pump?.cancel()
            pump = nil
            demoFeed = nil
            ownPacer = nil
            pipeline.stop(at: AudioClock.now())
        }
    }

    private func teardownSession() {
        stopTap()
        stopAnalysis()
    }

    private func teardown() {
        teardownSession()
        removeListeners()
    }

    // MARK: Analysis (analysis queue)

    private func startAnalysis(sampleRate: Double, delay: Double, feed: DemoAudioFeed?, target: AudioTapTarget?, own: OwnAudioPacer? = nil) {
        let gate = policy.isGateOpen
        analysisTarget = target
        analysis.async { [self] in
            pipeline.configure(sampleRate: sampleRate)
            baseDelay = delay
            pipeline.presentationDelay = delay + effectsDelay
            pipeline.setGate(open: gate, at: AudioClock.now())
            demoFeed = feed
            ownPacer = own
            lastSamplesAt = AudioClock.now()
            stallReported = false
            guard pump == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: analysis)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            pump = timer
        }
    }

    private func tick() {
        let now = AudioClock.now()
        demoFeed?.render(until: now, into: pipeline.ring.writer)
        if let ownPacer, let ownAudio {
            // A song file with another rate, or another speed: the analysis
            // follows it.
            let rate = ownAudio.analysisRate
            if rate > 0, rate != pipeline.analyzer?.sampleRate {
                pipeline.configure(sampleRate: rate)
                ownPacer.reset()
            }
            ownPacer.pump(until: now, sampleRate: rate, into: pipeline.ring.writer)
            baseDelay = Self.ownDelay(ownAudio)
            pipeline.presentationDelay = baseDelay + effectsDelay
        }
        if pipeline.ring.availableSamples > 0 { lastSamplesAt = now }
        pipeline.pump(now: now)
        ticks += 1
        guard ticks % 50 == 0 else { return }
        // Twice a second: a tap that only delivers zeros while music plays
        // is on the wrong process; one that delivers nothing has died.
        let silence = pipeline.digitalSilence
        if silence >= 2.9, pipeline.isGateOpen {
            control.async { [self] in
                policy.noteDigitalSilence(silence, now: AudioClock.now())
                apply()
            }
        }
        if now - lastSamplesAt > 2, !stallReported {
            stallReported = true
            control.async { [self] in
                guard session != nil else { return }
                log.notice("The tap stopped delivering audio; rebuilding it")
                teardownSession()
                policy.noteTapFailed(now: AudioClock.now())
                apply()
            }
        }
    }

    // MARK: Hardware changes (control queue)

    private func installListeners() {
        guard listeners.isEmpty, demo == nil else { return }
        let selectors = [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyServiceRestarted,
        ]
        for selector in selectors {
            var address = CoreAudioQueries.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.hardwareChanged(selector) }
            if AudioObjectAddPropertyListenerBlock(CoreAudioQueries.system, &address, control, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func removeListeners() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(CoreAudioQueries.system, &address, control, block)
        }
        listeners = []
    }

    /// Debounced: the process list changes in bursts.
    private func hardwareChanged(_ selector: AudioObjectPropertySelector) {
        if selector != kAudioHardwarePropertyProcessObjectList {
            // A new output (headphones, AirPods) or a restarted audio server
            // needs a new aggregate device.
            forceRebuild = true
        }
        pendingHardwareChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        pendingHardwareChange = work
        control.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Timers and status (control queue)

    private func scheduleDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let at = policy.nextDeadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + max(0, at - AudioClock.now()) + 0.01)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            policy.tick(now: AudioClock.now())
            apply()
        }
        timer.resume()
        deadline = timer
    }

    private func report() {
        var next = status
        next.state = policy.state
        next.isRunning = built != nil
        switch built?.scope {
        case .processes(let objects): next.processCount = objects.count
        default: next.processCount = 0
        }
        if case .own = built?.request {
            next.isOwnPlayback = true
            next.sampleRate = ownAudio?.analysisRate ?? 0
            next.presentationDelay = ownAudio.map(Self.ownDelay) ?? 0
        } else {
            next.isOwnPlayback = false
        }
        if #available(macOS 14.2, *), let tap = session as? ProcessTapSession {
            next.sampleRate = tap.sampleRate
            next.presentationDelay = tap.outputLatency
        } else if !next.isOwnPlayback {
            next.sampleRate = built?.request == .demo ? DemoAudioFeed.sampleRate : 0
            next.presentationDelay = 0
        }
        next.playsEffects = playingSink != nil
        guard next != status else { return }
        status = next
        onStatus?(next)
    }
}
