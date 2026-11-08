import Foundation

/// The feature switches in the menu bar extra and the Dock menu.
public enum QuickToggle: String, CaseIterable, Sendable, Identifiable {
    case edgeLight
    case desktopPlayer
    case lyrics
    case liveWallpaper
    case dockArt

    public var id: String { rawValue }

    /// The setting this switch flips.
    public var keyPath: ReferenceWritableKeyPath<AppSettings, Bool> {
        switch self {
        case .edgeLight: \AppSettings.light.enabled
        case .desktopPlayer: \AppSettings.player.enabled
        case .lyrics: \AppSettings.lyrics.enabled
        case .liveWallpaper: \AppSettings.wallpaper.enabled
        case .dockArt: \AppSettings.dock.albumArtIcon
        }
    }
}

extension AppSettings {
    public func isOn(_ toggle: QuickToggle) -> Bool {
        self[keyPath: toggle.keyPath]
    }

    public func flip(_ toggle: QuickToggle) {
        self[keyPath: toggle.keyPath].toggle()
    }
}
