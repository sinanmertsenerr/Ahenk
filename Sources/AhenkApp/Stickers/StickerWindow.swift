import AhenkKit
import AppKit
import QuartzCore

/// A sticker's window: at the widgets' level (above the desktop icons and
/// the live wallpaper, below app windows), on every Space, never active.
/// Square, so the sticker turns inside it without resizing.
final class StickerWindow: NSPanel {
    let stickerID: UUID

    init(stickerID: UUID, frame: CGRect) {
        self.stickerID = stickerID
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = false
        level = DesktopWidgetWindow.level
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        isMovable = false
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    var stickerView: StickerView? { contentView as? StickerView }
}

/// What a gesture changed: the sticker's centre (screen points), width and turn.
struct StickerEdit: Equatable {
    var center: CGPoint
    var width: Double
    var rotation: Double
}

/// Shows one sticker and lets the pointer move it (drag it anywhere on it),
/// resize it (the corner handle, the scroll wheel, a pinch) and turn it
/// (the handle above it, Option with the scroll wheel, a two-finger
/// rotation). The handles show while the pointer is over the sticker.
/// Right-click opens the controller's menu.
final class StickerView: NSView {
    /// While a gesture runs, and once when it ends (to be saved).
    var onChange: ((StickerEdit) -> Void)?
    var onEnd: ((StickerEdit) -> Void)?
    var makeMenu: (() -> NSMenu?)?
    /// The largest width allowed on this screen.
    var clampWidth: ((Double) -> Double)?

    private(set) var stickerWidth: Double
    private(set) var aspect: Double
    private(set) var rotation: Double
    private var picture: CGImage?
    /// The bordered picture is this much larger than the sticker.
    private var pictureScale: Double = 1

    private let content = CALayer()
    private let imageLayer = CALayer()
    private let resizeHandle = CAShapeLayer()
    private let rotateHandle = CAShapeLayer()
    private let rotateStem = CAShapeLayer()
    private var hideHandles: DispatchWorkItem?
    private var gesture: Gesture?
    private var pendingEnd: DispatchWorkItem?

    private enum Gesture {
        case move(mouse: CGPoint, origin: CGPoint)
        case resize(startDistance: Double, startWidth: Double)
        case rotate(startAngle: Double, startRotation: Double)
    }

    static let handleRadius: CGFloat = 7
    static let stemLength: CGFloat = 16

    init(width: Double, aspect: Double, rotation: Double) {
        stickerWidth = width
        self.aspect = aspect
        self.rotation = rotation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        content.masksToBounds = false
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        imageLayer.shadowOpacity = 0.32
        imageLayer.shadowRadius = 6
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)
        for handle in [resizeHandle, rotateHandle] {
            handle.fillColor = CGColor(gray: 1, alpha: 0.96)
            handle.strokeColor = CGColor(gray: 0, alpha: 0.35)
            handle.lineWidth = 1
            handle.shadowOpacity = 0.25
            handle.shadowRadius = 2
            handle.shadowOffset = .zero
        }
        rotateStem.strokeColor = CGColor(gray: 1, alpha: 0.85)
        rotateStem.lineWidth = 1.5
        content.addSublayer(imageLayer)
        content.addSublayer(rotateStem)
        content.addSublayer(resizeHandle)
        content.addSublayer(rotateHandle)
        layer?.addSublayer(content)
        setHandlesVisible(false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StickerView is never decoded")
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The picture as shown (with or without its border).
    func setPicture(_ image: CGImage?, scale: Double) {
        picture = image
        pictureScale = max(1, scale)
        imageLayer.contents = image
        layoutContent()
    }

    func apply(width: Double, aspect: Double, rotation: Double) {
        stickerWidth = width
        self.aspect = aspect
        self.rotation = rotation
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private var stickerSize: CGSize { CGSize(width: stickerWidth, height: stickerWidth * aspect) }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = stickerSize
        let shown = CGSize(width: size.width * pictureScale, height: size.height * pictureScale)
        content.bounds = CGRect(x: -shown.width / 2, y: -shown.height / 2, width: shown.width, height: shown.height)
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        content.setAffineTransform(CGAffineTransform(rotationAngle: rotation))
        imageLayer.frame = content.bounds
        let r = Self.handleRadius
        let corner = CGPoint(x: shown.width / 2, y: -shown.height / 2)
        resizeHandle.path = CGPath(ellipseIn: CGRect(x: corner.x - r, y: corner.y - r, width: 2 * r, height: 2 * r), transform: nil)
        let top = CGPoint(x: 0, y: shown.height / 2 + Self.stemLength)
        rotateHandle.path = CGPath(ellipseIn: CGRect(x: top.x - r + 1, y: top.y - r + 1, width: 2 * r - 2, height: 2 * r - 2), transform: nil)
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 0, y: shown.height / 2))
        stem.addLine(to: CGPoint(x: 0, y: top.y - r + 1))
        rotateStem.path = stem
        CATransaction.commit()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved() }
    override func mouseMoved(with event: NSEvent) { pointerMoved() }

    override func mouseExited(with event: NSEvent) {
        guard gesture == nil else { return }
        scheduleHide(after: 0.35)
    }

    private func pointerMoved() {
        setHandlesVisible(true, animated: true)
        // Transparent parts pass the pointer on, so "exited" may never come.
        scheduleHide(after: 2.2)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideHandles?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.gesture == nil else { return }
            self.setHandlesVisible(false, animated: true)
        }
        hideHandles = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setHandlesVisible(_ visible: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        for handle in [resizeHandle, rotateHandle, rotateStem] {
            handle.opacity = visible ? 1 : 0
        }
        CATransaction.commit()
    }

    var handlesVisible: Bool { resizeHandle.opacity > 0.5 }

    // MARK: Hit testing

    /// The point in the unturned sticker's frame (origin at its centre).
    private func unturned(_ point: CGPoint) -> CGPoint {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(-rotation), s = sin(-rotation)
        return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
    }

    private enum Part { case body, resize, rotate }

    private func part(at point: CGPoint) -> Part? {
        let p = unturned(point)
        let size = stickerSize
        let shown = CGSize(width: size.width * pictureScale, height: size.height * pictureScale)
        let grab = Self.handleRadius + 4
        if handlesVisible {
            if hypot(p.x - shown.width / 2, p.y + shown.height / 2) <= grab { return .resize }
            if hypot(p.x, p.y - (shown.height / 2 + Self.stemLength)) <= grab { return .rotate }
        }
        if abs(p.x) <= shown.width / 2, abs(p.y) <= shown.height / 2 { return .body }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return part(at: local) == nil ? nil : self
    }

    // MARK: Gestures

    private var centerOnScreen: CGPoint {
        guard let window else { return .zero }
        return CGPoint(x: window.frame.midX, y: window.frame.midY)
    }

    override func mouseDown(with event: NSEvent) {
        pendingEnd?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let mouse = NSEvent.mouseLocation
        let center = centerOnScreen
        switch part(at: point) {
        case .resize:
            gesture = .resize(startDistance: max(4, hypot(mouse.x - center.x, mouse.y - center.y)), startWidth: stickerWidth)
        case .rotate:
            gesture = .rotate(startAngle: atan2(mouse.y - center.y, mouse.x - center.x), startRotation: rotation)
        case .body:
            gesture = .move(mouse: mouse, origin: window?.frame.origin ?? .zero)
        case nil:
            gesture = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture, let window else { return }
        let mouse = NSEvent.mouseLocation
        switch gesture {
        case .move(let start, let origin):
            window.setFrameOrigin(CGPoint(x: (origin.x + mouse.x - start.x).rounded(), y: (origin.y + mouse.y - start.y).rounded()))
        case .resize(let startDistance, let startWidth):
            let center = centerOnScreen
            let width = startWidth * hypot(mouse.x - center.x, mouse.y - center.y) / startDistance
            resize(to: width)
        case .rotate(let startAngle, let startRotation):
            let center = centerOnScreen
            let angle = atan2(mouse.y - center.y, mouse.x - center.x)
            rotation = StickerGeometry.snappedRotation(startRotation + angle - startAngle)
            layoutContent()
        }
        onChange?(edit)
    }

    override func mouseUp(with event: NSEvent) {
        guard gesture != nil else { return }
        gesture = nil
        onEnd?(edit)
        scheduleHide(after: 1.5)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.option) {
            rotation = StickerGeometry.normalizedRotation(rotation + Double(delta) * 0.01)
            layoutContent()
        } else {
            resize(to: stickerWidth * (1 + Double(delta) * 0.006))
        }
        onChange?(edit)
        endSoon()
    }

    override func magnify(with event: NSEvent) {
        resize(to: stickerWidth * (1 + Double(event.magnification)))
        onChange?(edit)
        endSoon()
    }

    override func rotate(with event: NSEvent) {
        rotation = StickerGeometry.normalizedRotation(rotation + Double(event.rotation) * .pi / 180)
        layoutContent()
        onChange?(edit)
        endSoon()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?()
    }

    /// Saves a scroll or a pinch once it has settled.
    private func endSoon() {
        pendingEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onEnd?(self.edit)
        }
        pendingEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// A new width, the window growing or shrinking around the same centre.
    private func resize(to width: Double) {
        let clamped = clampWidth?(width) ?? Sticker.clampedWidth(width)
        guard abs(clamped - stickerWidth) > 0.25, let window else { return }
        let center = centerOnScreen
        stickerWidth = clamped
        let frame = StickerGeometry.windowFrame(center: center, size: CGSize(width: clamped * pictureScale, height: clamped * aspect * pictureScale))
        window.setFrame(frame, display: true)
        layoutContent()
    }

    var edit: StickerEdit {
        StickerEdit(center: centerOnScreen, width: stickerWidth, rotation: rotation)
    }

    // MARK: Offscreen

    /// The sticker drawn into a bitmap (the smoke check), as it shows.
    func snapshot() -> NSBitmapImageRep? {
        layoutSubtreeIfNeeded()
        layoutContent()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        bitmap.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.cgContext.clear(CGRect(origin: .zero, size: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)))
        layer?.render(in: context.cgContext)
        context.flushGraphics()
        return bitmap
    }
}
