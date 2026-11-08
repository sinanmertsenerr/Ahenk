import Foundation
import Observation

/// Every user setting of Ahenk in one observable, Codable model, persisted
/// to `UserDefaults`.
///
/// - Observation is per group: a view or controller that reads
///   `settings.light` is only invalidated when a light setting changes.
/// - Each change is written back immediately (one JSON-compatible dictionary
///   under `defaultsKey`, readable with `defaults read com.sinanmertsener.Ahenk`).
/// - Decoding is lenient field by field, so documents written by older or
///   newer versions load without resetting unrelated settings.
///
/// Not thread-safe: use it from the main thread only (the app does).
/// Side effects of a change (rebuilding menus, starting a feature) belong to
/// the app, which observes the groups it cares about.
@Observable
public final class AppSettings: Codable {
    /// Bumped when a stored key changes meaning; see `migrate`.
    public static let schemaVersion = 1
    public static let defaultsKey = "settings"

    public var general = GeneralSettings() { didSet { if general != oldValue { persist() } } }
    public var sources = SourceSettings() { didSet { if sources != oldValue { persist() } } }
    public var light = LightSettings() { didSet { if light != oldValue { persist() } } }
    public var player = PlayerSettings() { didSet { if player != oldValue { persist() } } }
    public var lyrics = LyricsSettings() { didSet { if lyrics != oldValue { persist() } } }
    public var wallpaper = WallpaperSettings() { didSet { if wallpaper != oldValue { persist() } } }
    public var dock = DockSettings() { didSet { if dock != oldValue { persist() } } }
    public var audio = AudioAnalysisSettings() { didSet { if audio != oldValue { persist() } } }
    public var effects = SoundEffectSettings() { didSet { if effects != oldValue { persist() } } }
    public var stickers = StickerSettings() { didSet { if stickers != oldValue { persist() } } }
    public var layout = DesktopLayout() { didSet { if layout != oldValue { persist() } } }

    /// How the persisted settings were found at load time.
    public enum Origin: Equatable, Sendable {
        /// Created in memory; nothing is read or written.
        case memory
        /// Nothing was stored yet; defaults are in use.
        case fresh
        /// Loaded from `UserDefaults`.
        case stored(schemaVersion: Int)
        /// The stored value was unreadable and has been replaced by defaults.
        case recovered(reason: String)
    }

    @ObservationIgnored public private(set) var origin: Origin = .memory
    @ObservationIgnored private var store: Store?
    /// Last error from writing to `UserDefaults`, for diagnostics.
    @ObservationIgnored public private(set) var lastSaveError: String?

    /// Default settings, kept in memory only.
    public init() {}

    /// Settings loaded from `defaults` (defaults if nothing usable is
    /// stored); every later change is written back.
    public convenience init(defaults: UserDefaults, key: String = AppSettings.defaultsKey) {
        self.init()
        let store = Store(defaults: defaults, key: key)
        switch store.load() {
        case .missing:
            origin = .fresh
        case .loaded(let stored, let version):
            replaceValues(with: stored)
            origin = .stored(schemaVersion: version)
        case .unreadable(let reason):
            origin = .recovered(reason: reason)
        }
        self.store = store
        if case .recovered = origin { persist() }
    }

    /// An in-memory copy of whatever `defaults` holds. Changes to the copy
    /// are never written back (used by `--smoke`).
    public static func detachedCopy(of defaults: UserDefaults, key: String = AppSettings.defaultsKey) -> AppSettings {
        let copy = AppSettings()
        if case .loaded(let stored, _) = Store(defaults: defaults, key: key).load() {
            copy.replaceValues(with: stored)
        }
        return copy
    }

    /// Copies every group from `other` (persisting once per changed group).
    public func replaceValues(with other: AppSettings) {
        general = other.general
        sources = other.sources
        light = other.light
        player = other.player
        lyrics = other.lyrics
        wallpaper = other.wallpaper
        dock = other.dock
        audio = other.audio
        effects = other.effects
        stickers = other.stickers
        layout = other.layout
    }

    /// Restores every default.
    public func resetToDefaults() {
        replaceValues(with: AppSettings())
    }

    /// True when every setting matches `other`.
    public func hasSameValues(as other: AppSettings) -> Bool {
        general == other.general && sources == other.sources && light == other.light
            && player == other.player && lyrics == other.lyrics && wallpaper == other.wallpaper
            && dock == other.dock && audio == other.audio && effects == other.effects
            && stickers == other.stickers && layout == other.layout
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(self)
            lastSaveError = nil
        } catch {
            lastSaveError = String(describing: error)
            Self.log.error("Could not save settings: \(error)")
        }
    }

    private static let log = AhenkLogger(category: "settings")

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case general, sources, light, player, lyrics, wallpaper, dock, audio, effects, stickers, layout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = c.lenient(.schemaVersion, Self.schemaVersion)
        Self.migrate(from: version)
        general = c.lenient(.general, GeneralSettings())
        sources = c.lenient(.sources, SourceSettings())
        light = c.lenient(.light, LightSettings())
        player = c.lenient(.player, PlayerSettings())
        lyrics = c.lenient(.lyrics, LyricsSettings())
        wallpaper = c.lenient(.wallpaper, WallpaperSettings())
        dock = c.lenient(.dock, DockSettings())
        audio = c.lenient(.audio, AudioAnalysisSettings())
        effects = c.lenient(.effects, SoundEffectSettings())
        stickers = c.lenient(.stickers, StickerSettings())
        layout = c.lenient(.layout, DesktopLayout())
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(general, forKey: .general)
        try c.encode(sources, forKey: .sources)
        try c.encode(light, forKey: .light)
        try c.encode(player, forKey: .player)
        try c.encode(lyrics, forKey: .lyrics)
        try c.encode(wallpaper, forKey: .wallpaper)
        try c.encode(dock, forKey: .dock)
        try c.encode(audio, forKey: .audio)
        try c.encode(effects, forKey: .effects)
        try c.encode(stickers, forKey: .stickers)
        try c.encode(layout, forKey: .layout)
    }

    /// Hook for future key changes. Version 1 is the first schema, so there
    /// is nothing to migrate yet; a newer version's document is read as-is
    /// (unknown keys are ignored, known keys keep working).
    private static func migrate(from storedVersion: Int) {}
}

// MARK: - Storage

extension AppSettings {
    /// Reads and writes the settings document as a property-list dictionary.
    struct Store {
        enum LoadResult {
            case missing
            case loaded(AppSettings, schemaVersion: Int)
            case unreadable(String)
        }

        let defaults: UserDefaults
        let key: String

        func load() -> LoadResult {
            guard let object = defaults.object(forKey: key) else { return .missing }
            guard let dictionary = object as? [String: Any] else {
                return .unreadable("stored value is not a dictionary")
            }
            // A hand-edited domain can hold dates or data, which
            // JSONSerialization rejects with an exception, not an error.
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                return .unreadable("stored value holds non-JSON types")
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: dictionary)
                let settings = try JSONDecoder().decode(AppSettings.self, from: data)
                let version = dictionary[CodingKeys.schemaVersion.rawValue] as? Int ?? AppSettings.schemaVersion
                return .loaded(settings, schemaVersion: version)
            } catch {
                return .unreadable(String(describing: error))
            }
        }

        func save(_ settings: AppSettings) throws {
            let data = try JSONEncoder().encode(settings)
            let object = try JSONSerialization.jsonObject(with: data)
            defaults.set(object, forKey: key)
        }
    }
}
