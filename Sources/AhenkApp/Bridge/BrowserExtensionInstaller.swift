import AhenkKit
import AppKit

/// Where the browser extension's files are, and "Install Browser
/// Extension…": shows the folder in Finder and the few steps a browser
/// needs to load it (Ahenk never installs anything into a browser itself).
///
/// The app carries two ready folders in `Contents/Resources/Extension`:
/// `Chromium` (Chrome, Edge, Brave, Arc, Opera, Vivaldi, Search) and
/// `Firefox`. A development run (`swift run`) uses the repository's
/// `Extension` folder, which is the Chromium variant.
@MainActor
enum BrowserExtensionInstaller {
    static let symbolName = "puzzlepiece.extension"

    /// The folder to load in a Chromium browser.
    static var chromiumFolder: URL? {
        if let bundled = bundledFolder?.appendingPathComponent("Chromium", isDirectory: true), hasManifest(bundled) { return bundled }
        return repositoryFolder
    }

    /// The folder whose `manifest.json` Firefox loads.
    static var firefoxFolder: URL? {
        guard let bundled = bundledFolder?.appendingPathComponent("Firefox", isDirectory: true), hasManifest(bundled) else { return nil }
        return bundled
    }

    private static var bundledFolder: URL? {
        guard AppInfo.isBundled else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("Extension", isDirectory: true)
    }

    /// `swift run` from the repository: `<repo>/Extension`.
    private static var repositoryFolder: URL? {
        #if DEBUG
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = repository.appendingPathComponent("Extension", isDirectory: true)
        return hasManifest(folder) ? folder : nil
        #else
        return nil
        #endif
    }

    private static func hasManifest(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
    }

    /// Shows the folders in Finder and the steps.
    static func present() {
        guard let chromium = chromiumFolder else {
            NSApp.activate(ignoringOtherApps: true)
            missingAlert().runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([chromium] + (firefoxFolder.map { [$0] } ?? []))
        NSApp.activate(ignoringOtherApps: true)
        if stepsAlert().runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chromium.path, forType: .string)
        }
    }

    /// The steps, for each kind of browser (also drawn by `--smoke --snapshots`).
    static func stepsAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Install the Ahenk Browser Extension".l10n
        alert.informativeText = [
            "Finder shows the extension's folders. In Chrome, Edge, Brave, Arc or another Chromium browser:".l10n,
            "1. Open the extensions page (chrome://extensions, edge://extensions, brave://extensions, arc://extensions).".l10n,
            "2. Turn on Developer mode.".l10n,
            "3. Click Load unpacked and choose the Chromium folder.".l10n,
            "In the Search browser: click the puzzle button, then Load Unpacked…, and choose the Chromium folder.".l10n,
            "In Firefox: open about:debugging, choose This Firefox, click Load Temporary Add-on… and pick manifest.json in the Firefox folder. Firefox removes it when it quits.".l10n,
            "Then open a music site. Ahenk sees it within a few seconds; the extension's button shows the connection.".l10n,
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: "OK".l10n)
        alert.addButton(withTitle: "Copy Folder Path".l10n)
        return alert
    }

    private static func missingAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The browser extension is missing from this copy of Ahenk.".l10n
        alert.informativeText = "Build Ahenk with Scripts/make-app.sh to include it.".l10n
        return alert
    }
}
