import Foundation

// The groups that make up `AppSettings`, one per Settings pane / feature.
//
// Rules for adding a setting:
// - Give it a default in the declaration; that is what fresh installs and
//   documents written by older versions get.
// - Decode it leniently in the group's `init(from:)`. The round-trip test in
//   AppSettingsTests fails if a property is not decoded.
// - Property names are the on-disk keys: never rename one without a
//   migration in `AppSettings.migrate`.
// - Numeric settings declare their range here; sliders use the same range and
//   decoding clamps to it.

// MARK: - General

public struct GeneralSettings: Codable, Equatable, Sendable {
    public var language: AppLanguage = .english
    /// Settings › General › Optimized mode: fewer particles, lower frame
    /// rates, smaller video.
    public var optimizedMode = false
    /// Switch to the lighter mode by itself on battery, in Low Power Mode or
    /// with Energy Saver on.
    public var lighterOnBattery = true
    /// Show the song title next to the menu bar icon (the menu itself always
    /// lists the current song).
    public var showSongTitleInMenuBar = false
    /// Two-letter store country for catalog lookups (albums, search, motion
    /// artwork). `nil` follows the Mac's region.
    public var storefront: String?
    /// First-run onboarding (Step 11) finished.
    public var onboardingCompleted = false
    /// Write debug-level lines to the log file as well.
    public var verboseLogging = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        language = c.lenient(.language, d.language)
        optimizedMode = c.lenient(.optimizedMode, d.optimizedMode)
        lighterOnBattery = c.lenient(.lighterOnBattery, d.lighterOnBattery)
        showSongTitleInMenuBar = c.lenient(.showSongTitleInMenuBar, d.showSongTitleInMenuBar)
        storefront = Self.validStorefront(c.lenientOptional(.storefront))
        onboardingCompleted = c.lenient(.onboardingCompleted, d.onboardingCompleted)
        verboseLogging = c.lenient(.verboseLogging, d.verboseLogging)
    }

    /// Upper-cased two-letter code, or `nil` for anything else.
    public static func validStorefront(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(),
              code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return code
    }
}

// MARK: - Sources

public struct SourceSettings: Codable, Equatable, Sendable {
    public static let portRange: ClosedRange<Int> = 1024...49151

    public var selection: SourceSelection = .automatic
    /// When two sources play at once, ask which one to follow instead of
    /// switching silently.
    public var askWhenSeveralPlay = true
    /// Pause the previous source when the user switches to another one.
    public var pauseOthersOnSwitch = true
    /// Sources whose playback is ignored entirely.
    public var ignoredSources: Set<MusicSource> = []
    /// Accept connections from the Ahenk browser extension (Step 7).
    public var browserBridgeEnabled = true
    /// Local WebSocket port (127.0.0.1 only) shared with the extension.
    public var browserBridgePort = 42_617

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        selection = c.lenient(.selection, d.selection)
        askWhenSeveralPlay = c.lenient(.askWhenSeveralPlay, d.askWhenSeveralPlay)
        pauseOthersOnSwitch = c.lenient(.pauseOthersOnSwitch, d.pauseOthersOnSwitch)
        ignoredSources = c.lenientSet(.ignoredSources, d.ignoredSources)
        browserBridgeEnabled = c.lenient(.browserBridgeEnabled, d.browserBridgeEnabled)
        browserBridgePort = c.lenient(.browserBridgePort, d.browserBridgePort, in: Self.portRange)
    }
}

// MARK: - Edge light

public struct LightSettings: Codable, Equatable, Sendable {
    /// Line thickness in points.
    public static let thicknessRange: ClosedRange<Double> = 2...40
    public static let glowRange: ClosedRange<Double> = 0...1
    public static let intensityRange: ClosedRange<Double> = 0...1
    /// Animation speed multiplier.
    public static let speedRange: ClosedRange<Double> = 0.25...3
    public static let maxCustomColors = 4

    public var enabled = true
    public var style: LightStyle = .glow
    public var position: LightPosition = .allEdges
    public var thickness = 10.0
    public var glow = 0.6
    public var intensity = 0.8
    public var speed = 1.0
    public var colorSource: LightColorSource = .album
    /// Used when `colorSource == .custom`; 1 to `maxCustomColors` colours.
    public var customColors: [SRGBColor] = [SRGBColor("#FF4F8B"), SRGBColor("#7C5CFF")]
    /// Stable display identifiers (CGDisplay UUIDs) where the light is off.
    /// Every other display, including new ones, shows it.
    public var disabledDisplays: Set<String> = []
    /// Draw only while the desktop is in front; step back when an app is.
    public var onlyOnDesktop = false
    /// Hide on a display while an app is full screen there.
    public var stepAsideInFullScreen = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.lenient(.enabled, d.enabled)
        style = c.lenient(.style, d.style)
        position = c.lenient(.position, d.position)
        thickness = c.lenient(.thickness, d.thickness, in: Self.thicknessRange)
        glow = c.lenient(.glow, d.glow, in: Self.glowRange)
        intensity = c.lenient(.intensity, d.intensity, in: Self.intensityRange)
        speed = c.lenient(.speed, d.speed, in: Self.speedRange)
        colorSource = c.lenient(.colorSource, d.colorSource)
        let colors: [SRGBColor] = c.lenientArray(.customColors, d.customColors)
        customColors = colors.isEmpty ? d.customColors : Array(colors.prefix(Self.maxCustomColors))
        disabledDisplays = c.lenient(.disabledDisplays, d.disabledDisplays)
        onlyOnDesktop = c.lenient(.onlyOnDesktop, d.onlyOnDesktop)
        stepAsideInFullScreen = c.lenient(.stepAsideInFullScreen, d.stepAsideInFullScreen)
    }

    public func isEnabled(onDisplay displayID: String) -> Bool {
        enabled && !disabledDisplays.contains(displayID)
    }
}

// MARK: - Desktop player

public struct PlayerSettings: Codable, Equatable, Sendable {
    /// Size of the clock's digits relative to the default.
    public static let clockScaleRange: ClosedRange<Double> = 0.6...1.4

    public var enabled = true
    public var size: PlayerSize = .large
    /// Display (CGDisplay UUID) that shows the player, clock and lyrics.
    /// `nil` is the display with the menu bar.
    public var displayID: String?
    public var showClock = true
    public var showDate = true
    public var clockFormat: ClockFormat = .system
    public var clockScale = 1.0
    public var showContinuePlaying = true
    /// The artist's albums as a cover flow.
    public var showAlbums = true
    public var showSearch = true
    public var showPlayerBar = true
    /// Where picks from search, albums and lists play (the source picker at
    /// the left of the player). `nil` follows the source that plays.
    public var listeningSource: MusicSource?
    /// Start every song at 0:15.
    public var startAtFifteenSeconds = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.lenient(.enabled, d.enabled)
        size = c.lenient(.size, d.size)
        displayID = c.lenientOptional(.displayID)
        showClock = c.lenient(.showClock, d.showClock)
        showDate = c.lenient(.showDate, d.showDate)
        clockFormat = c.lenient(.clockFormat, d.clockFormat)
        clockScale = c.lenient(.clockScale, d.clockScale, in: Self.clockScaleRange)
        showContinuePlaying = c.lenient(.showContinuePlaying, d.showContinuePlaying)
        showAlbums = c.lenient(.showAlbums, d.showAlbums)
        showSearch = c.lenient(.showSearch, d.showSearch)
        showPlayerBar = c.lenient(.showPlayerBar, d.showPlayerBar)
        listeningSource = c.lenientOptional(.listeningSource)
        startAtFifteenSeconds = c.lenient(.startAtFifteenSeconds, d.startAtFifteenSeconds)
    }
}

// MARK: - Lyrics

public struct LyricsSettings: Codable, Equatable, Sendable {
    public static let textScaleRange: ClosedRange<Double> = 0.6...1.6
    /// Global timing offset in seconds, positive shows the lines earlier
    /// (per-song nudges live in `LyricsSongStore`).
    public static let offsetRange: ClosedRange<Double> = -5...5

    public var enabled = true
    public var style: LyricStyle = .fisheye
    /// Where the lyrics sit until they are dragged (choosing one forgets
    /// the dragged place).
    public var position: LyricsPosition = .abovePlayer
    /// Show the album cover beside the lyrics.
    public var showAlbumArt = true
    public var textScale = 1.0
    /// Colour the lines from the album palette (otherwise white).
    public var useAlbumColors = true
    /// Music note with a countdown to the next line in instrumental parts.
    public var instrumentalCountdown = true
    /// Measure and correct timing from the playing audio.
    public var autoSync = true
    public var globalOffset = 0.0
    /// Provider names (`LyricsProvider.name`) the chain skips. New providers
    /// are on by default.
    public var disabledProviders: Set<String> = []
    /// Offer on-device alignment of plain lyrics with whisper (Beta).
    public var localAlignment = true
    /// Overrides for the whisper tools; `nil` uses auto-detection.
    public var whisperExecutablePath: String?
    public var whisperModelPath: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.lenient(.enabled, d.enabled)
        style = c.lenient(.style, d.style)
        position = c.lenient(.position, d.position)
        showAlbumArt = c.lenient(.showAlbumArt, d.showAlbumArt)
        textScale = c.lenient(.textScale, d.textScale, in: Self.textScaleRange)
        useAlbumColors = c.lenient(.useAlbumColors, d.useAlbumColors)
        instrumentalCountdown = c.lenient(.instrumentalCountdown, d.instrumentalCountdown)
        autoSync = c.lenient(.autoSync, d.autoSync)
        globalOffset = c.lenient(.globalOffset, d.globalOffset, in: Self.offsetRange)
        disabledProviders = c.lenient(.disabledProviders, d.disabledProviders)
        localAlignment = c.lenient(.localAlignment, d.localAlignment)
        whisperExecutablePath = c.lenientOptional(.whisperExecutablePath)
        whisperModelPath = c.lenientOptional(.whisperModelPath)
    }
}

// MARK: - Live wallpaper

public struct WallpaperSettings: Codable, Equatable, Sendable {
    /// Crossfade between the user's wallpaper and the video, in seconds.
    public static let crossfadeRange: ClosedRange<Double> = 0.2...5
    /// Darkening over the video so widgets stay readable.
    public static let dimmingRange: ClosedRange<Double> = 0...0.8

    public var enabled = true
    public var useMotionArtwork = true
    /// The song's music video, or another video by the same artist.
    public var useMusicVideos = true
    /// Slow-moving, blurred album cover when no video is found.
    public var useArtworkFallback = true
    public var crossfadeDuration = 1.2
    public var dimming = 0.15
    /// The user's own list of desktop videos.
    public var savedVideos: [SavedVideo] = []
    /// A saved video pinned as the wallpaper; `nil` follows the song.
    public var selectedVideoID: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.lenient(.enabled, d.enabled)
        useMotionArtwork = c.lenient(.useMotionArtwork, d.useMotionArtwork)
        useMusicVideos = c.lenient(.useMusicVideos, d.useMusicVideos)
        useArtworkFallback = c.lenient(.useArtworkFallback, d.useArtworkFallback)
        crossfadeDuration = c.lenient(.crossfadeDuration, d.crossfadeDuration, in: Self.crossfadeRange)
        dimming = c.lenient(.dimming, d.dimming, in: Self.dimmingRange)
        savedVideos = c.lenientArray(.savedVideos, d.savedVideos)
        let selected: String? = c.lenientOptional(.selectedVideoID)
        selectedVideoID = savedVideos.contains { $0.id == selected } ? selected : nil
    }
}

// MARK: - Dock

public struct DockSettings: Codable, Equatable, Sendable {
    /// The Dock icon becomes the current album cover.
    public var albumArtIcon = true
    /// A ring around the cover that beats along.
    public var beatRing = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        albumArtIcon = c.lenient(.albumArtIcon, d.albumArtIcon)
        beatRing = c.lenient(.beatRing, d.beatRing)
    }
}

// MARK: - Audio analysis

public struct AudioAnalysisSettings: Codable, Equatable, Sendable {
    /// Gain applied to the analysed levels before they reach the visuals.
    public static let sensitivityRange: ClosedRange<Double> = 0.25...3

    public var sensitivity = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        sensitivity = c.lenient(.sensitivity, d.sensitivity, in: Self.sensitivityRange)
    }
}

// MARK: - Sound effects

public struct SoundEffectSettings: Codable, Equatable, Sendable {
    public static let speedRange: ClosedRange<Double> = 0.5...2
    /// Semitones.
    public static let pitchRange: ClosedRange<Double> = -12...12
    /// Reverb wet mix.
    public static let reverbRange: ClosedRange<Double> = 0...1
    /// Equalizer gain in dB.
    public static let gainRange: ClosedRange<Double> = -12...12
    /// Centre frequencies of the 10 equalizer bands, in Hz.
    public static let equalizerFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let flatEqualizer = [Double](repeating: 0, count: 10)

    /// The effects button beside the lyrics.
    public var enabled = false
    public var preset: SoundPreset = .custom
    public var speed = 1.0
    public var pitch = 0.0
    public var reverb = 0.0
    public var equalizerEnabled = false
    /// One gain per entry of `equalizerFrequencies`.
    public var equalizerBands = SoundEffectSettings.flatEqualizer

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.lenient(.enabled, d.enabled)
        preset = c.lenient(.preset, d.preset)
        speed = c.lenient(.speed, d.speed, in: Self.speedRange)
        pitch = c.lenient(.pitch, d.pitch, in: Self.pitchRange)
        reverb = c.lenient(.reverb, d.reverb, in: Self.reverbRange)
        equalizerEnabled = c.lenient(.equalizerEnabled, d.equalizerEnabled)
        equalizerBands = Self.normalizedBands(c.lenient(.equalizerBands, d.equalizerBands))
    }

    /// Exactly 10 finite gains inside `gainRange`; missing bands are flat.
    public static func normalizedBands(_ bands: [Double]) -> [Double] {
        (0..<equalizerFrequencies.count).map { index in
            guard index < bands.count, bands[index].isFinite else { return 0 }
            return bands[index].clamped(to: gainRange)
        }
    }
}

// MARK: - Stickers

public struct StickerSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// White cut-out border around each sticker.
    public var border = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.lenient(.enabled, d.enabled)
        border = c.lenient(.border, d.border)
    }
}

// MARK: - Desktop layout

/// Where the user dragged each desktop widget, per display.
public struct DesktopLayout: Codable, Equatable, Sendable {
    /// Keyed by `key(widget:display:)`.
    public var positions: [String: NormalizedPoint] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positions = c.lenient(.positions, [:])
    }

    public static func key(widget: String, display: String) -> String {
        "\(display)/\(widget)"
    }

    public func position(of widget: String, on display: String) -> NormalizedPoint? {
        positions[Self.key(widget: widget, display: display)]
    }

    public mutating func setPosition(_ point: NormalizedPoint?, of widget: String, on display: String) {
        positions[Self.key(widget: widget, display: display)] = point
    }

    /// Forget every widget position on one display (back to the defaults).
    public mutating func resetPositions(on display: String) {
        positions = positions.filter { !$0.key.hasPrefix("\(display)/") }
    }
}
