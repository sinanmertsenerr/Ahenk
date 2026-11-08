import Foundation

/// What an app is, as far as music goes.
public enum AppKind: Sendable, Equatable {
    /// A music service's own app (Apple Music, Spotify, TIDAL, …).
    case musicApp(MusicSource)
    /// A web browser: the site decides the source.
    case browser
    case videoPlayer
    case spokenWordPlayer
    case other
}

/// Maps bundle identifiers onto sources. Holds the browsers found on this
/// Mac on top of the built-in list.
public struct SourceResolver: Sendable, Equatable {
    public private(set) var browserBundleIdentifiers: Set<String>

    public init(additionalBrowsers: Set<String> = []) {
        browserBundleIdentifiers = KnownApps.browsers.union(additionalBrowsers)
    }

    public static let standard = SourceResolver()

    public func kind(of bundleIdentifier: String?) -> AppKind {
        guard let id = bundleIdentifier, !id.isEmpty else { return .other }
        if let source = KnownApps.musicApps[id] { return .musicApp(source) }
        if isBrowser(id) { return .browser }
        if KnownApps.videoPlayers.contains(id) { return .videoPlayer }
        if KnownApps.spokenWordPlayers.contains(id) { return .spokenWordPlayer }
        return .other
    }

    /// Browsers, their installed web apps (`com.google.Chrome.app.…`) and
    /// Safari's web apps (`com.apple.Safari.WebApp.…`).
    public func isBrowser(_ bundleIdentifier: String) -> Bool {
        if browserBundleIdentifiers.contains(bundleIdentifier) { return true }
        if bundleIdentifier.hasPrefix("com.apple.Safari.WebApp.") { return true }
        if let range = bundleIdentifier.range(of: ".app.") {
            return browserBundleIdentifiers.contains(String(bundleIdentifier[..<range.lowerBound]))
        }
        return false
    }

    /// The app that owns a player. WebKit plays from helper processes
    /// (`com.apple.WebKit.GPU`) that name the browser as their parent.
    public static func owner(bundleIdentifier: String?, parent: String?) -> String? {
        if let parent, !parent.isEmpty { return parent }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return bundleIdentifier
    }
}
