import AhenkKit
import AppKit
import QuartzCore
import SwiftUI

/// A miniature screen showing one edge light style live, for the style
/// gallery in Settings › Edge Light.
///
/// Redraws itself through ``LightPreviewClock`` (never through SwiftUI),
/// only while its window is on screen and it is scrolled into view, at one
/// pixel per point. Clicks go to the SwiftUI button around it.
final class LightPreviewView: NSView {
    var style: LightStyle {
        didSet { if style != oldValue { needsFrame = true } }
    }

    /// The light's own layer; its contents are the newest frame.
    let lightLayer = CALayer()
    fileprivate var ring: SurfaceRing?
    fileprivate var needsFrame = true
    private var occlusion: NSObjectProtocol?

    init(style: LightStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 75))
        let root = CALayer()
        root.backgroundColor = NSColor(srgbRed: 0.09, green: 0.1, blue: 0.13, alpha: 1).cgColor
        layer = root
        wantsLayer = true
        lightLayer.isOpaque = false
        lightLayer.contentsGravity = .resize
        lightLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        root.addSublayer(lightLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LightPreviewView is never decoded")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lightLayer.frame = bounds
        CATransaction.commit()
        needsFrame = true
        LightPreviewClock.shared.drawSoon(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRegistration() }
            }
        }
        updateRegistration()
        LightPreviewClock.shared.drawSoon(self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRegistration()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRegistration()
    }

    private func updateRegistration() {
        if let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor {
            LightPreviewClock.shared.add(self)
        } else {
            LightPreviewClock.shared.remove(self)
        }
    }

    /// Scrolled into view (the gallery sits in a scrolling form).
    var isInView: Bool {
        window != nil && !visibleRect.isEmpty && bounds.width >= 8 && bounds.height >= 8
    }
}

/// Drives every visible style preview from one display link at 30 fps. Runs
/// only while at least one preview is on screen; uses the app's shared edge
/// light renderer; moves with the music, or with the demo beat while
/// nothing plays.
@MainActor
final class LightPreviewClock: NSObject {
    static let shared = LightPreviewClock()

    private var views: [ObjectIdentifier: Weak] = [:]
    private var link: CADisplayLink?
    private var motion = LightMotion()
    private let start = AudioClock.now()
    private var pending: [Weak] = []

    private struct Weak {
        weak var view: LightPreviewView?
    }

    /// Previews are a fraction of a screen: thinner lines, smaller particles.
    static let scale = 0.35
    static let framesPerSecond: Float = 30

    func add(_ view: LightPreviewView) {
        views[ObjectIdentifier(view)] = Weak(view: view)
        startIfNeeded()
    }

    func remove(_ view: LightPreviewView) {
        views[ObjectIdentifier(view)] = nil
        if views.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    /// Draws `view` once soon, even if it is not animating (a first frame
    /// for a window that is not visible yet, a new style).
    func drawSoon(_ view: LightPreviewView) {
        let scheduled = !pending.isEmpty
        pending.append(Weak(view: view))
        guard !scheduled else { return }
        EdgeLightShader.shared.load { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let views = self.pending.compactMap(\.view)
                self.pending = []
                self.render(views, at: AudioClock.now())
            }
        }
    }

    private func startIfNeeded() {
        guard link == nil, !views.isEmpty else { return }
        EdgeLightShader.shared.load { [weak self] renderer in
            guard let self, renderer != nil, self.link == nil, !self.views.isEmpty else { return }
            guard let screen = self.views.values.compactMap({ $0.view?.window?.screen }).first ?? NSScreen.main else { return }
            let link = screen.displayLink(target: self, selector: #selector(self.tick(_:)))
            let fps = Self.framesPerSecond
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        views = views.filter { $0.value.view != nil }
        guard !views.isEmpty else {
            link.invalidate()
            self.link = nil
            return
        }
        render(views.values.compactMap(\.view), at: link.targetTimestamp)
    }

    private func render(_ targets: [LightPreviewView], at time: Double) {
        guard let renderer = EdgeLightShader.shared.renderer, let environment = AppEnvironment.current else { return }
        let settings = environment.settings.light
        var features = environment.audio.store.features(at: time)
        if features.isSilent {
            features = DemoBeat.features(at: time - start)
        }
        motion.advance(to: time, features: features, speed: settings.speed)
        let colors = environment.light.colors
        guard let commands = renderer.queue.makeCommandBuffer() else { return }
        commands.label = "Edge light previews"
        var frames: [(CALayer, IOSurface)] = []
        for view in targets where view.isInView || view.needsFrame {
            let size = view.bounds.size
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            guard width >= 8, height >= 8 else { continue }
            if view.ring.map({ $0.width != width || $0.height != height }) ?? true {
                view.ring = SurfaceRing(device: renderer.device, width: width, height: height, count: 2)
            }
            guard let (surface, texture) = view.ring?.acquire() else { continue }
            var light = settings
            light.style = view.style
            let look = LightLook(settings: light, scale: Self.scale)
            let shape = EdgeShape(width: Double(size.width), height: Double(size.height), corners: .all(7))
            let metrics = EdgeMetrics(shape: shape, band: look.band)
            let uniforms = EdgeLightUniforms(
                metrics: metrics, strip: CGRect(origin: .zero, size: size), pixelScale: Double(width) / Double(size.width),
                look: look, colors: colors.slots, isRainbow: colors.isRainbow, motion: motion, features: features,
                time: time, opacity: 1, quality: .full, seed: Int32(view.style.shaderIndex)
            )
            guard (try? renderer.encode(uniforms, into: texture, commandBuffer: commands)) != nil else { continue }
            frames.append((view.lightLayer, surface))
            view.needsFrame = false
        }
        guard !frames.isEmpty else { return }
        commands.commit()
        commands.waitUntilCompleted()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, surface) in frames { layer.contents = surface }
        CATransaction.commit()
    }
}

/// SwiftUI wrapper for one preview.
struct LightPreview: NSViewRepresentable {
    let style: LightStyle

    func makeNSView(context: Context) -> LightPreviewView {
        LightPreviewView(style: style)
    }

    func updateNSView(_ view: LightPreviewView, context: Context) {
        view.style = style
    }
}
