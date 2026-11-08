import AhenkKit
import AppKit
import CoreGraphics

/// What is in front: which app is active (for "only on the desktop") and
/// which displays show an app full screen (for "step aside"). Event-driven:
/// app activation and Space changes, plus one look shortly after a Space
/// change, when its animation has finished.
@MainActor
final class DesktopWatcher {
    /// The desktop counts as "in front" while the Finder (the desktop
    /// itself) or Ahenk is the active app.
    private(set) var isDesktopInFront = true
    /// Displays where a window covers the whole screen (a full-screen app,
    /// a game, a slideshow).
    private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []
    /// Called after either changed.
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private static let finder = "com.apple.finder"
    private static let log = AhenkLogger(category: "light")

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        })
        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        pending?.cancel()
        pending = nil
    }

    private func changed() {
        refresh()
        // Spaces slide in; look again once the new one has settled.
        pending?.cancel()
        let again = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: again)
    }

    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        let desktop = front == nil
            || front?.bundleIdentifier == Self.finder
            || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let full = Self.fullScreenDisplays()
        guard desktop != isDesktopInFront || full != fullScreenDisplays else { return }
        if full != fullScreenDisplays {
            Self.log.info("Full screen on \(full.count) display(s)")
        }
        isDesktopInFront = desktop
        fullScreenDisplays = full
        onChange?()
    }

    /// Displays covered edge to edge by an ordinary window of another app.
    /// Reads only window bounds, owners and levels (no window contents,
    /// no permission involved).
    static func fullScreenDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        let bounds = displays.map { ($0, CGDisplayBounds($0)) }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var covered: Set<CGDirectDisplayID> = []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != me,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw)
            else { continue }
            for (display, screen) in bounds where frame.equalTo(screen) {
                covered.insert(display)
            }
        }
        return covered
    }
}
