import Foundation

/// Facts about the running build.
enum AppInfo {
    static let bundleIdentifier = "com.sinanmertsener.Ahenk"
    static let repositoryURL = URL(string: "https://github.com/sinanmertsenerr/Ahenk")!

    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var version: String { info["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { info["CFBundleVersion"] as? String ?? "0" }
    /// Short commit hash stamped by make-app.sh.
    static var commit: String { info["AhenkGitCommit"] as? String ?? "unknown" }

    /// Running from an assembled `.app` (not `swift run`).
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == bundleIdentifier
    }

    /// `Contents/Resources/adapter` with the MediaRemote adapter assets.
    static var adapterDirectory: URL? {
        guard isBundled else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("adapter", isDirectory: true)
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static var launchSummary: String {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "Ahenk \(version) (\(build), \(commit)), \(system), \(architecture), pid \(ProcessInfo.processInfo.processIdentifier)"
    }
}
