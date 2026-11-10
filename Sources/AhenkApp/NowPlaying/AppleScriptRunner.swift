import AhenkKit
import Carbon
import Foundation
import os

/// Runs AppleScript off the main thread, one script at a time, and asks
/// macOS about the Automation permission.
///
/// Callers (the scripted providers) only run a script while the target app
/// is running: `tell application` would launch it. Every script carries its
/// own `with timeout`, so a busy app cannot stall the queue for long.
final class AppleScriptRunner: ScriptRunning, @unchecked Sendable {
    // Safety: `compiled` is only touched on `queue`.
    private let queue = DispatchQueue(label: "com.sinanmertsener.Ahenk.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String) async -> Result<ScriptValue, ScriptError> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.execute(source))
            }
        }
    }

    /// How long macOS gets to say whether Ahenk may automate an app.
    static let permissionTimeout: TimeInterval = 2.5

    /// Apps whose permission question macOS has not answered yet (the call
    /// is still waiting on its thread): not asked again meanwhile.
    private static let unanswered = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func automationPermission(for bundleIdentifier: String, askIfNeeded: Bool) async -> AutomationPermission {
        if let status = await determinePermission(for: bundleIdentifier) {
            let permission = Self.permission(for: status)
            // Not asked yet and the user wants to be asked: the script
            // below makes macOS show its question.
            if !(permission == .notDetermined && askIfNeeded) { return permission }
        } else if !askIfNeeded, !UserDefaults.standard.bool(forKey: Self.grantedKey(bundleIdentifier)) {
            // Never prompt by itself: without an answer from macOS, only an
            // app that was read before is tried (that cannot prompt).
            return .notDetermined
        }
        // macOS never answers this question for some apps (Spotify on
        // macOS 26: the call waits forever), which left the app unread: no
        // position checks, no paused song after a launch. Using the app
        // answers it: a script runs when Ahenk is allowed, and fails with
        // the permission's own error when it is not.
        let probe = "with timeout of 5 seconds\ntell application id \"\(bundleIdentifier)\" to get name\nend timeout"
        switch await run(probe) {
        case .success:
            UserDefaults.standard.set(true, forKey: Self.grantedKey(bundleIdentifier))
            return .granted
        case .failure(let error):
            switch error.code {
            case ScriptError.automationDenied:
                UserDefaults.standard.removeObject(forKey: Self.grantedKey(bundleIdentifier))
                return .denied
            case ScriptError.consentRequired: return .notDetermined
            case Int(procNotFound): return .appNotRunning
            default: return .unknown
            }
        }
    }

    /// Remembers that scripts reached the app (so the next launch may
    /// read it without macOS's answer, and without a prompt).
    private static func grantedKey(_ bundleIdentifier: String) -> String { "automationWorked.\(bundleIdentifier)" }

    /// macOS's answer without a prompt, or `nil` when it does not come in
    /// time.
    private func determinePermission(for bundleIdentifier: String) async -> OSStatus? {
        guard Self.unanswered.withLock({ $0.insert(bundleIdentifier).inserted }) else { return nil }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (OSStatus?) -> Void = { status in
                guard resumed.withLock({ done -> Bool in
                    defer { done = true }
                    return !done
                }) else { return }
                continuation.resume(returning: status)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
                )
                Self.unanswered.withLock { _ = $0.remove(bundleIdentifier) }
                finish(status)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.permissionTimeout) {
                finish(nil)
            }
        }
    }

    static func permission(for status: OSStatus) -> AutomationPermission {
        switch Int(status) {
        case Int(noErr): .granted
        case ScriptError.automationDenied: .denied
        case ScriptError.consentRequired: .notDetermined
        case Int(procNotFound): .appNotRunning
        default: .unknown
        }
    }

    // MARK: Execution (on `queue`)

    private func execute(_ source: String) -> Result<ScriptValue, ScriptError> {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else {
                return .failure(ScriptError(code: -2700, message: "The script could not be created"))
            }
            var error: NSDictionary?
            guard created.compileAndReturnError(&error) else {
                return .failure(Self.error(from: error))
            }
            // Reads repeat; commands carry arguments (a seek target), so
            // keep the cache small instead of growing with every seek.
            if compiled.count >= 32 { compiled.removeAll() }
            compiled[source] = created
            script = created
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error { return .failure(Self.error(from: error)) }
        return .success(Self.value(of: descriptor))
    }

    private static func error(from dictionary: NSDictionary?) -> ScriptError {
        let code = (dictionary?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        let message = dictionary?[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
        return ScriptError(code: code, message: message)
    }

    /// Converts a result descriptor into plain values.
    static func value(of descriptor: NSAppleEventDescriptor) -> ScriptValue {
        switch descriptor.descriptorType {
        case DescType(typeAEList):
            let count = descriptor.numberOfItems
            guard count > 0 else { return .list([]) }
            return .list((1...count).map { index in
                descriptor.atIndex(index).map(value(of:)) ?? .missing
            })
        case DescType(typeTrue):
            return .boolean(true)
        case DescType(typeFalse):
            return .boolean(false)
        case DescType(typeBoolean):
            return .boolean(descriptor.booleanValue)
        case DescType(typeSInt16), DescType(typeSInt32), DescType(typeSInt64), DescType(typeUInt16),
             DescType(typeUInt32), DescType(typeUInt64), DescType(typeIEEE32BitFloatingPoint),
             DescType(typeIEEE64BitFloatingPoint):
            return .number(descriptor.doubleValue)
        case DescType(typeNull):
            return .missing
        case DescType(typeType):
            return descriptor.typeCodeValue == OSType(cMissingValue) ? .missing : .text(descriptor.stringValue ?? "")
        case DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar), DescType(typeUTF16ExternalRepresentation):
            return .text(descriptor.stringValue ?? "")
        case DescType(typeEnumerated):
            return .text(descriptor.stringValue ?? "")
        default:
            // Pictures and raw artwork data ('JPEG', 'PNGf', 'tdta', …).
            return .data(descriptor.data)
        }
    }
}
