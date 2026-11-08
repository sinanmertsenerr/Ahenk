import AhenkKit
import AppKit
import Metal
import QuartzCore

/// A thread with its own run loop. The edge light's display-link callbacks
/// and Metal encoding run here, so a busy main thread (Settings laying out
/// a form) never makes the light stutter.
final class RenderThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    /// Starts the thread and returns once its run loop accepts work.
    func launch() {
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive while no display link is attached.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
    }

    /// Runs `block` on the thread, in order.
    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Ends the thread after the work queued so far.
    func finish() {
        perform { [weak self] in
            self?.cancel()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}

/// What the main thread tells the render loop about one screen.
struct EdgeLightScreenState {
    var id: String
    var metrics: EdgeMetrics
    var look: LightLook
    /// Every strip's slot in the screen's atlas…
    var atlas: EdgeAtlas
    /// …and the layers that show them, in the same order.
    var layers: [CALayer]
    /// Frame rate and quality while visible.
    var plan: LightFramePlan
    var seed: Int32
    /// Enabled for this display and not stepping aside.
    var isAllowed: Bool
    /// The window is on screen and not covered.
    var isVisible: Bool

    var canDraw: Bool { isVisible && !plan.isPaused && !layers.isEmpty }
}

/// Draws every screen's edge light.
///
/// Each screen has a display link on the render thread. On every frame it
/// reads the audio features for the frame's target time (lock-free),
/// advances the shared motion, fades and colours, draws every strip of the
/// screen into one atlas surface in one render pass and, once the GPU is
/// done, shows it on all strip layers in one Core Animation transaction.
/// A screen stops its display link as soon as
/// it has nothing to show: the music has faded out, the screen stepped
/// aside, or its window is hidden. The main thread wakes it again with
/// `setMusic`, `preview` or a new screen state; nothing polls.
///
/// All state below the public methods lives on the render thread; the
/// public methods only queue work there.
final class EdgeLightRenderLoop: @unchecked Sendable {
    private final class LinkTarget: NSObject {
        weak var loop: EdgeLightRenderLoop?
        let id: String

        init(loop: EdgeLightRenderLoop, id: String) {
            self.loop = loop
            self.id = id
        }

        @objc func tick(_ link: CADisplayLink) {
            loop?.tick(link, id: id)
        }
    }

    private final class Target {
        var state: EdgeLightScreenState
        var link: CADisplayLink?
        var presence = LightFade.presence()
        var isRunning = false

        init(state: EdgeLightScreenState) {
            self.state = state
        }
    }

    private let thread = RenderThread(name: "Ahenk edge light")
    private let renderer: EdgeLightRenderer
    private let features: AudioFeatureSource
    private let onIdle: @MainActor (String) -> Void
    private let log = AhenkLogger(category: "light")

    // Render thread only.
    private var targets: [String: Target] = [:]
    /// Atlas surfaces per screen.
    private var rings: [String: SurfaceRing] = [:]
    private var music = LightFade.music()
    private var musicActive = false
    private var previewStart = 0.0
    private var previewUntil = -Double.infinity
    private var motion = LightMotion()
    private var colors: PaletteCrossfade
    private var isRainbow = false
    private var speed = 1.0
    private var sharedTime = -Double.infinity
    private var frameFeatures = AudioFeatures.silence
    private var frameColors: [SRGBColor]
    private var wasDrawing = false
    private var reportedFailure = false

    /// `onIdle` runs on the main thread when a screen has nothing left to
    /// draw and stopped its display link.
    init(renderer: EdgeLightRenderer, features: AudioFeatureSource, colors: LightColors, onIdle: @escaping @MainActor (String) -> Void) {
        self.renderer = renderer
        self.features = features
        self.onIdle = onIdle
        self.colors = PaletteCrossfade(colors)
        isRainbow = colors.isRainbow
        frameColors = colors.slots
        thread.launch()
    }

    // MARK: Main thread → render thread

    /// Adds or updates a screen. `link` replaces the screen's display link
    /// (a new screen, or the display was reconfigured); it must be paused
    /// and not yet scheduled.
    func update(_ state: EdgeLightScreenState, link: CADisplayLink?) {
        thread.perform { [self] in
            let target = targets[state.id] ?? Target(state: state)
            targets[state.id] = target
            target.state = state
            if let link {
                target.link?.invalidate()
                link.isPaused = true
                link.add(to: .current, forMode: .default)
                target.link = link
                target.isRunning = false
            }
            applyFrameRate(target)
            reevaluate(target)
            pruneRings()
        }
    }

    /// A display link for `screen`, paused, ready for ``update(_:link:)``.
    @MainActor
    func makeLink(for screen: NSScreen, id: String) -> CADisplayLink {
        let link = screen.displayLink(target: LinkTarget(loop: self, id: id), selector: #selector(LinkTarget.tick(_:)))
        link.isPaused = true
        return link
    }

    func remove(screenID: String) {
        thread.perform { [self] in
            targets[screenID]?.link?.invalidate()
            targets[screenID] = nil
            pruneRings()
        }
    }

    /// Music the light reacts to plays (or stopped).
    func setMusic(_ active: Bool) {
        thread.perform { [self] in
            musicActive = active
            targets.values.forEach(reevaluate)
        }
    }

    /// Shows the light for `seconds` even without music (a setting just
    /// changed), with the demo beat if nothing is heard.
    func preview(seconds: Double) {
        thread.perform { [self] in
            let now = AudioClock.now()
            if now >= previewUntil { previewStart = now }
            previewUntil = now + seconds
            targets.values.forEach(reevaluate)
        }
    }

    func setColors(_ new: LightColors) {
        thread.perform { [self] in
            colors.set(new, at: max(sharedTime, AudioClock.now() - 0.05))
            isRainbow = new.isRainbow
        }
    }

    func setSpeed(_ value: Double) {
        thread.perform { [self] in speed = value }
    }

    /// Stops every display link and the thread. The loop is unusable after.
    func shutDown() {
        thread.perform { [self] in
            for target in targets.values { target.link?.invalidate() }
            targets = [:]
            rings = [:]
        }
        thread.finish()
    }

    // MARK: Render thread

    private var wantsLight: Bool {
        musicActive || AudioClock.now() < previewUntil
    }

    private func applyFrameRate(_ target: Target) {
        guard let link = target.link else { return }
        let fps = Float(max(1, target.state.plan.framesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: max(10, fps / 2), maximum: fps, preferred: fps)
    }

    /// Starts or stops a screen's display link after something changed.
    private func reevaluate(_ target: Target) {
        music.set(on: wantsLight)
        target.presence.set(on: target.state.isAllowed)
        guard let link = target.link else { return }
        let needsFrames = target.state.canDraw && !music.isIdle && !target.presence.isIdle
        if needsFrames, !target.isRunning {
            if !targets.values.contains(where: \.isRunning) {
                // Nothing ran: the shared fade starts a new timeline.
                music.resetClock()
            }
            target.presence.resetClock()
            target.isRunning = true
            link.isPaused = false
            noteDrawing()
        } else if !target.state.canDraw, target.isRunning {
            // Hidden: nobody sees the fade, stop at once.
            target.isRunning = false
            link.isPaused = true
            noteDrawing()
        }
    }

    private func tick(_ link: CADisplayLink, id: String) {
        guard let target = targets[id], target.link === link, target.isRunning else {
            link.isPaused = true
            return
        }
        let time = link.targetTimestamp
        advanceShared(to: time)
        target.presence.advance(to: time)
        let opacity = music.value * target.presence.value
        draw(target, time: time, opacity: opacity)
        if music.isIdle || target.presence.isIdle {
            // The last frame drawn was empty: stop until woken.
            target.isRunning = false
            link.isPaused = true
            noteDrawing()
            let onIdle = self.onIdle
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onIdle(id) }
            }
        }
    }

    private func advanceShared(to time: Double) {
        guard time > sharedTime else { return }
        sharedTime = time
        let previewing = time < previewUntil
        music.set(on: musicActive || previewing)
        music.advance(to: time)
        var frame = features.features(at: time)
        if frame.isSilent, previewing, !musicActive {
            frame = DemoBeat.features(at: time - previewStart)
        }
        frameFeatures = frame
        motion.advance(to: time, features: frame, speed: speed)
        frameColors = colors.colors(at: time)
    }

    private func draw(_ target: Target, time: Double, opacity: Double) {
        let state = target.state
        let atlas = state.atlas
        if rings[state.id].map({ $0.width != atlas.width || $0.height != atlas.height }) ?? true {
            rings[state.id] = SurfaceRing(device: renderer.device, width: atlas.width, height: atlas.height)
        }
        // All three surfaces still on screen: keep the last frame.
        guard let (surface, texture) = rings[state.id]?.acquire(),
              let commands = renderer.queue.makeCommandBuffer()
        else { return }
        commands.label = "Edge light"
        let draws = atlas.slots.map { slot in
            (uniforms: EdgeLightUniforms(
                metrics: state.metrics, strip: slot.strip, pixelScale: atlas.scale, look: state.look,
                colors: frameColors, isRainbow: isRainbow, motion: motion, features: frameFeatures,
                time: time, opacity: opacity, quality: state.plan.quality, seed: state.seed, slot: slot
            ), slot: slot)
        }
        do {
            try renderer.encode(atlas: draws, into: texture, commandBuffer: commands)
        } catch {
            if !reportedFailure {
                reportedFailure = true
                log.error("Edge light: could not draw (\(error))")
            }
            return
        }
        commands.commit()
        // The window server must not show a half-drawn surface.
        commands.waitUntilCompleted()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in state.layers {
            layer.contents = surface
        }
        CATransaction.commit()
    }

    /// Forgets the surfaces of screens that are gone.
    private func pruneRings() {
        rings = rings.filter { targets[$0.key] != nil }
    }

    private func noteDrawing() {
        let drawing = targets.values.contains(where: \.isRunning)
        guard drawing != wasDrawing else { return }
        wasDrawing = drawing
        if drawing {
            let count = targets.values.filter(\.isRunning).count
            log.info("Edge light: drawing on \(count) screen(s)")
        } else {
            log.info("Edge light: stopped drawing")
        }
    }
}
