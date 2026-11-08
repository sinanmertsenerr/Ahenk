import Observation
import SwiftUI

/// The sidebar of the Settings window.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case sources
    case light
    case player
    case lyrics
    case wallpaper
    case sound
    case stickers
    case about

    var id: String { rawValue }

    /// Sidebar groups, separated by a little space.
    static let groups: [[SettingsPane]] = [
        [.general, .sources],
        [.light, .player, .lyrics, .wallpaper],
        [.sound, .stickers],
        [.about],
    ]

    @MainActor
    var title: String {
        switch self {
        case .general: "General".l10n
        case .sources: "Sources".l10n
        case .light: "Edge Light".l10n
        case .player: "Desktop Player".l10n
        case .lyrics: "Lyrics".l10n
        case .wallpaper: "Live Wallpaper".l10n
        case .sound: "Sound".l10n
        case .stickers: "Stickers".l10n
        case .about: "About".l10n
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .sources: "music.note.list"
        case .light: "light.max"
        case .player: "play.rectangle.fill"
        case .lyrics: "quote.bubble.fill"
        case .wallpaper: "photo.on.rectangle.angled"
        case .sound: "speaker.wave.2.fill"
        case .stickers: "face.smiling.inverse"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .sources: Color(red: 0.98, green: 0.27, blue: 0.38)
        case .light: Color(red: 1.0, green: 0.62, blue: 0.1)
        case .player: Color(red: 0.2, green: 0.5, blue: 1.0)
        case .lyrics: Color(red: 0.62, green: 0.38, blue: 0.98)
        case .wallpaper: Color(red: 0.1, green: 0.72, blue: 0.75)
        case .sound: Color(red: 0.98, green: 0.3, blue: 0.62)
        case .stickers: Color(red: 0.98, green: 0.78, blue: 0.1)
        case .about: Color(white: 0.55)
        }
    }

    /// Parses the value of `--settings` ("light", "Lyrics", …).
    init?(argument: String) {
        guard let pane = SettingsPane(rawValue: argument.lowercased()) else { return nil }
        self = pane
    }
}

/// Which pane the Settings window shows.
@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsPane? = .general
}
