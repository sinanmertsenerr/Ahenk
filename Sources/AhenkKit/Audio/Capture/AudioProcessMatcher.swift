import Foundation

/// One Core Audio process object (a process that has used audio), with what
/// is needed to tell whose sound it is.
public struct AudioProcess: Sendable, Equatable {
    /// The Core Audio object ID (`AudioObjectID`).
    public var objectID: UInt32
    public var pid: Int32
    public var bundleIdentifier: String?
    /// The process macOS holds responsible for it: the app behind an XPC
    /// helper (WebKit's GPU process belongs to the browser that started
    /// it). `nil` when it cannot be read.
    public var responsiblePID: Int32?
    /// Parent, grandparent, … (nearest first; may be empty).
    public var ancestors: [Int32]
    public var isRunningOutput: Bool

    public init(
        objectID: UInt32, pid: Int32, bundleIdentifier: String?, responsiblePID: Int32? = nil,
        ancestors: [Int32] = [], isRunningOutput: Bool = false
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.responsiblePID = responsiblePID
        self.ancestors = ancestors
        self.isRunningOutput = isRunningOutput
    }
}

/// Finds the processes that play an app's sound. Browsers and Electron
/// apps play from helper processes, Safari (and other WebKit apps) from
/// WebKit's GPU process, which is not their child; so a process belongs to
/// the app when
/// - it is the app (same PID or the same bundle identifier),
/// - the app is responsible for it (XPC helpers, WebKit's GPU process),
/// - it descends from the app (Chromium, Electron and Firefox helpers), or
/// - it published the song (the snapshot's process).
///
/// A similar name alone never adds a process. Ahenk's own processes are
/// never tapped.
public enum AudioProcessMatcher {
    public static let webKitAudioProcess = "com.apple.WebKit.GPU"
    /// Apps whose web audio plays from WebKit's GPU process, used only when
    /// responsibility cannot be read.
    public static let webKitBrowsers: Set<String> = [KnownApps.safari, "com.apple.SafariTechnologyPreview"]

    /// The processes playing `target`'s sound. `appPIDs` are the running
    /// app's own PIDs (from its bundle identifier).
    public static func processes(
        for target: AudioTapTarget, appPIDs: Set<Int32>, in processes: [AudioProcess], ownPID: Int32
    ) -> [AudioProcess] {
        var owners = appPIDs
        if let publisher = target.processIdentifier { owners.insert(publisher) }
        let canReadResponsibility = processes.contains { $0.responsiblePID != nil }
        return processes.filter { process in
            guard !belongsToAhenk(process, ownPID: ownPID) else { return false }
            if owners.contains(process.pid) { return true }
            if let bundle = target.bundleIdentifier, process.bundleIdentifier == bundle { return true }
            if let responsible = process.responsiblePID, responsible != process.pid, owners.contains(responsible) { return true }
            if !owners.isDisjoint(with: process.ancestors) { return true }
            if !canReadResponsibility, process.bundleIdentifier == webKitAudioProcess,
               let bundle = target.bundleIdentifier, webKitBrowsers.contains(bundle) {
                return true
            }
            return false
        }
    }

    /// Ahenk's own processes, left out of a tap on everything.
    public static func ahenkProcesses(in processes: [AudioProcess], ownPID: Int32) -> [AudioProcess] {
        processes.filter { belongsToAhenk($0, ownPID: ownPID) }
    }

    private static func belongsToAhenk(_ process: AudioProcess, ownPID: Int32) -> Bool {
        process.pid == ownPID || process.responsiblePID == ownPID || process.ancestors.contains(ownPID)
    }
}
