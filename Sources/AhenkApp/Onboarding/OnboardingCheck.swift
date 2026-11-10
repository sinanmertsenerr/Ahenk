import AhenkKit
import AppKit
import SwiftUI

/// `--smoke` check `onboarding`: every page of the first-run guide drawn
/// offscreen in both languages (nothing is asked, nothing is shown), the
/// rules for when it opens, the menu items that open it again, and the
/// login item's state read without changing it.
@MainActor
enum OnboardingCheck {
    static func run(environment: AppEnvironment, snapshots: URL?) async throws -> String {
        guard !OnboardingPolicy.showsAtLaunch(mode: environment.options.mode, completed: false, requested: true) else {
            throw SmokeFailure("a smoke run would open the guide")
        }
        let settings = environment.settings
        let original = settings.general.language
        let originalCompleted = settings.general.onboardingCompleted
        defer {
            settings.general.language = original
            settings.general.onboardingCompleted = originalCompleted
        }
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }

        var drawn = 0
        let model = OnboardingModel()
        for language in AppLanguage.allCases {
            settings.general.language = language
            for page in OnboardingPage.allCases {
                model.page = page
                let view = OnboardingView(environment: environment, model: model) {}
                let bitmap = try await OffscreenRender.bitmap(of: view, size: OnboardingWindowController.size)
                let share = OffscreenRender.drawnShare(bitmap)
                guard share > 0.02 else {
                    throw SmokeFailure("the \(page.rawValue) page drew almost nothing in \(language.rawValue) (\(Int(share * 100)) %)")
                }
                if let snapshots, let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: snapshots.appendingPathComponent("onboarding-\(page.rawValue)-\(language.rawValue).png"))
                }
                drawn += 1
            }
            // The guide opens again from the menu bar menu and the app menu.
            let menu = NSMenu()
            QuickMenu.populate(menu, environment: environment, placement: .menuBar)
            guard menu.items.contains(where: { $0.title == "Getting Started…".l10n && $0.action != nil }) else {
                throw SmokeFailure("the menu bar menu has no Getting Started item in \(language.rawValue)")
            }
            let appMenu = MainMenu.build(environment: environment).items.first?.submenu
            guard appMenu?.items.contains(where: { $0.title == "Getting Started…".l10n }) == true else {
                throw SmokeFailure("the app menu has no Getting Started item in \(language.rawValue)")
            }
        }

        // Login at startup: macOS's own state, only read in a smoke run.
        let login = environment.loginItem
        guard !login.canChange else { throw SmokeFailure("a smoke run could change the login item") }
        login.refresh()
        let saved = snapshots.map { ", snapshots in \($0.path)" } ?? ""
        return "\(drawn) pages drawn offscreen (\(OnboardingPage.allCases.count) pages × \(AppLanguage.allCases.count) languages); "
            + "opens by itself only on a normal first launch; Getting Started in the menu bar and app menus; "
            + "open at login: \(login.state.rawValue) (read, never changed here)\(saved)"
    }
}
