import AhenkKit
import AppKit
import CoreGraphics

/// One connected display as the edge light sees it.
struct LightScreen: Equatable {
    /// CoreGraphics UUID: survives reconnects (the per-display setting).
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    /// Global AppKit coordinates.
    let frame: CGRect
    let backingScale: CGFloat
    let shape: EdgeShape
    let maximumFramesPerSecond: Int

    /// Every display that has a UUID, in `NSScreen.screens` order.
    @MainActor
    static func current() -> [(LightScreen, NSScreen)] {
        NSScreen.screens.compactMap { screen in
            LightScreen(screen).map { ($0, screen) }
        }
    }

    @MainActor
    init?(_ screen: NSScreen) {
        guard let displayID = DisplayIdentity.displayID(of: screen),
              let id = DisplayIdentity.stableID(of: screen)
        else { return nil }
        self.id = id
        self.displayID = displayID
        name = screen.localizedName
        frame = screen.frame
        backingScale = screen.backingScaleFactor
        let notch = EdgeShape.notchRect(
            frame: screen.frame, topLeftArea: screen.auxiliaryTopLeftArea,
            topRightArea: screen.auxiliaryTopRightArea, safeAreaTop: screen.safeAreaInsets.top
        )
        shape = EdgeShape.display(width: screen.frame.width, height: screen.frame.height, notch: notch)
        maximumFramesPerSecond = max(30, screen.maximumFramesPerSecond)
    }

    /// The display's bounds in CoreGraphics global coordinates (top-left
    /// origin), as window lists report them.
    var quartzBounds: CGRect { CGDisplayBounds(displayID) }

    /// A different particle pattern per display.
    var seed: Int32 { Int32(bitPattern: displayID % 10_007) }
}
