import Foundation

/// The edge light's motion, integrated frame by frame from the audio
/// features: kicks push the light forward, quiet parts drift.
///
/// - ``drift`` is a clock for flowing textures (flames, plasma, aurora): it
///   runs at the speed setting and a little faster on every kick.
/// - ``travel`` is how far moving shapes (snakes, waves, stars) have gone
///   around the screen, in perimeter lengths: a slow base pace plus a lunge
///   on every beat pulse.
/// - ``swell`` is the loudness, smoothed over about half a second, for the
///   light's breathing.
/// - ``beats`` are the last four beats, newest first, for styles that spawn
///   something per beat (rings, fireworks, strikes). When no beat has come
///   for ``idleBeatInterval`` (a quiet intro, music the analysis cannot
///   hear) a soft one is made up, so those styles stay alive at a calm pace.
///
/// Pure value type; the render thread owns one for all screens.
public struct LightMotion: Sendable {
    public struct Beat: Equatable, Sendable {
        /// When the beat sounded (``AudioClock`` seconds).
        public var time: Double
        /// `0...1`.
        public var strength: Float
        /// Different per beat; the shader hashes it to place what it spawns.
        public var seed: Float
    }

    /// `drift` wraps at this many seconds to keep float precision in the
    /// shader (a jump once in about an hour of playback).
    public static let driftPeriod = 4096.0
    /// Perimeter lengths per second at speed 1 with no beat…
    public static let travelBase = 0.03
    /// …and extra per second at a full beat pulse.
    public static let travelPush = 0.35
    /// Seconds without a beat before a soft beat is made up (at speed 1).
    public static let idleBeatInterval = 1.9
    public static let historyCount = 4
    /// Age reported for a beat slot that holds nothing.
    public static let noBeatAge: Float = 1000

    public private(set) var drift: Double = 0
    public private(set) var travel: Double = 0
    public private(set) var swell: Float = 0
    /// The beat pulse this frame (`0...1`).
    public private(set) var kick: Float = 0
    public private(set) var beats: [Beat] = []
    /// Time of the last `advance`.
    public private(set) var time: Double?
    private var lastBeatIndex: Int?
    private var madeUp = 0

    public init() {}

    /// Integrates the motion up to `time` (``AudioClock`` seconds, e.g. a
    /// display link's target timestamp). Steps longer than a quarter second
    /// (after the display link slept) count as a quarter second.
    public mutating func advance(to time: Double, features: AudioFeatures, speed: Double) {
        guard let last = self.time else {
            self.time = time
            lastBeatIndex = features.beatIndex
            return
        }
        guard time > last else { return }
        self.time = time
        let step = min(time - last, 0.25)
        let speed = max(0.05, speed)
        let pulse = features.isSilent ? 0 : min(1, max(0, features.beat))
        let energy = features.isSilent ? 0 : min(1, max(0, features.energy))

        kick = pulse
        let rate: Double = energy > swell ? 1 / 0.25 : 1 / 0.8
        swell += (energy - swell) * Float(1 - exp(-step * rate))
        drift = (drift + step * speed * (1 + 0.5 * Double(pulse))).truncatingRemainder(dividingBy: Self.driftPeriod)
        travel = (travel + step * speed * (Self.travelBase + Self.travelPush * Double(pulse))).truncatingRemainder(dividingBy: 1)

        if let lastBeatIndex, features.beatIndex > lastBeatIndex, !features.isSilent {
            let period = features.bpm > 0 ? 60 / Double(features.bpm) : 0
            let age = Double(features.beatPhase) * period
            push(Beat(time: time - age, strength: max(0.4, pulse), seed: Float(features.beatIndex % 65_536)))
        }
        lastBeatIndex = features.beatIndex

        let quiet = Self.idleBeatInterval / min(max(speed, 0.5), 2)
        if time - (beats.first?.time ?? -.infinity) > quiet {
            madeUp += 1
            push(Beat(time: time, strength: 0.45, seed: Float(70_000 + madeUp % 30_000)))
        }
    }

    private mutating func push(_ beat: Beat) {
        beats.insert(beat, at: 0)
        if beats.count > Self.historyCount { beats.removeLast(beats.count - Self.historyCount) }
    }

    /// Seconds since each of the last four beats at `time`, newest first;
    /// ``noBeatAge`` for empty slots.
    public func beatAges(at time: Double) -> SIMD4<Float> {
        var ages = SIMD4<Float>(repeating: Self.noBeatAge)
        for (index, beat) in beats.prefix(Self.historyCount).enumerated() {
            ages[index] = Float(min(Double(Self.noBeatAge), max(0, time - beat.time)))
        }
        return ages
    }

    public var beatStrengths: SIMD4<Float> {
        var strengths = SIMD4<Float>(repeating: 0)
        for (index, beat) in beats.prefix(Self.historyCount).enumerated() { strengths[index] = beat.strength }
        return strengths
    }

    public var beatSeeds: SIMD4<Float> {
        var seeds = SIMD4<Float>(repeating: 0)
        for (index, beat) in beats.prefix(Self.historyCount).enumerated() { seeds[index] = beat.seed }
        return seeds
    }
}
