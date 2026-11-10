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
/// sits just above that copy and shows pictures of the wallpaper window's
/// own top edge, taken a few times a second.
///
/// It used to show the wallpaper window's layers live (`CALayerHost`).
/// Measured with a video playing, that made the window server draw the
/// whole screen again for every frame: 60 % of the GPU against 19 % with
/// no strip at all. Pictures of the edge cost next to nothing (20 % at one
/// a second, 22 % at fifteen).
final class WallpaperMenuBarWindow: NSWindow {
    /// Above the system's strip behind the menu bar (one above the desktop
    /// icons), below the widgets.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    /// Nothing below the menu bar: desktop icons start right under it,
    /// and this window is above them (it would cut their tops off).
    static let reachBelowMenuBar: CGFloat = 0
    /// Pictures a second while the wallpaper moves. The strip is a few
    /// dozen points high and lies behind the menu bar's own material.
    static let picturesPerSecond: Double = 10

    private let picture = CALayer()
    private var timer: Timer?
    private var sourceNumber: UInt32 = 0
    private var captureRect: CGRect = .zero
    private var failures = 0
    private var taken = 0
    private static let log = AhenkLogger(category: "wallpaper")

    /// The window server's picture of one window. The SDK no longer
    /// declares it (it points to ScreenCaptureKit, which asks for the
    /// screen recording permission even for the app's own windows); the
    /// function is still there and needs no permission for those.
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let capture: Capture? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: Capture.self)
    }()
    /// `kCGWindowListOptionIncludingWindow`.
    private static let onlyThisWindow: UInt32 = 1 << 3
    /// `kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution`.
    private static let imageOptions: UInt32 = (1 << 0) | (1 << 3)

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
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        picture.contentsGravity = .resize
        view.layer?.addSublayer(picture)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows the top `height` points of `source` (a window that covers
    /// `screenFrame`) over the same place. `false`: nothing to show yet
    /// (the source has not been drawn) or no pictures on this system.
    @discardableResult
    func mirror(_ source: NSWindow, screenFrame: CGRect, height: CGFloat) -> Bool {
        guard height > 0, source.windowNumber > 0, Self.capture != nil else {
            hide()
            return false
        }
        let frame = CGRect(x: screenFrame.minX, y: screenFrame.maxY - height, width: screenFrame.width, height: height)
        if self.frame != frame { setFrame(frame, display: false) }
        picture.frame = CGRect(x: 0, y: 0, width: frame.width, height: height)
        // The window list counts from the top of the first display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.maxY
        captureRect = CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY, width: screenFrame.width, height: height)
        sourceNumber = UInt32(source.windowNumber)
        // Asked again while it runs (every plan change): the timer's next
        // picture is soon enough.
        if timer != nil, isVisible { return true }
        guard refresh() else {
            hide()
            return false
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1 / Self.picturesPerSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if !isVisible { orderFrontRegardless() }
        return true
    }

    private func refresh() -> Bool {
        guard let capture = Self.capture, sourceNumber != 0,
              let image = capture(captureRect, Self.onlyThisWindow, sourceNumber, Self.imageOptions)?.takeRetainedValue(),
              image.width > 1, image.height > 1
        else {
            failures += 1
            if failures == 30 {
                Self.log.notice("No picture of the wallpaper's top edge; the menu bar shows the system's wallpaper")
                hide()
            }
            return false
        }
        if failures != 0 || picture.contents == nil {
            Self.log.info("Menu bar strip: pictures of the wallpaper's top edge (\(image.width)x\(image.height), mean colour \(Self.meanColour(of: image)))")
        }
        failures = 0
        taken += 1
        // Once more when the wallpaper has melted in (the first picture is
        // of a wallpaper that is still clear).
        if taken == 60 { Self.log.info("Menu bar strip: mean colour \(Self.meanColour(of: image)) after 60 pictures") }
        picture.contents = image
        return true
    }

    /// "r g b" (0–255) of the whole picture, for the log: a strip that
    /// came out black or empty shows here.
    private static func meanColour(of image: CGImage) -> String {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "?" }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return "\(pixel[0]) \(pixel[1]) \(pixel[2]), alpha \(pixel[3])"
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        picture.contents = nil
        if isVisible { orderOut(nil) }
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
