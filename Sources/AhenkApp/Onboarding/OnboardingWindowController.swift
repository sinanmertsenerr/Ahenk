import AhenkKit
import AppKit
import SwiftUI

/// The first-run guide's window: opens by itself on the first normal
/// launch, again from the menu bar menu, the app menu and Settings ›
/// General. Closing it (any way) in a normal run counts as done, so it
/// never nags; its content is released when it closes.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 640, height: 560)

    let model = OnboardingModel()
    private unowned let environment: AppEnvironment
    private var window: NSWindow?
    private var titleObserver: ChangeObserver<AppLanguage>?
    private static let log = AhenkLogger(category: "onboarding")

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(page: OnboardingPage? = nil) {
        if let page {
            model.page = page
        } else if window == nil {
            model.page = .welcome
        }
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Self.log.info("Showing the guide (\(model.page.rawValue))")
    }

    func close() {
        window?.close()
    }

    /// "Welcome to Ahenk" in the current language.
    static var title: String { "Welcome to Ahenk".l10n }

    private func makeWindow() -> NSWindow {
        let root = OnboardingView(environment: environment, model: model) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = Self.title
        let settings = environment.settings
        titleObserver = ChangeObserver({ settings.general.language }) { [weak window] _ in
            window?.title = Self.title
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.size)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if OnboardingPolicy.closingCountsAsSeen(mode: environment.options.mode), !environment.settings.general.onboardingCompleted {
            environment.settings.general.onboardingCompleted = true
            Self.log.info("The guide was closed; it opens again only when asked")
        }
        window?.contentViewController = nil
        window = nil
        titleObserver = nil
    }
}
