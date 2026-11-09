import Foundation

/// The browser app behind a connection, when the socket cannot tell: the
/// bundle identifiers that the name the extension reports may stand for,
/// most likely first (the app checks which one runs).
public enum BrowserIdentity {
    public static func bundleCandidates(for browser: BridgeBrowser) -> [String] {
        let names = ([browser.name] + (browser.brands ?? [])).map { $0.lowercased() }
        func any(_ fragment: String) -> Bool { names.contains { $0.contains(fragment) } }
        var result: [String] = []
        if any("edge") { result += ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"] }
        if any("brave") { result += ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"] }
        if any("opera") { result += ["com.operasoftware.Opera", "com.operasoftware.OperaGX"] }
        if any("vivaldi") { result += ["com.vivaldi.Vivaldi"] }
        if any("arc") { result += ["company.thebrowser.Browser"] }
        if any("firefox") { result += ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen"] }
        if any("google chrome") || browser.name.lowercased() == "chrome" {
            result += ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]
        }
        if any("chromium") || result.isEmpty {
            // Chromium-based browsers that say only "Chromium" (Arc, the
            // Search browser, Chromium itself) or nothing useful.
            result += ["org.chromium.Chromium", KnownApps.search, "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome"]
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
