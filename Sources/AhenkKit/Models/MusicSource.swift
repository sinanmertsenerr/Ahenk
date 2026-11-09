import Foundation

/// Where a song plays. Raw values are persisted (settings, recently played),
/// so never rename one; add new cases instead.
///
/// Step 2 maps bundle identifiers and browser URLs onto these cases.
public enum MusicSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case appleMusic
    case spotify
    case spotifyWeb
    case youtubeMusic
    case soundCloud
    case amazonMusic
    case deezer
    case tidal
    case youtube
    /// Any other app that publishes system Now Playing information.
    case otherApp
    /// Files Ahenk plays itself (a folder dropped on Continue Playing).
    case local
    /// Invented songs from `DemoProvider` (`--demo`).
    case demo

    public var id: String { rawValue }

    /// The service's own name, which is never translated. `nil` for the
    /// generic sources (`otherApp`, `local`, `demo`), whose labels the app
    /// localizes.
    public var brandName: String? {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .spotifyWeb: "Spotify"
        case .youtubeMusic: "YouTube Music"
        case .soundCloud: "SoundCloud"
        case .amazonMusic: "Amazon Music"
        case .deezer: "Deezer"
        case .tidal: "TIDAL"
        case .youtube: "YouTube"
        case .otherApp, .local, .demo: nil
        }
    }

    /// Played in a web browser and reported by the Ahenk browser extension.
    public var isBrowserBased: Bool {
        switch self {
        case .spotifyWeb, .youtubeMusic, .soundCloud, .amazonMusic, .youtube: true
        // Deezer and TIDAL also have desktop apps; the hub decides per update.
        case .appleMusic, .spotify, .deezer, .tidal, .otherApp, .local, .demo: false
        }
    }

    /// A music site the browser extension reports and controls.
    public var isSite: Bool {
        switch self {
        case .spotifyWeb, .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .youtube: true
        case .appleMusic, .spotify, .otherApp, .local, .demo: false
        }
    }

    /// Sources a user can pick as "where I listen". The catch-all and the
    /// demo are never pinned.
    public static var pinnable: [MusicSource] {
        allCases.filter { $0 != .otherApp && $0 != .demo }
    }
}
