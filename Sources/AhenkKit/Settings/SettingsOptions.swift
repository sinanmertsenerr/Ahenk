import Foundation

// Option types used by `AppSettings`. Raw values are stored on disk: never
// rename one. Unknown raw values decode to the setting's default, so removing
// a case is safe. Display names live in the app (localized).

/// UI language. An explicit in-app choice that does not follow the system
/// language; English is the default.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    case turkish = "tr"

    public var id: String { rawValue }

    /// The language's own name, shown untranslated in the language picker.
    public var nativeName: String {
        switch self {
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    /// Locale for formatting dates and numbers in this language, keeping the
    /// user's region (so English on a Turkish Mac still writes 08.11.2026).
    public func locale(region: Locale.Region? = Locale.current.region) -> Locale {
        Locale(languageCode: Locale.LanguageCode(rawValue), languageRegion: region)
    }
}

/// Which song the app follows when several sources play.
public enum SourceSelection: Hashable, Sendable, Codable {
    /// The source that started playing most recently.
    case automatic
    case pinned(MusicSource)

    /// `"automatic"` or a `MusicSource` raw value.
    public var rawValue: String {
        switch self {
        case .automatic: "automatic"
        case .pinned(let source): source.rawValue
        }
    }

    public init(rawValue: String) {
        if let source = MusicSource(rawValue: rawValue) {
            self = .pinned(source)
        } else {
            self = .automatic
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Edge light styles (Step 4 renders each one).
public enum LightStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case glow
    case pulse
    case breathe
    case wave
    case spectrum
    case snake
    case twinSnakes
    case lava
    case aurora
    case rainbow
    case neonTube
    case plasma
    case fire
    case embers
    case snow
    case hearts
    case fireworks
    case sparkles
    case bubbles
    case lightning
    case rain
    case starfield

    public var id: String { rawValue }
}

/// Which part of the screen edge lights up.
public enum LightPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case allEdges
    case bottom
    case top
    case corners

    public var id: String { rawValue }
}

/// Where the light takes its colours from.
public enum LightColorSource: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The palette of the current album cover.
    case album
    /// `LightSettings.customColors`.
    case custom
    case rainbow

    public var id: String { rawValue }
}

public enum PlayerSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case small
    case large

    public var id: String { rawValue }
}

public enum ClockFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Follows the system's 12/24-hour preference.
    case system
    case twelveHour
    case twentyFourHour

    public var id: String { rawValue }
}

/// Desktop lyrics styles (Step 6), each with its own font.
public enum LyricStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Nothing but the words, one line after another (the default).
    case plain
    /// A line decodes out of random characters.
    case glitch
    /// A film title: a slow fade and a hairline.
    case cinema
    /// The whole line lights up as it is sung.
    case karaoke
    case typewriter
    /// Calm: words surface, sway and float away.
    case drift

    public var id: String { rawValue }
}

/// Where the lyrics sit on the desktop until the user drags them.
public enum LyricsPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Above the player, at its middle.
    case abovePlayer
    case middle
    case top

    public var id: String { rawValue }
}

/// Sound effect presets (Step 10). `custom` uses the manual speed, pitch,
/// reverb and equalizer values as they are.
public enum SoundPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case custom
    case nightcore
    case slowedReverb
    case eightD
    case bassBoost
    case echo
    case vaporwave
    case lofi
    case concertHall
    case underwater

    public var id: String { rawValue }
}

/// A video the user added to the live wallpaper list (Step 8).
public struct SavedVideo: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// `reference` is a YouTube video ID, played in an embedded player.
        case youtube
        /// `reference` is an absolute file path.
        case file
        /// `reference` is the web address of a video file or stream
        /// (`https://…`), played with AVPlayer while it shows.
        case url
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var reference: String
    public var addedAt: Date

    public init(id: String = UUID().uuidString, title: String, kind: Kind, reference: String, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.kind = kind
        self.reference = reference
        self.addedAt = addedAt
    }
}

/// A position relative to a screen's visible frame: (0, 0) is the bottom-left
/// corner, (1, 1) the top-right. Survives resolution changes.
public struct NormalizedPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = Self.unit(x)
        self.y = Self.unit(y)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    private enum CodingKeys: String, CodingKey { case x, y }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}
