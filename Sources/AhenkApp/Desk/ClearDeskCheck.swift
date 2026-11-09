import AhenkKit
import AppKit

/// Smoke check `clearDesk`: Clear Desk's real controller against a desk of
/// invented apps (nothing on this Mac is hidden): the first click hides the
/// right ones and makes Ahenk active, an app that refuses, one the user
/// shows, one that quits and one launched meanwhile are handled, the second
/// click shows exactly the rest and brings the front app back; the menu bar
/// item drives the environment's controller (also on invented apps in a
/// smoke run). This Mac's own apps are only read: the first click is worked
/// out for them and never carried out.
@MainActor
enum ClearDeskCheck {
    static func run(environment: AppEnvironment) async throws -> String {
        guard environment.options.mode != .normal, environment.deskController.workspace is InventedDeskWorkspace else {
            throw SmokeFailure("Clear Desk would act on the real apps")
        }
        let desk = InventedDeskWorkspace.demo()
        let editor: Int32 = 900_002, browser: Int32 = 900_003, finder: Int32 = 900_001
        let extra = DeskApp(pid: 900_010, bundleIdentifier: "com.example.stubborn", name: "Stubborn")
        desk.launch(extra)
        desk.refusing = [extra.pid]
        let controller = ClearDeskController(workspace: desk, store: ClearDeskStore(fileURL: nil))
        controller.start()
        defer { controller.stop() }

        controller.toggle()
        guard controller.isActive else { throw SmokeFailure("the first click did not clear the desk") }
        guard desk.calls.first == "activate Ahenk" else { throw SmokeFailure("Ahenk was not made active before hiding") }
        let hidden = desk.calls.filter { $0.hasPrefix("hide ") }
        guard hidden == ["hide Finder", "hide Browser", "hide Stubborn", "hide Editor"] else { throw SmokeFailure("hid \(hidden)") }
        guard desk.apps.first(where: { $0.name == "Video" })?.isHidden == false,
              desk.apps.first(where: { $0.name == "Menu Extra" })?.isHidden == false
        else { throw SmokeFailure("a full-screen app or a menu bar extra was hidden") }

        // A second later the refusing app is let go.
        try await Task.sleep(for: .seconds(ClearDeskController.refusalDelay + 0.2))
        // Meanwhile: the user shows the browser, Finder quits, a new app starts.
        desk.userShows(browser)
        desk.quit(finder)
        desk.launch(DeskApp(pid: 900_011, bundleIdentifier: "com.example.new", name: "New"))
        desk.clearCalls()

        controller.toggle()
        guard !controller.isActive else { throw SmokeFailure("the second click did not restore the desk") }
        guard desk.calls == ["show Editor", "activate Editor"] else {
            throw SmokeFailure("the second click did \(desk.calls) instead of showing the editor and bringing it to the front")
        }
        guard desk.apps.first(where: { $0.pid == editor })?.isHidden == false,
              desk.apps.first(where: { $0.name == "Notes" })?.isHidden == true,
              desk.apps.first(where: { $0.name == "New" })?.isHidden == false
        else { throw SmokeFailure("the desk did not come back as it was") }
        guard let restore = controller.lastRestore, restore.leftAlone.count == 0 || restore.leftAlone.allSatisfy({ [finder, browser].contains($0.pid) }) else {
            throw SmokeFailure("unexpected apps left alone")
        }

        // The menu bar item drives the environment's own controller.
        let deskBefore = environment.clearDesk.isActive
        try flipMenuItem(environment)
        guard environment.clearDesk.isActive != deskBefore else { throw SmokeFailure("the menu item did not clear the desk") }
        try flipMenuItem(environment)
        guard environment.clearDesk.isActive == deskBefore else { throw SmokeFailure("the menu item did not bring it back") }

        // This Mac, looked at only: the apps are read and the first click is
        // worked out, never carried out.
        let look = SystemDeskWorkspace().lookOnly()
        guard look.apps > 0, look.wouldHide + look.fullScreen + look.alreadyHidden < look.apps else {
            throw SmokeFailure("this Mac's apps could not be read")
        }
        return "invented desk: hid Finder, Browser, Stubborn and Editor (Ahenk active first; the full-screen app, the hidden one and "
            + "the menu bar extra left alone); the refusing app was let go; after the user showed one, one quit and one started, "
            + "the second click showed only Editor and brought it to the front; the menu item clears and restores; this Mac, looked at "
            + "only: \(look.apps) apps run, a click would hide \(look.wouldHide) and leave \(look.fullScreen) full-screen and "
            + "\(look.alreadyHidden) hidden ones alone (Spaces list \(ManagedSpaces.isAvailable ? "read" : "unavailable"))"
    }

    private static func flipMenuItem(_ environment: AppEnvironment) throws {
        let menu = NSMenu()
        QuickMenu.populate(menu, environment: environment, placement: .menuBar)
        guard let item = menu.items.first(where: { $0.title == "Clear Desk".l10n }), item.isEnabled, let action = item.action else {
            throw SmokeFailure("no enabled Clear Desk item in the menu")
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}
