import AhenkKit
import AppKit
import QuartzCore

/// The borderless, transparent window that carries one screen's light:
/// click-through, just below the Dock and the menu bar (above every normal
/// window), on every Space, left in place by Mission Control.
final class EdgeLightWindow: NSWindow {
    /// Right below the Dock: over every app window, under the Dock, the
    /// menu bar, menus and alerts' own levels above them.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = Self.level
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        setAccessibilityElement(false)
        setAccessibilityRole(.unknown)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        // Layer-hosting: AppKit leaves the layer tree to us.
        view.layer = CALayer()
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        contentView = view
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Covers the whole screen, menu bar and Dock included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Full-screen Spaces show the light only when it should not step aside.
    func setShowsOverFullScreenApps(_ shows: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if shows { behavior.insert(.fullScreenAuxiliary) }
        if collectionBehavior != behavior { collectionBehavior = behavior }
    }
}

/// One strip of a screen's light: a plain layer that shows its slot of the
/// screen's atlas (the render loop swaps the atlas surface every frame, see
/// ``SurfaceRing``).
final class EdgeLightStrip {
    let place: EdgeStrip.Place
    let layer = CALayer()

    init(place: EdgeStrip.Place) {
        self.place = place
        layer.isOpaque = false
        layer.contentsGravity = .resize
        layer.needsDisplayOnBoundsChange = false
        layer.actions = [
            "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
            "contentsRect": NSNull(), "transform": NSNull(), "hidden": NSNull(),
        ]
    }

    /// Puts the layer over its strip and points it at its slot; a turned
    /// slot is turned back a quarter. Call inside a transaction without
    /// actions.
    func show(_ slot: EdgeAtlasSlot, of atlas: EdgeAtlas) {
        layer.setAffineTransform(.identity)
        layer.contentsScale = CGFloat(atlas.scale)
        layer.bounds = CGRect(origin: .zero, size: slot.layerSize)
        layer.position = CGPoint(x: slot.strip.midX, y: slot.strip.midY)
        if slot.isRotated {
            layer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
        }
        layer.contentsRect = slot.contentsRect(atlasWidth: atlas.width, atlasHeight: atlas.height)
    }
}

/// One screen's light window and its strips. Main thread only; the render
/// loop draws into the strips' layers from its own thread.
@MainActor
final class EdgeLightOverlay {
    private(set) var screen: LightScreen
    let window: EdgeLightWindow
    private(set) var strips: [EdgeLightStrip] = []
    /// Where every strip lives in the atlas the render loop draws.
    private(set) var atlas = EdgeAtlas(strips: [], scale: 1)
    /// The window shows on the current Space and nothing covers it.
    private(set) var isVisible = true
    /// Called when the window becomes visible or hidden (occlusion, sleep,
    /// another Space).
    var onVisibilityChange: ((Bool) -> Void)?
    private var occlusion: NSObjectProtocol?

    init(screen: LightScreen) {
        self.screen = screen
        window = EdgeLightWindow(frame: screen.frame)
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
    }

    var isShown: Bool { window.isVisible }

    /// The display moved or changed resolution.
    func update(screen: LightScreen) {
        self.screen = screen
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    /// Lays out the strips for `layout`, drawn at `resolutionScale` of the
    /// display's backing scale into one atlas. Reuses layers by place.
    func layout(_ layout: [EdgeStrip], resolutionScale: Double) {
        guard let root = window.contentView?.layer else { return }
        let scale = max(1, screen.backingScale * CGFloat(resolutionScale))
        let atlas = EdgeAtlas(strips: layout, scale: Double(scale))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var next: [EdgeLightStrip] = []
        for slot in atlas.slots {
            let strip = strips.first { $0.place == slot.place } ?? EdgeLightStrip(place: slot.place)
            strip.show(slot, of: atlas)
            if strip.layer.superlayer == nil { root.addSublayer(strip.layer) }
            next.append(strip)
        }
        self.atlas = atlas
        for old in strips where !next.contains(where: { $0 === old }) {
            old.layer.removeFromSuperlayer()
        }
        strips = next
        CATransaction.commit()
    }

    /// Drops the layers and their drawables (the light is off for good).
    func removeStrips() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strips.forEach { $0.layer.removeFromSuperlayer() }
        strips = []
        atlas = EdgeAtlas(strips: [], scale: 1)
        CATransaction.commit()
    }

    /// Orders the window in. Its occlusion state lags behind for a moment;
    /// the notification that follows says whether it is really visible.
    func show() {
        guard !window.isVisible else { return }
        window.orderFrontRegardless()
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
    }

    func close() {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        removeStrips()
        window.orderOut(nil)
        window.close()
    }

    private func occlusionChanged() {
        // An ordered-out window reports "not visible"; that is not a
        // reason to stop, the window is about to be shown.
        let visible = !window.isVisible || window.occlusionState.contains(.visible)
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange?(visible)
    }
}
