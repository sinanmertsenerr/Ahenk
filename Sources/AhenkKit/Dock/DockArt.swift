import Foundation

/// What the Dock icon shows.
public enum DockArtMode: Equatable, Sendable {
    /// Ahenk's own icon: nothing plays, or Dock Art is off.
    case appIcon
    /// The cover with a calm ring, drawn once and left alone (paused, the
    /// ring turned off, Low Power Mode).
    case still
    /// The cover with a ring that beats along, redrawn at most this often.
    case animated(framesPerSecond: Int)

    public var framesPerSecond: Int {
        if case .animated(let fps) = self { return fps }
        return 0
    }
}

/// What decides the Dock icon's mode.
public struct DockArtInputs: Equatable, Sendable {
    /// Settings › Dock Art (the menu's quick toggle).
    public var enabled: Bool
    /// The ring beats along (otherwise it stays still).
    public var beatRing: Bool
    /// A song is followed (music, by the light's rule: never a video, a
    /// podcast or an advert) and its cover is known.
    public var hasCover: Bool
    /// Music plays (the light's rule: music or unlabelled content).
    public var isPlaying: Bool
    public var lighterOnBattery: Bool
    public var isOnBattery: Bool
    public var isLowPowerMode: Bool
    public var isThermallyConstrained: Bool

    public init(
        enabled: Bool = true, beatRing: Bool = true, hasCover: Bool = true, isPlaying: Bool = true,
        lighterOnBattery: Bool = true, isOnBattery: Bool = false,
        isLowPowerMode: Bool = false, isThermallyConstrained: Bool = false
    ) {
        self.enabled = enabled
        self.beatRing = beatRing
        self.hasCover = hasCover
        self.isPlaying = isPlaying
        self.lighterOnBattery = lighterOnBattery
        self.isOnBattery = isOnBattery
        self.isLowPowerMode = isLowPowerMode
        self.isThermallyConstrained = isThermallyConstrained
    }
}

/// How often the Dock icon may change. Every new tile is a bitmap sent to
/// the Dock, which redraws it: that costs the Dock process more than it
/// costs Ahenk, so the rates stay low, the tile changes in a few steps
/// (`DockTileLook`) and frames that would look the same are never sent
/// (`DockRingMotion.differs`).
///
/// - Off, or nothing to show → the app icon (a new song's cover gets
///   ``coverGrace`` to arrive first; the last cover stays meanwhile).
/// - Paused, the ring off, Low Power Mode or a hot Mac → the cover, still.
/// - battery (with "run lighter") → 6 frames a second.
/// - Otherwise 10 frames a second.
public enum DockArtPolicy {
    public static let normalFramesPerSecond = 10
    public static let lighterFramesPerSecond = 6

    /// A new song's cover takes a moment to arrive (a lookup, a download):
    /// the cover shown stays this long before Ahenk's icon comes back, so
    /// the Dock does not flash the icon between songs.
    public static let coverGrace: TimeInterval = 3

    /// True while the tile should keep the last cover: a song is followed,
    /// its cover is not known yet, a cover is showing and the grace has
    /// not run out. `sinceLost`: seconds since the cover went missing.
    public static func holdsLastCover(hasSong: Bool, hasCover: Bool, showsCover: Bool, sinceLost: TimeInterval) -> Bool {
        hasSong && !hasCover && showsCover && sinceLost >= 0 && sinceLost < coverGrace
    }

    public static func mode(_ inputs: DockArtInputs) -> DockArtMode {
        guard inputs.enabled, inputs.hasCover else { return .appIcon }
        guard inputs.isPlaying, inputs.beatRing else { return .still }
        if inputs.isThermallyConstrained || (inputs.lighterOnBattery && inputs.isLowPowerMode) { return .still }
        if inputs.lighterOnBattery, inputs.isOnBattery {
            return .animated(framesPerSecond: lighterFramesPerSecond)
        }
        return .animated(framesPerSecond: normalFramesPerSecond)
    }
}

/// One Dock tile.
public struct DockArtFrame: Equatable, Sendable {
    /// The ring's beat swell, 0…1: wider, brighter, pushed a little out.
    public var pulse: Double
    /// Loudness, 0…1: the glow's base.
    public var level: Double
    /// Share of the song played, 0…1: a brighter arc along the ring.
    public var progress: Double
    public var isPlaying: Bool

    public init(pulse: Double, level: Double, progress: Double, isPlaying: Bool) {
        self.pulse = min(1, max(0, pulse.isFinite ? pulse : 0))
        self.level = min(1, max(0, level.isFinite ? level : 0))
        self.progress = min(1, max(0, progress.isFinite ? progress : 0))
        self.isPlaying = isPlaying
    }

    /// The cover with a calm ring (paused, Low Power Mode).
    public static func still(progress: Double) -> DockArtFrame {
        DockArtFrame(pulse: 0, level: 0, progress: progress, isPlaying: false)
    }
}

/// What a tile looks like apart from the progress arc, in the few steps
/// the Dock is redrawn in: paused, or one of ``pulseSteps`` + 1 sizes of
/// the swell, quiet or loud.
///
/// The steps are what makes the tile cheap. The Dock's tile is a
/// wide-colour bitmap in which gradients, clips and resampled pictures are
/// slow to draw, while a picture drawn before is copied quickly; so the app
/// draws each look once per cover and afterwards only copies it
/// (``count`` pictures at most).
public struct DockTileLook: Hashable, Sendable {
    /// The swell's sizes between none and full.
    public static let pulseSteps = 12
    /// Loudness from which the glow is the stronger one.
    public static let loudLevel = 0.5

    public var isPlaying: Bool
    /// 0…``pulseSteps``; 0 while paused.
    public var pulseStep: Int
    public var isLoud: Bool

    public init(_ frame: DockArtFrame) {
        isPlaying = frame.isPlaying
        pulseStep = frame.isPlaying ? Int((frame.pulse * Double(Self.pulseSteps)).rounded()) : 0
        isLoud = frame.isPlaying && frame.level >= Self.loudLevel
    }

    /// The frame that is drawn for this look.
    public func frame(progress: Double = 0) -> DockArtFrame {
        guard isPlaying else { return .still(progress: progress) }
        return DockArtFrame(
            pulse: Double(pulseStep) / Double(Self.pulseSteps), level: isLoud ? 0.8 : 0.3, progress: progress, isPlaying: true
        )
    }

    /// How many looks there are.
    public static var count: Int { 1 + 2 * (pulseSteps + 1) }
}

/// The ring's motion from the audio features, made for a tile that is
/// redrawn only a few times a second.
///
/// The features' own beat pulse lasts ~0.1 s, shorter than two frames at
/// 10 fps, so it would mostly be missed. Instead every new beat (a change
/// of `beatIndex`, which a slow reader never misses) starts a swell of its
/// own that fades with ``decay``, timed from the beat itself when the tempo
/// is known, so it looks the same at any frame rate.
public struct DockRingMotion: Sendable {
    /// Time constant of a beat's swell (seconds).
    public static let decay = 0.16
    /// One degree of the progress arc.
    public static let angleStep = 1.0 / 360

    private var lastBeatIndex: Int?
    private var peak = 0.0
    private var beatTime = -Double.infinity

    public init() {}

    /// The frame at `time` (seconds on any steady clock).
    public mutating func frame(features: AudioFeatures, at time: Double, progress: Double, isPlaying: Bool) -> DockArtFrame {
        guard isPlaying, !features.isSilent else {
            lastBeatIndex = nil
            return .still(progress: progress)
        }
        if let last = lastBeatIndex, features.beatIndex != last {
            // How long ago the beat was: from the tempo when it is known.
            let beatLength = features.bpm > 0 ? 60 / Double(features.bpm) : 0
            let age = beatLength > 0 ? min(Double(features.beatPhase) * beatLength, 0.25) : 0
            beatTime = time - age
            peak = 0.6 + 0.4 * Double(min(1, max(0, features.energy)))
        }
        lastBeatIndex = features.beatIndex
        let swell = peak * exp(-max(0, time - beatTime) / Self.decay)
        return DockArtFrame(pulse: swell, level: Double(features.energy), progress: progress, isPlaying: true)
    }

    /// True when `next` looks different from what the Dock shows, so that a
    /// new tile is worth sending: another look, or the progress arc a
    /// degree further.
    public static func differs(_ next: DockArtFrame, from shown: DockArtFrame?) -> Bool {
        guard let shown else { return true }
        if DockTileLook(next) != DockTileLook(shown) { return true }
        return abs(next.progress - shown.progress) >= angleStep
    }
}

/// The ring's measures in a tile of side 1 (multiply by the tile's size).
public struct DockRingGeometry: Equatable, Sendable {
    /// Radius of the round cover.
    public var coverRadius: Double
    /// Radius of the ring's centre line.
    public var ringRadius: Double
    public var ringWidth: Double
    /// Blur radius of the glow.
    public var glowRadius: Double
    /// Opacity of the glow.
    public var glowOpacity: Double
    /// Opacity of the ring's colours.
    public var ringOpacity: Double

    /// The round cover's radius in a tile of side 1.
    public static let coverRadius = 0.34

    /// The measures for `frame`: the swell widens and brightens the ring
    /// and pushes it out a little; a paused ring is thin and quiet. Every
    /// measure stays inside the tile (the glow included).
    public static func of(_ frame: DockArtFrame) -> DockRingGeometry {
        let pulse = frame.isPlaying ? frame.pulse : 0
        let level = frame.isPlaying ? frame.level : 0
        let coverRadius = Self.coverRadius
        let width = frame.isPlaying ? 0.03 * (1 + pulse) : 0.02
        let ringRadius = coverRadius + 0.025 + width / 2 + 0.012 * pulse
        let glow = frame.isPlaying ? 0.02 + 0.03 * pulse : 0
        let opacity = frame.isPlaying ? 0.22 + 0.5 * pulse + 0.2 * level : 0
        return DockRingGeometry(
            coverRadius: coverRadius, ringRadius: ringRadius, ringWidth: width, glowRadius: glow,
            glowOpacity: min(0.95, opacity), ringOpacity: frame.isPlaying ? 0.8 + 0.2 * pulse : 0.55
        )
    }

    /// How far the ring and its glow reach from the centre.
    public var outerReach: Double { ringRadius + ringWidth / 2 + glowRadius }
}
