import AhenkKit
import AppKit
import QuartzCore

/// The window that carries one display's live wallpaper: borderless, just
/// above the desktop picture and below the desktop icons, on every Space,
/// left in place by Mission Control and Show Desktop, never clicked (clicks
/// reach the desktop as before). The user's own wallpaper setting is never
/// touched: melting back is this window fading out.
final class WallpaperWindow: NSWindow {
    /// The desktop picture's own level: above the system's wallpaper
    /// windows (which sit a little lower), below the icons.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    let content: WallpaperScreenView

    init(frame: CGRect) {
        content = WallpaperScreenView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = Self.level
        // Not on full-screen Spaces: an app there hides it (and it pauses).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        setAccessibilityElement(false)
        setAccessibilityRole(.unknown)
        contentView = content
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Covers the whole screen, menu bar and Dock included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The wallpaper's top edge, shown again right behind the menu bar. macOS
/// draws its own copy of the user's wallpaper there, in a window above the
/// desktop icons, so the wallpaper window (below the icons) cannot cover
/// it and the wallpaper would seem to start under the menu bar. This strip
/// sits just above that copy and shows the wallpaper window's own layers
/// live (`CALayerHost`, the render server's mirror of another window's
/// layer tree: no second player, no copying). Where the system does not
/// offer that, there is no strip and the menu bar looks as it did.
final class WallpaperMenuBarWindow: NSWindow {
    /// Above the system's strip behind the menu bar (one above the desktop
    /// icons), below the widgets.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    /// Nothing below the menu bar: desktop icons start right under it,
    /// and this window is above them (it would cut their tops off).
    static let reachBelowMenuBar: CGFloat = 0

    private var host: CALayer?
    private var hostedContext: UInt32 = 0
    /// Keeps the strip drawn afresh on every frame. The window server
    /// draws a window again only when its own layers change, and the
    /// mirrored ones belong to the wallpaper window: without this the
    /// strip kept the previous song's picture after a crossfade (until
    /// something else, a screenshot for one, made the screen draw again).
    /// An all but invisible layer over the whole strip whose opacity
    /// never rests does it, in the render server, at no cost to Ahenk.
    private let pulse = CALayer()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        setAccessibilityElement(false)
        setAccessibilityRole(.unknown)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.layer = CALayer()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.setAccessibilityElement(false)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows the top `height` points of `source` (a window that covers
    /// `screenFrame`) over the same place. `false`: nothing to mirror yet
    /// (the source has not been drawn) or no mirroring on this system.
    @discardableResult
    func mirror(_ source: NSWindow, screenFrame: CGRect, height: CGFloat) -> Bool {
        guard height > 0, let root = contentView?.layer,
              let context = source.contentView?.layer?.value(forKey: "context") as? NSObject,
              let contextID = context.value(forKey: "contextId") as? UInt32, contextID != 0,
              let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type
        else {
            orderOut(nil)
            return false
        }
        let frame = CGRect(x: screenFrame.minX, y: screenFrame.maxY - height, width: screenFrame.width, height: height)
        if self.frame != frame { setFrame(frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if host == nil || hostedContext != contextID {
            host?.removeFromSuperlayer()
            let made = hostClass.init()
            made.setValue(contextID, forKey: "contextId")
            made.anchorPoint = .zero
            root.addSublayer(made)
            host = made
            hostedContext = contextID
        }
        // The source's layers keep their own place: its top edge on ours.
        host?.position = CGPoint(x: 0, y: height - screenFrame.height)
        if pulse.superlayer == nil {
            pulse.backgroundColor = NSColor.black.cgColor
            pulse.opacity = 0.004
            pulse.zPosition = 10
            root.addSublayer(pulse)
        }
        pulse.frame = CGRect(x: 0, y: 0, width: frame.width, height: height)
        if pulse.animation(forKey: "pulse") == nil {
            let beat = CABasicAnimation(keyPath: "opacity")
            beat.fromValue = 0.004
            beat.toValue = 0.008
            beat.duration = 0.5
            beat.autoreverses = true
            beat.repeatCount = .infinity
            beat.isRemovedOnCompletion = false
            // A video has 24 to 30 pictures a second: drawing the strip
            // more often only makes the whole screen draw more often.
            beat.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            pulse.add(beat, forKey: "pulse")
        }
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
        return true
    }

    func hide() {
        if isVisible { orderOut(nil) }
        // Ordered out, the animation is dropped; `mirror` adds it again.
        pulse.removeAnimation(forKey: "pulse")
    }
}

/// One display's wallpaper: the media views stacked on `canvas` (the one in
/// front on top), a scrim over them for readability, all inside `stage`,
/// whose opacity melts the whole thing in and out. With blur on, the canvas
/// reaches past the screen's edges (and is clipped), so the blur's soft
/// edge is never seen.
final class WallpaperScreenView: NSView {
    /// Clips, and its opacity is the melt.
    let stage = NSView()
    /// Holds the media views; blurred as a whole.
    let canvas = NSView()
    private let scrim = CALayer()
    private let vignette = CAGradientLayer()
    private(set) var opacity: Double = 0
    private var blurMargin: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setAccessibilityElement(false)
        stage.frame = bounds
        stage.autoresizingMask = [.width, .height]
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.layer?.masksToBounds = true
        stage.layer?.opacity = 0
        addSubview(stage)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        canvas.layerUsesCoreImageFilters = true
        stage.addSubview(canvas)
        let actions: [String: CAAction] = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        scrim.actions = actions
        scrim.backgroundColor = NSColor.black.cgColor
        scrim.opacity = 0
        scrim.zPosition = 100
        vignette.actions = actions
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
        vignette.locations = [0.45, 1]
        vignette.zPosition = 101
        stage.layer?.addSublayer(scrim)
        stage.layer?.addSublayer(vignette)
        placeCanvas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WallpaperScreenView is never decoded")
    }

    override func layout() {
        super.layout()
        placeCanvas()
    }

    private func placeCanvas() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = stage.bounds
        vignette.frame = stage.bounds
        CATransaction.commit()
        let frame = stage.bounds.insetBy(dx: -blurMargin, dy: -blurMargin)
        if canvas.frame != frame { canvas.frame = frame }
        for media in canvas.subviews where media.frame != canvas.bounds {
            media.frame = canvas.bounds
        }
    }

    /// Fades the whole wallpaper to `value` (0: the user's own wallpaper).
    func setOpacity(_ value: Double, duration: TimeInterval) {
        guard value != opacity, let layer = stage.layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        opacity = value
        layer.opacity = Float(value)
        guard duration > 0 else {
            layer.removeAnimation(forKey: "melt")
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = Float(value)
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "melt")
    }

    /// Darkening (a scrim and a vignette that keeps the edge light and the
    /// widgets readable) and blur, from the settings.
    func setLook(dimming: Double, blur: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.opacity = Float(max(0, min(0.8, dimming)))
        let edge = dimming > 0 ? min(0.5, dimming * 1.6 + 0.1) : 0
        vignette.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(edge).cgColor]
        CATransaction.commit()
        let radius = max(0, min(1, blur)) * 28
        if radius < 0.5 {
            canvas.contentFilters = []
            blurMargin = 0
        } else if let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) {
            canvas.contentFilters = [filter]
            blurMargin = (radius * 2.5).rounded(.up)
        }
        placeCanvas()
    }

    /// Puts `media` on the canvas, under what shows.
    func host(_ media: WallpaperMediaView) {
        guard media.superview !== canvas else { return }
        media.frame = canvas.bounds
        media.autoresizingMask = [.width, .height]
        canvas.addSubview(media, positioned: .below, relativeTo: nil)
    }

    func bringToFront(_ media: WallpaperMediaView) {
        guard media.superview === canvas else { return }
        canvas.addSubview(media, positioned: .above, relativeTo: nil)
    }
}
