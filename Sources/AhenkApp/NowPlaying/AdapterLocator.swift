import AhenkKit
import Foundation

/// Finds the bundled `mediaremote-adapter`.
///
/// A packaged app uses only its own `Contents/Resources/adapter`, so nothing
/// outside the signed bundle can redirect what runs under perl. Unbundled
/// development runs (`swift run`) look for the source tree's
/// `Vendor/mediaremote-adapter` next to the executable's folders; debug
/// builds also honour `AHENK_ADAPTER_DIR` and the current directory.
enum AdapterLocator {
    static func invocation() -> MediaRemoteAdapter.Invocation? {
        if let directory = AppInfo.adapterDirectory {
            return .bundled(in: directory)
        }
        guard !AppInfo.isBundled else { return nil }

        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["AHENK_ADAPTER_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if let found = MediaRemoteAdapter.Invocation.bundled(in: url) ?? .sourceTree(at: url) { return found }
        }
        #endif

        // `.build/<triple>/<config>/Ahenk` → up to the package root.
        var directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = directory else { break }
            if let found = MediaRemoteAdapter.Invocation.sourceTree(at: current.appendingPathComponent("Vendor/mediaremote-adapter")) {
                return found
            }
            directory = current.deletingLastPathComponent()
        }

        #if DEBUG
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return .sourceTree(at: workingDirectory.appendingPathComponent("Vendor/mediaremote-adapter"))
        #else
        return nil
        #endif
    }
}
