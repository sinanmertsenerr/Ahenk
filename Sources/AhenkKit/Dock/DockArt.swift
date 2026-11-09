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
    /// A song is followed and its cover is known.
    public var hasCover: Bool
    /// Music plays (the light's rule: music or unlabelled content).
    public var isPlaying: Bool
    public var optimizedMode: Bool
    public var lighterOnBattery: Bool
    public var isOnBattery: Bool
    public var isLowPowerMode: Bool
    public var isThermallyConstrained: Bool

    public init(
        enabled: Bool = true, beatRing: Bool = true, hasCover: Bool = true, isPlaying: Bool = true,
        optimizedMode: Bool = false, lighterOnBattery: Bool = true, isOnBattery: Bool = false,
        isLowPowerMode: Bool = false, isThermallyConstrained: Bool = false
    ) {
        self.enabled = enabled
        self.beatRing = beatRing
        self.hasCover = hasCover
        self.isPlaying = isPlaying
        self.optimizedMode = optimizedMode
        self.lighterOnBattery = lighterOnBattery
        self.isOnBattery = isOnBattery
        self.isLowPowerMode = isLowPowerMode
        self.isThermallyConstrained = isThermallyConstrained
    }
}

/// How often the Dock icon may change. Every new tile is a bitmap sent to
/// the Dock, which redraws it: that costs the Dock process more than it
/// costs Ahenk, so the rates stay low and frames that would look the same
/// are never sent (`DockRingMotion.differs`).
///
/// - Off, or nothing to show → the app icon.
/// - Paused, the ring off, Low Power Mode or a hot Mac → the cover, still.
/// - Optimized Mode or (with "run lighter") battery → 6 frames a second.
/// - Otherwise 10 frames a second.
public enum DockArtPolicy {
    public static let normalFramesPerSecond = 10
    public static let lighterFramesPerSecond = 6

    public static func mode(_ inputs: DockArtInputs) -> DockArtMode {
        guard inputs.enabled, inputs.hasCover else { return .appIcon }
        guard inputs.isPlaying, inputs.beatRing else { return .still }
        if inputs.isThermallyConstrained || (inputs.lighterOnBattery && inputs.isLowPowerMode) { return .still }
        if inputs.optimizedMode || (inputs.lighterOnBattery && inputs.isOnBattery) {
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
    /// Where the ring's colours stand, in turns (0..<1); they step on with
    /// every beat.
    public var turn: Double
    public var isPlaying: Bool

    public init(pulse: Double, level: Double, progress: Double, turn: Double, isPlaying: Bool) {
        self.pulse = min(1, max(0, pulse.isFinite ? pulse : 0))
        self.level = min(1, max(0, level.isFinite ? level : 0))
        self.progress = min(1, max(0, progress.isFinite ? progress : 0))
        let wrapped = turn.isFinite ? turn.truncatingRemainder(dividingBy: 1) : 0
        self.turn = wrapped < 0 ? wrapped + 1 : wrapped
        self.isPlaying = isPlaying
    }

    /// The cover with a calm ring (paused, Low Power Mode).
    public static func still(progress: Double, turn: Double = 0) -> DockArtFrame {
        DockArtFrame(pulse: 0, level: 0, progress: progress, turn: turn, isPlaying: false)
    }
}

/// The ring's motion from the audio features, made for a tile that is
/// redrawn only a few times a second.
///
/// The features' own beat pulse lasts ~0.1 s, shorter than two frames at
/// 10 fps, so it would mostly be missed. Instead every new beat (a change
/// of `beatIndex`, which a slow reader never misses) starts a swell of its
/// own that fades with ``decay``, timed from the beat itself when the tempo
/// is known, so it looks the same at any frame rate. The colours step a
/// little further round on every beat.
public struct DockRingMotion: Sendable {
    /// Time constant of a beat's swell (seconds).
    public static let decay = 0.16
    /// How far the colours move per beat, in turns, and how long that takes.
    public static let turnPerBeat = 1.0 / 24
    public static let turnDuration = 0.22
    /// Frames differing by less than this look the same in the Dock.
    public static let pulseStep = 0.05
    public static let levelStep = 0.08
    /// One degree of the progress arc, and of the colours.
    public static let angleStep = 1.0 / 360

    private var lastBeatIndex: Int?
    private var peak = 0.0
    private var beatTime = -Double.infinity
    private var turnFrom = 0.0
    private var turnTo = 0.0

    public init() {}

    /// The frame at `time` (seconds on any steady clock).
    public mutating func frame(features: AudioFeatures, at time: Double, progress: Double, isPlaying: Bool) -> DockArtFrame {
        guard isPlaying, !features.isSilent else {
            lastBeatIndex = nil
            return .still(progress: progress, turn: turnTo)
        }
        if let last = lastBeatIndex, features.beatIndex != last {
            // How long ago the beat was: from the tempo when it is known.
            let beatLength = features.bpm > 0 ? 60 / Double(features.bpm) : 0
            let age = beatLength > 0 ? min(Double(features.beatPhase) * beatLength, 0.25) : 0
            // The colours go on from wherever the last step had got to.
            turnFrom = currentTurn(at: time)
            turnTo = turnFrom + Self.turnPerBeat
            beatTime = time - age
            peak = 0.6 + 0.4 * Double(min(1, max(0, features.energy)))
        }
        lastBeatIndex = features.beatIndex
        let swell = peak * exp(-max(0, time - beatTime) / Self.decay)
        return DockArtFrame(
            pulse: swell, level: Double(features.energy), progress: progress, turn: currentTurn(at: time), isPlaying: true
        )
    }

    private func currentTurn(at time: Double) -> Double {
        let t = min(1, max(0, (time - beatTime) / Self.turnDuration))
        let eased = 1 - pow(1 - t, 3)
        return turnFrom + (turnTo - turnFrom) * eased
    }

    /// True when `next` looks different enough from what the Dock shows to
    /// send it a new tile.
    public static func differs(_ next: DockArtFrame, from shown: DockArtFrame?) -> Bool {
        guard let shown else { return true }
        if next.isPlaying != shown.isPlaying { return true }
        if abs(next.pulse - shown.pulse) >= pulseStep { return true }
        if abs(next.level - shown.level) >= levelStep { return true }
        if abs(next.progress - shown.progress) >= angleStep { return true }
        let turn = abs(next.turn - shown.turn)
        return min(turn, 1 - turn) >= angleStep
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

    /// The measures for `frame`: the swell widens and brightens the ring
    /// and pushes it out a little; a paused ring is thin and quiet. Every
    /// measure stays inside the tile (the glow included).
    public static func of(_ frame: DockArtFrame) -> DockRingGeometry {
        let pulse = frame.isPlaying ? frame.pulse : 0
        let level = frame.isPlaying ? frame.level : 0
        let coverRadius = 0.34
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
