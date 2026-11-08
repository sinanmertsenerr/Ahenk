import AhenkKit
import Carbon
import Foundation

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

    func automationPermission(for bundleIdentifier: String, askIfNeeded: Bool) async -> AutomationPermission {
        await withCheckedContinuation { continuation in
            // Asking blocks until the user answers macOS's prompt.
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askIfNeeded
                )
                continuation.resume(returning: Self.permission(for: status))
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
