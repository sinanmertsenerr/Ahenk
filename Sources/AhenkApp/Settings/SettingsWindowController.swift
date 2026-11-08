import AhenkKit
import AppKit
import SwiftUI

/// The Settings window: created on first use, reused afterwards, and
/// released from memory when closed (nothing in it runs while hidden).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let navigation = SettingsNavigation()
    private unowned let environment: AppEnvironment
    private var window: NSWindow?
    private static let log = AhenkLogger(category: "settings-window")

    static let defaultSize = NSSize(width: 780, height: 580)

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Self.log.info("Showing settings (\(navigation.selection?.rawValue ?? "general"))")
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(environment: environment, navigation: navigation)
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = NSSize(width: 720, height: 500)
        if !window.setFrameUsingName("AhenkSettings") {
            window.center()
        }
        window.setFrameAutosaveName("AhenkSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree so timelines and observers stop with it.
        window?.contentViewController = nil
        window = nil
    }
}
