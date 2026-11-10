import AhenkKit
import AppKit
import Observation
import ServiceManagement

/// "Open Ahenk at login": the system's own login item for this app
/// (System Settings › General › Login Items), read and changed through
/// `SMAppService.mainApp`. Nothing is stored in Ahenk's settings, so the
/// switch always shows what macOS will do, also after a change made in
/// System Settings.
@MainActor
@Observable
final class LoginItem {
    enum State: String, Equatable {
        case off
        case on
        /// Registered, but switched off in System Settings › Login Items:
        /// macOS waits for the user's approval there.
        case needsApproval
        /// Not an app bundle (`swift run`): there is nothing to register.
        case unavailable
    }

    private(set) var state: State = .off
    /// The last register/unregister failure, for the UI.
    private(set) var problem: String?
    /// Demo and smoke runs read the state but never change it.
    @ObservationIgnored let canChange: Bool
    @ObservationIgnored private var activation: NSObjectProtocol?
    private static let log = AhenkLogger(category: "login-item")

    init(canChange: Bool) {
        self.canChange = canChange
        state = Self.read()
        // The user may change it in System Settings while Ahenk runs.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Ahenk is (or waits to be) opened at login.
    var isOn: Bool { state == .on || state == .needsApproval }

    func refresh() {
        let current = Self.read()
        if current != state { state = current }
    }

    /// Adds or removes the login item; the switch shows what macOS did.
    func set(_ on: Bool) {
        guard canChange, state != .unavailable, on != isOn else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
            Self.log.notice(on ? "Ahenk now opens at login" : "Ahenk no longer opens at login")
        } catch {
            problem = error.localizedDescription
            Self.log.error("Could not \(on ? "add" : "remove") the login item: \(error.localizedDescription)")
        }
        refresh()
    }

    /// System Settings › General › Login Items.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The system's state, read without changing anything.
    static func read() -> State {
        guard AppInfo.isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        // `.notFound` is what macOS answers for an app that never
        // registered itself.
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }
}
