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
    private var titleObserver: ChangeObserver<AppLanguage>?
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
        // The title is set below; SwiftUI's navigation title never reached
        // the window (it showed "Untitled" in the title bar and Window menu).
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = Self.title
        let settings = environment.settings
        titleObserver = ChangeObserver({ settings.general.language }) { [weak window] _ in
            window?.title = Self.title
        }
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

    /// "Ahenk Settings" in the current language.
    static var title: String { "Ahenk Settings".l10n }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree so timelines and observers stop with it.
        window?.contentViewController = nil
        window = nil
        titleObserver = nil
    }
}
