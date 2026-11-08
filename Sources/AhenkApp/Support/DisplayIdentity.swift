import AppKit
import CoreGraphics

/// A connected display, identified by its CoreGraphics UUID so per-display
/// settings survive reconnects and rearrangement.
struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let name: String
    /// The display with the menu bar.
    let isMain: Bool
}

enum DisplayIdentity {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Stable UUID string of the display behind `screen`.
    static func stableID(of screen: NSScreen) -> String? {
        guard let displayID = displayID(of: screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    @MainActor
    static func currentDisplays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        return screens.enumerated().compactMap { index, screen in
            guard let id = stableID(of: screen) else { return nil }
            return DisplayInfo(id: id, name: screen.localizedName, isMain: index == 0)
        }
    }
}
