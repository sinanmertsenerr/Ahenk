import AhenkKit
import AppKit
import SwiftUI

/// A desktop widget's window: borderless and transparent, just above the
/// desktop icons and below every app window, on every Space, left in place
/// by Mission Control and Show Desktop.
///
/// It never activates Ahenk: clicks reach the controls while the app in
/// front stays in front (a non-activating panel whose views accept the
/// first click). Only a window with a text field (the player's search) may
/// become key, and only when that field is clicked.
final class DesktopWidgetWindow: NSPanel {
    /// Just above the desktop icons, the system's strip behind the menu
    /// bar (one above the icons) and the wallpaper's own strip over that
    /// (``WallpaperMenuBarWindow``); app windows (level 0) stay on top.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)

    /// `nil` for the queue panel, which moves with the player.
    let widget: DesktopWidget?
    /// The search field may take the keyboard.
    var allowsKeyboard = false

    init(widget: DesktopWidget?, frame: CGRect) {
        self.widget = widget
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Panels hide when their app is not in front unless told otherwise;
        // Ahenk is almost never in front.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Before the level: changing this resets the level to normal.
        isFloatingPanel = false
        level = Self.level
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        isMovable = false
        // Clicks reach the window only where it has paint (its glass and
        // controls); clear margins pass them on to the desktop. Setting
        // `ignoresMouseEvents` at all would turn that off.
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Widgets may sit anywhere on their screen, under the menu bar too.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Gives the keyboard back: the field loses focus and the app the user
    /// works in gets its key window back.
    func releaseKeyboard() {
        makeFirstResponder(nil)
        if isKeyWindow { resignKey() }
    }
}

/// Hosts a widget's SwiftUI content: the first click on an inactive
/// desktop widget acts at once (no "click to focus first"), and the window
/// keeps the size the controller gives it.
final class DesktopHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DesktopHostingView is never decoded")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Buttons and lists never take the keyboard; the search field (an
    /// AppKit text field inside) asks for it itself.
    override var needsPanelToBecomeKey: Bool { false }
}

/// Moves a widget's window with the pointer. Views report a drag's start,
/// moves and end; the window follows `NSEvent.mouseLocation` (screen
/// points), so moving the window under the gesture never makes it jitter.
@MainActor
final class WidgetMover {
    weak var window: NSWindow?
    /// The widget's frame after a drag ended (the controller saves it).
    var onMoved: ((CGRect) -> Void)?
    /// Keeps the frame on screen while dragging.
    var clamp: ((CGRect) -> CGRect)?
    private var start: (mouse: CGPoint, origin: CGPoint)?

    var isDragging: Bool { start != nil }

    func changed() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if start == nil { start = (mouse, window.frame.origin) }
        guard let start else { return }
        var frame = window.frame
        frame.origin = CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        frame = clamp?(frame) ?? frame
        // Child windows (the queue panel) move along by themselves.
        window.setFrameOrigin(frame.origin)
    }

    func ended() {
        guard start != nil else { return }
        start = nil
        if let window { onMoved?(window.frame) }
    }
}

private struct WidgetMoverKey: EnvironmentKey {
    static let defaultValue: WidgetMover? = nil
}

extension EnvironmentValues {
    /// The window mover of the widget this view is in.
    var widgetMover: WidgetMover? {
        get { self[WidgetMoverKey.self] }
        set { self[WidgetMoverKey.self] = newValue }
    }
}

private struct WidgetsLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The widgets are locked in place (`PlayerSettings.widgetsLocked`).
    var widgetsLocked: Bool {
        get { self[WidgetsLockedKey.self] }
        set { self[WidgetsLockedKey.self] = newValue }
    }
}

/// Dragging this view's background moves the widget's window (not while
/// the widgets are locked).
private struct MovesWidget: ViewModifier {
    @Environment(\.widgetMover) private var mover
    @Environment(\.widgetsLocked) private var isLocked

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in mover?.changed() }
                .onEnded { _ in mover?.ended() },
            including: isLocked ? .subviews : .all
        )
    }
}

extension View {
    func movesWidget() -> some View {
        modifier(MovesWidget())
    }
}
