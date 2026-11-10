import AhenkKit
import Foundation

// Localized names for the setting options. Kept together so the English
// wording and the Turkish table are easy to review side by side.

extension LightStyle {
    @MainActor
    var title: String {
        switch self {
        case .glow: "Soft Glow".l10n
        case .pulse: "Pulse".l10n
        case .breathe: "Breathe".l10n
        case .wave: "Wave".l10n
        case .spectrum: "Spectrum".l10n
        case .snake: "Snake".l10n
        case .twinSnakes: "Twin Snakes".l10n
        case .lava: "Lava".l10n
        case .aurora: "Aurora".l10n
        case .rainbow: "Rainbow".l10n
        case .neonTube: "Neon Tube".l10n
        case .plasma: "Plasma".l10n
        case .fire: "Fire".l10n
        case .embers: "Embers".l10n
        case .snow: "Snow".l10n
        case .hearts: "Hearts".l10n
        case .fireworks: "Fireworks".l10n
        case .sparkles: "Sparkles".l10n
        case .bubbles: "Bubbles".l10n
        case .lightning: "Lightning".l10n
        case .rain: "Rain".l10n
        case .starfield: "Starfield".l10n
        }
    }
}

extension LightPosition {
    @MainActor
    var title: String {
        switch self {
        case .allEdges: "All Edges".l10n
        case .bottom: "Bottom".l10n
        case .top: "Top".l10n
        case .corners: "Corners".l10n
        }
    }
}

extension LightColorSource {
    @MainActor
    var title: String {
        switch self {
        case .album: "Album Cover".l10n
        case .custom: "Custom".l10n
        case .rainbow: "Rainbow".l10n
        }
    }
}

extension PlayerSize {
    @MainActor
    var title: String {
        switch self {
        case .small: "Small".l10n
        case .large: "Large".l10n
        }
    }
}

extension ClockFormat {
    @MainActor
    var title: String {
        switch self {
        case .system: "Same as the System".l10n
        case .twelveHour: "12-Hour".l10n
        case .twentyFourHour: "24-Hour".l10n
        }
    }
}

extension LyricStyle {
    @MainActor
    var title: String {
        switch self {
        case .plain: "Plain".l10n
        case .glitch: "Glitch".l10n
        case .cinema: "Cinema".l10n
        case .karaoke: "Karaoke".l10n
        case .typewriter: "Typewriter".l10n
        case .drift: "Drift".l10n
        }
    }
}

extension LyricsPosition {
    @MainActor
    var title: String {
        switch self {
        case .abovePlayer: "Above the Player".l10n
        case .middle: "Middle of the Screen".l10n
        case .top: "Top of the Screen".l10n
        }
    }
}

extension SoundPreset {
    @MainActor
    var title: String {
        switch self {
        case .custom: "Custom".l10n
        case .nightcore: "Nightcore"
        case .slowedReverb: "Slowed + Reverb"
        case .eightD: "8D Audio".l10n
        case .bassBoost: "Bass Boost".l10n
        case .echo: "Echo".l10n
        case .vaporwave: "Vaporwave"
        case .lofi: "Lo-fi"
        case .concertHall: "Concert Hall".l10n
        case .underwater: "Underwater".l10n
        }
    }
}

extension MusicSource {
    /// Brand names stay as they are; generic sources are translated.
    @MainActor
    var title: String {
        switch self {
        case .spotifyWeb: "Spotify Web Player".l10n
        case .otherApp: "Other Apps".l10n
        case .local: "Files on This Mac".l10n
        case .demo: "Demo".l10n
        default: brandName ?? rawValue
        }
    }
}

extension SourceSelection {
    @MainActor
    var title: String {
        switch self {
        case .automatic: "Automatic".l10n
        case .pinned(let source): source.title
        }
    }
}
