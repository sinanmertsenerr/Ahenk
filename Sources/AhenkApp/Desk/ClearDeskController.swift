import AhenkKit
import AppKit
import Observation

/// What Clear Desk does to apps. The real one is macOS's (`SystemDeskWorkspace`);
/// demo and smoke runs use invented apps, so they never hide anything.
@MainActor
protocol DeskWorkspace: AnyObject {
    var ownPID: Int32 { get }
    func runningApps() -> [DeskApp]
    /// PIDs front to back, by their windows on screen.
    func windowOrder() -> [Int32]
    func frontmostPID() -> Int32?
    func isHidden(_ pid: Int32) -> Bool?
    @discardableResult func hide(_ pid: Int32) -> Bool
    @discardableResult func unhide(_ pid: Int32) -> Bool
    func activate(_ pid: Int32)
    /// Makes Ahenk the active app first, so macOS never activates (and so
    /// shows) an app that was just hidden.
    func activateAhenk()
    /// An app was shown by someone else (the user clicked it in the Dock).
    var onShown: ((Int32) -> Void)? { get set }
    var onTerminated: ((Int32) -> Void)? { get set }
    func startObserving()
    func stopObserving()
    /// Words for the log ("12 apps on this Mac", "demo").
    var label: String { get }
}

/// Clear Desk: one click hides every other app in view (the widgets and
/// the wallpaper stay), a second click shows exactly those apps again.
/// Hide and show only; nothing is ever quit or relaunched.
///
/// The rules are `ClearDeskState`'s (AhenkKit); this carries them out: it
/// makes Ahenk active, hides the apps, checks a second later which ones
/// refused, follows apps the user shows or quits meanwhile, and shows the
/// hidden ones again on the second click and when Ahenk quits. A cleared
/// desk is written to disk while it lasts, so a crash does not leave apps
/// hidden: the next launch shows them.
@MainActor
@Observable
final class ClearDeskController: DeskClearing {
    private(set) var isActive = false
    var isAvailable: Bool { true }

    @ObservationIgnored private var state = ClearDeskState()
    @ObservationIgnored let workspace: DeskWorkspace
    @ObservationIgnored private let store: ClearDeskStore
    @ObservationIgnored private var refusalCheck: DispatchWorkItem?
    /// What the last clicks did (the smoke check reads them).
    @ObservationIgnored private(set) var lastClear: DeskClearingPlan?
    @ObservationIgnored private(set) var lastRestore: DeskRestorePlan?
    @ObservationIgnored private var isStarted = false
    private let log = AhenkLogger(category: "desk")

    /// How long apps get to hide before the ones still visible count as refusing.
    static let refusalDelay: TimeInterval = 1.2

    init(workspace: DeskWorkspace, store: ClearDeskStore) {
        self.workspace = workspace
        self.store = store
    }

    /// Follows apps the user shows or quits, and shows what an earlier run
    /// left hidden.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        workspace.onShown = { [weak self] pid in self?.shown(pid) }
        workspace.onTerminated = { [weak self] pid in self?.terminated(pid) }
        workspace.startObserving()
        if let leftover = store.takeLeftover() {
            log.notice("Showing \(leftover.hidden.count) apps an earlier run of Ahenk hid with Clear Desk")
            state = leftover
            isActive = true
            restore()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        workspace.stopObserving()
        refusalCheck?.cancel()
    }

    func toggle() {
        if isActive { restore() } else { clear() }
    }

    // MARK: Clicks

    func clear() {
        guard !isActive else { return }
        let apps = workspace.runningApps()
        let plan = state.clear(
            apps: apps, ownPID: workspace.ownPID, windowOrder: workspace.windowOrder(), frontmostPID: workspace.frontmostPID(), at: Date()
        )
        lastClear = plan
        isActive = true
        store.save(state)
        if !plan.toHide.isEmpty { workspace.activateAhenk() }
        // `hide()` answers false on this macOS even when the app does hide,
        // so its answer is not trusted: the check a second later tells which
        // apps really stayed visible.
        for app in plan.toHide {
            workspace.hide(app.pid)
        }
        let skipped = plan.skipped.filter { $0.reason == .fullScreen }.map(\.app.name)
        log.notice("Clear Desk: hid \(plan.toHide.count) apps (\(workspace.label))\(skipped.isEmpty ? "" : "; full screen, left alone: \(skipped.joined(separator: ", "))")")
        store.save(state)
        scheduleRefusalCheck()
    }

    func restore() {
        guard isActive else { return }
        refusalCheck?.cancel()
        refusalCheck = nil
        let plan = state.restore(apps: workspace.runningApps())
        lastRestore = plan
        isActive = false
        store.save(state)
        for record in plan.toUnhide {
            workspace.unhide(record.pid)
        }
        if let front = plan.activate {
            workspace.activate(front.pid)
        }
        log.notice("Clear Desk: showed \(plan.toUnhide.count) apps again\(plan.leftAlone.isEmpty ? "" : ", \(plan.leftAlone.count) left as they are (quit or shown meanwhile)")")
    }

    /// Ahenk quits: whatever it hid comes back.
    func restoreOnQuit() {
        if isActive { restore() }
        stop()
    }

    // MARK: Events

    private func scheduleRefusalCheck() {
        refusalCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            for record in self.state.hidden where self.workspace.isHidden(record.pid) == false {
                self.log.info("\(record.name) did not hide; Clear Desk leaves it as it is")
                self.state.noteRefused(pid: record.pid)
            }
            self.store.save(self.state)
        }
        refusalCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refusalDelay, execute: work)
    }

    private func shown(_ pid: Int32) {
        guard isActive, state.hidden.contains(where: { $0.pid == pid }) else { return }
        // Shown by the user (or by macOS on their click): theirs again.
        state.noteShown(pid: pid)
        store.save(state)
    }

    private func terminated(_ pid: Int32) {
        guard isActive else { return }
        state.noteTerminated(pid: pid)
        store.save(state)
    }
}

// MARK: - macOS

/// The apps of this Mac, through NSWorkspace. Reads window bounds and
/// owners only (no window contents, no permission).
@MainActor
final class SystemDeskWorkspace: DeskWorkspace {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var onShown: ((Int32) -> Void)?
    var onTerminated: ((Int32) -> Void)?
    private var tokens: [NSObjectProtocol] = []
    var label: String { "this Mac" }

    func runningApps() -> [DeskApp] {
        let fullScreen = fullScreenPIDs()
        return NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map { app in
            DeskApp(
                pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "?",
                isRegular: app.activationPolicy == .regular, isHidden: app.isHidden, isFullScreen: fullScreen.contains(app.processIdentifier)
            )
        }
    }

    func windowOrder() -> [Int32] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var order: [Int32] = []
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, !order.contains(pid) else { continue }
            order.append(pid)
        }
        return order
    }

    /// Apps that are full screen: the owners of full-screen Spaces (from
    /// the window server's list of Spaces, on any Space) and apps with a
    /// borderless window exactly as large as a display (a game, a
    /// slideshow).
    private func fullScreenPIDs() -> Set<Int32> {
        var pids = DeskSpaces.fullScreenPIDs(in: ManagedSpaces.current())
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        guard !bounds.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return pids }
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let info = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: info)
            else { continue }
            if bounds.contains(where: { abs($0.minX - frame.minX) < 1 && abs($0.minY - frame.minY) < 1 && abs($0.width - frame.width) < 1 && abs($0.height - frame.height) < 1 }) {
                pids.insert(pid)
            }
        }
        return pids
    }

    func frontmostPID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isHidden(_ pid: Int32) -> Bool? {
        NSRunningApplication(processIdentifier: pid).map(\.isHidden)
    }

    func hide(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.hide() ?? false
    }

    func unhide(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.unhide() ?? false
    }

    func activate(_ pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        // macOS 14 activates cooperatively: Ahenk hands its activation over.
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    func activateAhenk() {
        NSApp.activate()
    }

    func startObserving() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(note) else { return }
            MainActor.assumeIsolated { self?.onShown?(pid) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(note) else { return }
            MainActor.assumeIsolated { self?.onTerminated?(pid) }
        })
    }

    func stopObserving() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
    }

    private nonisolated static func pid(_ note: Notification) -> Int32? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }

    /// What the first click would do on this Mac right now, worked out by
    /// the rules and not carried out: nothing is hidden, shown or made
    /// active (the smoke check reads the counts).
    func lookOnly() -> (apps: Int, wouldHide: Int, fullScreen: Int, alreadyHidden: Int) {
        var state = ClearDeskState()
        let apps = runningApps()
        let plan = state.clear(apps: apps, ownPID: ownPID, windowOrder: windowOrder(), frontmostPID: frontmostPID(), at: Date())
        func count(_ reason: DeskSkipReason) -> Int { plan.skipped.filter { $0.reason == reason }.count }
        return (apps.count, plan.toHide.count, count(.fullScreen), count(.alreadyHidden))
    }
}

/// The window server's list of Spaces per display (read only: types and
/// owners, no window contents, no permission). The two functions are
/// private to macOS and looked up at run time; without them the list is
/// empty and full-screen apps are told by their windows' bounds alone.
enum ManagedSpaces {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias SpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (connection: ConnectionFunction, spaces: SpacesFunction)? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(framework, "CGSMainConnectionID"),
              let spaces = dlsym(framework, "CGSCopyManagedDisplaySpaces")
        else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFunction.self), unsafeBitCast(spaces, to: SpacesFunction.self))
    }()

    static var isAvailable: Bool { functions != nil }

    static func current() -> [[String: Any]] {
        guard let functions else { return [] }
        return functions.spaces(functions.connection())?.takeRetainedValue() as? [[String: Any]] ?? []
    }
}

// MARK: - Invented apps

/// A desk of invented apps for `--demo` and the smoke check: Clear Desk
/// runs its real rules against it and nothing on the Mac is touched.
@MainActor
final class InventedDeskWorkspace: DeskWorkspace {
    private(set) var apps: [DeskApp]
    let ownPID: Int32
    var windows: [Int32]
    var frontmost: Int32?
    /// PIDs that ignore a request to hide.
    var refusing: Set<Int32> = []
    private(set) var calls: [String] = []
    var onShown: ((Int32) -> Void)?
    var onTerminated: ((Int32) -> Void)?
    var label: String { "invented apps, nothing on this Mac is hidden" }

    init(apps: [DeskApp], ownPID: Int32, windows: [Int32], frontmost: Int32?) {
        self.apps = apps
        self.ownPID = ownPID
        self.windows = windows
        self.frontmost = frontmost
    }

    /// The demo's desk: Ahenk, Finder, an editor, a browser, a hidden notes
    /// app, a full-screen video app and a menu bar extra (all invented).
    static func demo() -> InventedDeskWorkspace {
        let own = ProcessInfo.processInfo.processIdentifier
        return InventedDeskWorkspace(
            apps: [
                DeskApp(pid: own, bundleIdentifier: KnownApps.ahenk, name: "Ahenk"),
                DeskApp(pid: 900_001, bundleIdentifier: "com.example.finder", name: "Finder"),
                DeskApp(pid: 900_002, bundleIdentifier: "com.example.editor", name: "Editor"),
                DeskApp(pid: 900_003, bundleIdentifier: "com.example.browser", name: "Browser"),
                DeskApp(pid: 900_004, bundleIdentifier: "com.example.notes", name: "Notes", isHidden: true),
                DeskApp(pid: 900_005, bundleIdentifier: "com.example.video", name: "Video", isFullScreen: true),
                DeskApp(pid: 900_006, bundleIdentifier: "com.example.extra", name: "Menu Extra", isRegular: false),
            ],
            ownPID: own, windows: [900_002, 900_003, 900_001], frontmost: 900_002
        )
    }

    func runningApps() -> [DeskApp] { apps }
    func windowOrder() -> [Int32] { windows }
    func frontmostPID() -> Int32? { frontmost }
    func isHidden(_ pid: Int32) -> Bool? { apps.first { $0.pid == pid }?.isHidden }

    func hide(_ pid: Int32) -> Bool {
        calls.append("hide \(name(pid))")
        guard !refusing.contains(pid) else { return true }
        set(pid, hidden: true)
        return true
    }

    func unhide(_ pid: Int32) -> Bool {
        calls.append("show \(name(pid))")
        set(pid, hidden: false)
        return true
    }

    func activate(_ pid: Int32) {
        calls.append("activate \(name(pid))")
        frontmost = pid
    }

    func activateAhenk() {
        calls.append("activate Ahenk")
        frontmost = ownPID
    }

    func startObserving() {}
    func stopObserving() {}

    /// The user clicks a hidden app in the Dock.
    func userShows(_ pid: Int32) {
        set(pid, hidden: false)
        onShown?(pid)
    }

    func quit(_ pid: Int32) {
        apps.removeAll { $0.pid == pid }
        windows.removeAll { $0 == pid }
        onTerminated?(pid)
    }

    func launch(_ app: DeskApp) {
        apps.append(app)
        windows.insert(app.pid, at: 0)
    }

    func clearCalls() {
        calls = []
    }

    private func set(_ pid: Int32, hidden: Bool) {
        if let index = apps.firstIndex(where: { $0.pid == pid }) { apps[index].isHidden = hidden }
    }

    private func name(_ pid: Int32) -> String {
        apps.first { $0.pid == pid }?.name ?? "\(pid)"
    }
}
