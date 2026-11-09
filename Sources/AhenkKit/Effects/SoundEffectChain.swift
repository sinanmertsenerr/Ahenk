import Foundation

/// The room a reverb imitates.
public enum ReverbSpace: String, Sendable, Equatable, CaseIterable {
    case room
    case chamber
    case hall
    case largeHall
    case plate
    case cathedral
}

/// A repeat of the sound that fades away.
public struct SoundEcho: Sendable, Equatable {
    /// Seconds between repeats.
    public var delay: Double
    /// Share of each repeat fed back into the next one (0...0.9).
    public var feedback: Double
    /// Share of the repeats in what is heard (0...1).
    public var mix: Double

    public init(delay: Double, feedback: Double, mix: Double) {
        self.delay = min(2, max(0.01, delay))
        self.feedback = min(0.9, max(0, feedback))
        self.mix = min(1, max(0, mix))
    }
}

/// The sound travelling around the listener's head ("8D").
public struct SoundOrbit: Sendable, Equatable {
    /// Seconds for one trip from the left to the right and back.
    public var period: Double
    /// How far to each side (0 stays in the middle, 1 goes all the way).
    public var depth: Double

    public init(period: Double, depth: Double) {
        self.period = min(60, max(1, period))
        self.depth = min(1, max(0, depth))
    }
}

/// What a preset sets: the values of the sliders, plus the parts no slider
/// reaches (an echo, an orbit, the kind of room).
public struct SoundPresetRecipe: Sendable, Equatable {
    public var speed = 1.0
    /// Semitones.
    public var pitch = 0.0
    public var reverb = 0.0
    public var space: ReverbSpace = .hall
    public var bands = SoundEffectSettings.flatEqualizer
    public var echo: SoundEcho?
    public var orbit: SoundOrbit?
}

public extension SoundPreset {
    /// The preset's own values. `custom` has none: it leaves the sliders
    /// where they are.
    var recipe: SoundPresetRecipe {
        var recipe = SoundPresetRecipe()
        switch self {
        case .custom:
            break
        case .nightcore:
            recipe.speed = 1.25
            recipe.pitch = 4
            recipe.bands = [0, 0, 0, 0, 0, 0, 1, 2, 3, 3]
        case .slowedReverb:
            recipe.speed = 0.85
            recipe.pitch = -3
            recipe.reverb = 0.45
            recipe.space = .largeHall
            recipe.bands = [3, 2, 1, 0, 0, 0, -1, -2, -3, -4]
        case .eightD:
            recipe.reverb = 0.22
            recipe.space = .hall
            recipe.orbit = SoundOrbit(period: 8, depth: 0.9)
        case .bassBoost:
            recipe.bands = [8, 7, 5, 2, 0, 0, 0, 0, 0, 0]
        case .echo:
            recipe.reverb = 0.08
            recipe.space = .room
            recipe.echo = SoundEcho(delay: 0.32, feedback: 0.38, mix: 0.3)
        case .vaporwave:
            recipe.speed = 0.8
            recipe.pitch = -4
            recipe.reverb = 0.3
            recipe.space = .plate
            recipe.bands = [2, 2, 1, 0, 0, 0, -1, -3, -5, -8]
        case .lofi:
            recipe.reverb = 0.12
            recipe.space = .room
            recipe.bands = [-6, -2, 1, 2, 1, 0, -1, -4, -8, -12]
        case .concertHall:
            recipe.reverb = 0.5
            recipe.space = .largeHall
            recipe.bands = [1, 1, 0, 0, -1, 0, 0, 1, 1, 0]
        case .underwater:
            recipe.reverb = 0.2
            recipe.space = .chamber
            recipe.bands = [4, 4, 3, 0, -4, -8, -12, -12, -12, -12]
        }
        return recipe
    }

    /// The preset changes how fast the song plays.
    var changesSpeed: Bool { recipe.speed != 1 }
}

public extension SoundEffectSettings {
    /// Chooses a preset: its values go into the sliders (so they can be
    /// adjusted from there). `custom` keeps the sliders and only drops the
    /// preset's echo, orbit and room.
    mutating func select(_ preset: SoundPreset) {
        self.preset = preset
        guard preset != .custom else { return }
        let recipe = preset.recipe
        speed = recipe.speed
        pitch = recipe.pitch
        reverb = recipe.reverb
        equalizerBands = Self.normalizedBands(recipe.bands)
        equalizerEnabled = recipe.bands.contains { $0 != 0 }
    }

    /// Everything back to an untouched sound (the switch stays as it is).
    mutating func reset() {
        preset = .custom
        speed = 1
        pitch = 0
        reverb = 0
        equalizerEnabled = false
        equalizerBands = Self.flatEqualizer
    }

    /// True when the sliders still hold the preset's own values.
    var matchesPreset: Bool {
        guard preset != .custom else { return true }
        let recipe = preset.recipe
        return speed == recipe.speed && pitch == recipe.pitch && reverb == recipe.reverb
            && (equalizerEnabled ? equalizerBands : Self.flatEqualizer) == Self.normalizedBands(recipe.bands)
    }
}

/// Who can change how fast the followed player plays.
public enum SoundSpeedControl: String, Sendable, Equatable {
    /// Ahenk's own player (song files).
    case ownPlayer
    /// A browser tab, through the extension.
    case browserTab
    /// Nobody: the player has no speed (Apple Music, Spotify, other apps).
    case none
}

/// Everything the audio chain needs to know, worked out from the settings:
/// what each stage does and whether it does anything at all.
///
/// Order of the stages: orbit (the sound moves between the ears) → pitch →
/// equalizer → echo → reverb. Speed is not a stage: only the player itself
/// can play faster or slower.
public struct SoundEffectChain: Sendable, Equatable {
    /// Playback speed asked of the player (1 leaves it alone).
    public var speed = 1.0
    /// Pitch shift in cents (100 per semitone).
    public var pitchCents = 0.0
    /// Reverb's share of what is heard (0...1).
    public var reverbMix = 0.0
    public var space: ReverbSpace = .hall
    /// One gain in dB per entry of `SoundEffectSettings.equalizerFrequencies`.
    public var equalizerGains = SoundEffectSettings.flatEqualizer
    public var echo: SoundEcho?
    public var orbit: SoundOrbit?

    public init() {}

    /// The chain the settings ask for; neutral while the switch is off.
    public init(_ settings: SoundEffectSettings) {
        guard settings.enabled else { return }
        let recipe = settings.preset.recipe
        speed = settings.speed.clamped(to: SoundEffectSettings.speedRange)
        pitchCents = settings.pitch.clamped(to: SoundEffectSettings.pitchRange) * 100
        reverbMix = settings.reverb.clamped(to: SoundEffectSettings.reverbRange)
        space = recipe.space
        equalizerGains = settings.equalizerEnabled ? SoundEffectSettings.normalizedBands(settings.equalizerBands) : SoundEffectSettings.flatEqualizer
        echo = recipe.echo
        orbit = recipe.orbit
    }

    public static let neutral = SoundEffectChain()

    public var shiftsPitch: Bool { abs(pitchCents) >= 1 }
    public var equalizes: Bool { equalizerGains.contains { abs($0) >= 0.05 } }
    public var reverberates: Bool { reverbMix >= 0.005 }
    public var echoes: Bool { (echo?.mix ?? 0) >= 0.005 }
    public var orbits: Bool { (orbit?.depth ?? 0) >= 0.005 }
    public var changesSpeed: Bool { abs(speed - 1) >= 0.005 }

    /// The sound itself is changed (speed aside): there is work for the
    /// audio chain.
    public var processesSound: Bool { shiftsPitch || equalizes || reverberates || echoes || orbits }

    /// Nothing to do at all.
    public var isNeutral: Bool { !processesSound && !changesSpeed }

    /// The chain for a player whose speed is controlled as `control` says:
    /// a player without a speed keeps playing at its own.
    public func adapted(to control: SoundSpeedControl) -> SoundEffectChain {
        guard control == .none else { return self }
        var chain = self
        chain.speed = 1
        return chain
    }

    /// Gain in dB taken off before the equalizer so that boosted bands do
    /// not clip: most of the largest boost.
    public var headroom: Double {
        let boost = equalizerGains.max() ?? 0
        return boost > 0 ? -boost * 0.6 : 0
    }
}
