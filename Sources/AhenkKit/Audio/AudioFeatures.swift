import Foundation

/// What the light, the Dock ring and the lyrics react to, sampled at display
/// rate. Every level is normalized to `0...1`.
///
/// Step 3 produces these from a Core Audio process tap; the demo synthesizes
/// a steady 120 BPM pattern. Consumers must treat `isSilent` (or a source
/// that is not playing) as "draw nothing new".
public struct AudioFeatures: Sendable, Equatable {
    public static let bandCount = 16

    /// Overall loudness (smoothed RMS).
    public var level: Float
    public var bass: Float
    public var mid: Float
    public var treble: Float
    /// Log-spaced bands, lowest first.
    public var bands: SIMD16<Float>
    /// Spectral-flux onset strength.
    public var onset: Float
    /// Beat pulse envelope: 1 right on a beat, decaying until the next one.
    public var beat: Float
    /// Position inside the current beat, `0..<1`.
    public var beatPhase: Float
    /// Increases by one on every detected beat; compare values to spot a new
    /// beat between two frames.
    public var beatIndex: Int
    /// Tempo estimate; 0 when unknown.
    public var bpm: Float
    public var isSilent: Bool

    public init(
        level: Float,
        bass: Float,
        mid: Float,
        treble: Float,
        bands: SIMD16<Float>,
        onset: Float,
        beat: Float,
        beatPhase: Float,
        beatIndex: Int,
        bpm: Float,
        isSilent: Bool
    ) {
        self.level = level
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.bands = bands
        self.onset = onset
        self.beat = beat
        self.beatPhase = beatPhase
        self.beatIndex = beatIndex
        self.bpm = bpm
        self.isSilent = isSilent
    }

    /// Nothing is playing.
    public static let silence = AudioFeatures(
        level: 0, bass: 0, mid: 0, treble: 0, bands: .zero, onset: 0,
        beat: 0, beatPhase: 0, beatIndex: 0, bpm: 0, isSilent: true
    )
}

/// Supplies the latest audio features. Called from render loops on any
/// thread, so implementations must be cheap and non-blocking.
public protocol AudioFeatureSource: AnyObject, Sendable {
    func currentFeatures() -> AudioFeatures
}
