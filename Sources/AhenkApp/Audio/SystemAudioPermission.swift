import AhenkKit
import Darwin
import Foundation

/// macOS's "System Audio Recording Only" permission (the TCC service
/// `kTCCServiceAudioCapture`), which process taps need. Never the
/// microphone.
///
/// macOS has no public call that reads this permission without asking, so
/// the TCC framework's own functions are looked up at run time:
/// `TCCAccessPreflight` answers silently (granted, denied, not asked) and
/// `TCCAccessRequest` shows macOS's prompt. Only a button the user presses
/// may call ``request(_:)``. If the functions are missing on some macOS,
/// the state reads `.unknown` and Ahenk listens only after the user allowed
/// it (building the tap then lets macOS ask by itself).
enum SystemAudioPermission {
    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let framework: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: Preflight? = {
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    private static let requestAccess: Request? = {
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: Request.self)
    }()

    /// The current state, read without any prompt. Takes a moment (it asks
    /// the TCC daemon); call it off the main thread.
    static func status() -> AudioCapturePermission {
        guard let preflight else { return .unknown }
        return AudioCapturePermission(preflightResult: Int(preflight(service, nil)))
    }

    /// True when ``request(_:)`` can show macOS's prompt itself.
    static var canRequest: Bool { requestAccess != nil }

    /// Shows macOS's prompt if the user has not answered yet; otherwise
    /// macOS answers at once with the earlier decision. `completion` runs
    /// on an arbitrary queue. Call only from a button the user pressed.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let requestAccess else {
            completion(false)
            return
        }
        requestAccess(service, nil) { granted in completion(granted) }
    }
}
