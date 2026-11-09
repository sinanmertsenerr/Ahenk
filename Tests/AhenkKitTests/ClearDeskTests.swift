import Foundation
import Testing
@testable import AhenkKit

/// A desk of invented apps: Ahenk (pid 1), Finder, an editor in front, a
/// browser behind it, a notes app the user had hidden, a full-screen video
/// app, a menu bar extra.
private struct FakeDesk {
    static let ahenk: Int32 = 1
    var apps: [DeskApp] = [
        DeskApp(pid: 1, bundleIdentifier: "com.sinanmertsener.Ahenk", name: "Ahenk"),
        DeskApp(pid: 10, bundleIdentifier: "com.apple.finder", name: "Finder"),
        DeskApp(pid: 20, bundleIdentifier: "com.example.editor", name: "Editor"),
        DeskApp(pid: 30, bundleIdentifier: "com.example.browser", name: "Browser"),
        DeskApp(pid: 40, bundleIdentifier: "com.example.notes", name: "Notes", isHidden: true),
        DeskApp(pid: 50, bundleIdentifier: "com.example.player", name: "Player", isFullScreen: true),
        DeskApp(pid: 60, bundleIdentifier: "com.example.menuextra", name: "Menu Extra", isRegular: false),
    ]
    /// Front to back.
    var windowOrder: [Int32] = [20, 30, 10]
    var frontmost: Int32? = 20

    mutating func setHidden(_ pid: Int32, _ hidden: Bool) {
        if let index = apps.firstIndex(where: { $0.pid == pid }) { apps[index].isHidden = hidden }
    }

    /// Carries out a plan like the app does.
    mutating func apply(_ plan: DeskClearingPlan, refusing: Set<Int32> = []) {
        for app in plan.toHide where !refusing.contains(app.pid) { setHidden(app.pid, true) }
    }

    mutating func apply(_ plan: DeskRestorePlan) {
        for record in plan.toUnhide { setHidden(record.pid, false) }
    }

    func visible() -> Set<Int32> { Set(apps.filter { !$0.isHidden }.map(\.pid)) }
}

@Suite("Clear Desk")
struct ClearDeskTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("The first click hides every visible regular app but Ahenk, back to front, the active app last")
    func clearHidesTheRightApps() {
        var desk = FakeDesk()
        var state = ClearDeskState()
        let plan = state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: desk.frontmost, at: start)
        #expect(plan.toHide.map(\.name) == ["Finder", "Browser", "Editor"])
        let skipped = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.app.name, $0.reason) })
        #expect(skipped == ["Ahenk": .ahenk, "Notes": .alreadyHidden, "Player": .fullScreen, "Menu Extra": .notRegular])
        #expect(state.isCleared && state.frontmost?.pid == 20)
        desk.apply(plan)
        #expect(desk.visible() == [1, 50, 60], "only Ahenk, the full-screen app and the menu bar extra stay")
    }

    @Test("The second click shows exactly what Ahenk hid, back to front, then the app that was in front")
    func restoreShowsWhatWasVisible() {
        var desk = FakeDesk()
        let before = desk.visible()
        var state = ClearDeskState()
        desk.apply(state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start))
        let restore = state.restore(apps: desk.apps)
        #expect(restore.toUnhide.map(\.name) == ["Finder", "Browser", "Editor"])
        #expect(restore.activate?.pid == 20)
        #expect(restore.leftAlone.isEmpty)
        desk.apply(restore)
        #expect(desk.visible() == before)
        #expect(desk.apps.first { $0.pid == 40 }?.isHidden == true, "the app the user had hidden stays hidden")
        #expect(!state.isCleared && state.hidden.isEmpty)
    }

    @Test("An app the user brings back meanwhile is theirs: the second click leaves it, even if they hid it again")
    func shownByHandIsForgotten() {
        var desk = FakeDesk()
        var state = ClearDeskState()
        desk.apply(state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start))
        desk.setHidden(30, false)
        state.noteShown(pid: 30)
        // …then hides it again with Command-H.
        desk.setHidden(30, true)
        let restore = state.restore(apps: desk.apps)
        #expect(!restore.toUnhide.contains { $0.pid == 30 })
        #expect(desk.apps.first { $0.pid == 30 }?.isHidden == true)
    }

    @Test("An app shown by the system without a notification is not shown twice")
    func alreadyVisibleIsLeftAlone() {
        var desk = FakeDesk()
        var state = ClearDeskState()
        desk.apply(state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start))
        desk.setHidden(10, false)
        let restore = state.restore(apps: desk.apps)
        #expect(restore.toUnhide.map(\.pid) == [30, 20])
        #expect(restore.leftAlone.map(\.pid) == [10])
    }

    @Test("Apps that quit, relaunch or start meanwhile are never touched")
    func launchedAndQuitMeanwhile() {
        var desk = FakeDesk()
        var state = ClearDeskState()
        desk.apply(state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start))
        // The browser quits; the editor quits and comes back as a new process.
        desk.apps.removeAll { $0.pid == 30 || $0.pid == 20 }
        state.noteTerminated(pid: 30)
        desk.apps.append(DeskApp(pid: 21, bundleIdentifier: "com.example.editor", name: "Editor"))
        desk.apps.append(DeskApp(pid: 70, bundleIdentifier: "com.example.new", name: "New App"))
        let restore = state.restore(apps: desk.apps)
        #expect(restore.toUnhide.map(\.pid) == [10], "only Finder: the editor's new process and the new app were never hidden")
        #expect(restore.activate == nil, "the app that was in front is gone")
        #expect(restore.leftAlone.map(\.pid) == [20])
    }

    @Test("A reused PID with another bundle is not the app Ahenk hid")
    func reusedPID() {
        var desk = FakeDesk()
        var state = ClearDeskState()
        desk.apply(state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start))
        let index = desk.apps.firstIndex { $0.pid == 30 }!
        desk.apps[index] = DeskApp(pid: 30, bundleIdentifier: "com.example.other", name: "Other", isHidden: true)
        let restore = state.restore(apps: desk.apps)
        #expect(!restore.toUnhide.contains { $0.pid == 30 })
    }

    @Test("An app that refuses to hide stays as it is and is not restored")
    func refusingApp() {
        var desk = FakeDesk()
        var state = ClearDeskState()
        let plan = state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start)
        desk.apply(plan, refusing: [20])
        state.noteRefused(pid: 20)
        #expect(state.refused.map(\.pid) == [20])
        #expect(state.frontmost == nil, "the refusing app was in front; nothing to bring back")
        let restore = state.restore(apps: desk.apps)
        #expect(restore.toUnhide.map(\.pid) == [10, 30])
        #expect(restore.activate == nil)
    }

    @Test("Apps without windows on screen go first; the order is stable")
    func hidingOrder() {
        var state = ClearDeskState()
        let apps = [
            DeskApp(pid: 5, bundleIdentifier: "a", name: "A"),
            DeskApp(pid: 6, bundleIdentifier: "b", name: "B"),
            DeskApp(pid: 7, bundleIdentifier: "c", name: "C"),
            DeskApp(pid: 8, bundleIdentifier: "d", name: "D"),
        ]
        let plan = state.clear(apps: apps, ownPID: 1, windowOrder: [7, 5], frontmostPID: 6, at: start)
        #expect(plan.toHide.map(\.pid) == [8, 5, 7, 6], "no windows (8), then back to front (5, 7), the active app (6) last")
    }

    @Test("Ahenk in front is never 'the app to bring back'; an empty desk is a no-op")
    func edgeCases() {
        var state = ClearDeskState()
        let plan = state.clear(apps: [DeskApp(pid: 1, bundleIdentifier: "x", name: "Ahenk")], ownPID: 1, windowOrder: [1], frontmostPID: 1, at: start)
        #expect(plan.toHide.isEmpty && state.frontmost == nil && state.isCleared)
        let restore = state.restore(apps: [])
        #expect(restore.toUnhide.isEmpty && restore.activate == nil && !state.isCleared)
    }

    @Test("A cleared desk is remembered on disk until it is restored, and only for a while")
    func store() throws {
        let scratch = ScratchDirectory()
        let store = ClearDeskStore(fileURL: scratch.url.appendingPathComponent("ClearDesk.json"))
        var desk = FakeDesk()
        var state = ClearDeskState()
        desk.apply(state.clear(apps: desk.apps, ownPID: FakeDesk.ahenk, windowOrder: desk.windowOrder, frontmostPID: 20, at: start))
        store.save(state)
        let leftover = try #require(store.takeLeftover(now: start.addingTimeInterval(60)))
        #expect(leftover == state)
        #expect(store.takeLeftover(now: start.addingTimeInterval(60)) == nil, "taken once")
        store.save(state)
        #expect(store.takeLeftover(now: start.addingTimeInterval(ClearDeskStore.maximumAge + 1)) == nil, "too old: another session")
        store.save(state)
        _ = state.restore(apps: desk.apps)
        store.save(state)
        #expect(store.takeLeftover(now: start) == nil, "restoring forgets it")
        #expect(ClearDeskStore(fileURL: nil).takeLeftover() == nil)
    }
}
