import Foundation

/// What the light, the Dock ring and the lyrics react to. Read it every
/// frame from ``AudioFeatureSource/currentFeatures()``.
///
/// Every level is normalized to `0...1` and already smoothed (fast attack,
/// slower release), so a renderer can use the values as they are. The
/// levels follow an adaptive dB scale: loud and quiet songs both use the
/// whole range, and Settings › Sound › Sensitivity scales them.
///
/// `beat` and `beatPhase` are computed at the moment of reading, so they
/// move smoothly at any frame rate. When `isSilent` is true (nothing plays,
/// the source is paused, or it plays something that is not music) every
/// level is 0 and no beats come; draw nothing new.
///
/// A plain-data value (no references): copying it never allocates.
public struct AudioFeatures: Sendable, Equatable, BitwiseCopyable {
    /// Number of bands in ``spectrum``.
    public static let spectrumCount = 32
    /// Edges of the spectrum: 30 Hz to 16 kHz, log-spaced (about a third of
    /// an octave per band). Above a quarter of the sample rate the top bands
    /// stay 0.
    public static let spectrumRange: ClosedRange<Double> = 30...16_000

    /// Overall loudness (smoothed RMS). Typical music sits around 0.6–0.9.
    public var energy: Float
    /// Five summary bands (sub-bass … high).
    public var bands: AudioBands
    /// Log-spaced spectrum for visuals, lowest band first.
    public var spectrum: SIMD32<Float>
    /// Spectral-flux onset strength: jumps on every attack (kick, snare,
    /// pluck, vocal entry) and falls back within ~70 ms.
    public var onset: Float
    /// Beat pulse: the beat's strength (0.4–1) right on a beat, decaying
    /// exponentially (time constant ~ a quarter of the beat, 70–200 ms).
    public var beat: Float
    /// Position inside the current beat, `0..<1`; 0 on the beat. Stays 0
    /// while the tempo is unknown.
    public var beatPhase: Float
    /// Increases by one on every beat. Compare with the previous frame's
    /// value to spot a new beat.
    public var beatIndex: Int
    /// Tempo; 0 while unknown (the first seconds of a song, music without a
    /// steady beat).
    public var bpm: Float
    /// How sure the tempo is, `0...1`. Above ~0.35 beats are predicted from
    /// the tempo (they land on time even through a quiet bar); below it they
    /// come from the kick drum alone.
    public var tempoConfidence: Float
    public var isSilent: Bool

    public init(
        energy: Float,
        bands: AudioBands,
        spectrum: SIMD32<Float>,
        onset: Float,
        beat: Float,
        beatPhase: Float,
        beatIndex: Int,
        bpm: Float,
        tempoConfidence: Float,
        isSilent: Bool
    ) {
        self.energy = energy
        self.bands = bands
        self.spectrum = spectrum
        self.onset = onset
        self.beat = beat
        self.beatPhase = beatPhase
        self.beatIndex = beatIndex
        self.bpm = bpm
        self.tempoConfidence = tempoConfidence
        self.isSilent = isSilent
    }

    /// Nothing is playing.
    public static let silence = AudioFeatures(
        energy: 0, bands: .zero, spectrum: .zero, onset: 0, beat: 0, beatPhase: 0,
        beatIndex: 0, bpm: 0, tempoConfidence: 0, isSilent: true
    )

    /// The levels (energy, bands, spectrum, onset, beat) times `factor`;
    /// timing and tempo stay as they are.
    public func scaled(by factor: Float) -> AudioFeatures {
        var result = self
        result.energy *= factor
        result.bands = bands.scaled(by: factor)
        result.spectrum *= factor
        result.onset *= factor
        result.beat *= factor
        return result
    }
}

/// The five summary bands, each `0...1`. They share one reference level
/// (with fixed offsets for the usual balance of music), so a band that
/// carries little of the song stays low: a bass line lights `bass`, a
/// hi-hat lights `high`.
public struct AudioBands: Sendable, Equatable, BitwiseCopyable {
    /// 20–60 Hz: the body of the kick, sub bass.
    public var subBass: Float
    /// 60–250 Hz: kick punch, bass line.
    public var bass: Float
    /// 250–500 Hz: low vocals, guitars, warmth.
    public var lowMid: Float
    /// 500 Hz – 2 kHz: vocals, snare, most instruments.
    public var mid: Float
    /// 2–16 kHz: hi-hats, cymbals, air.
    public var high: Float

    public static let count = 5
    /// Lower edge of each band, then the top edge, in Hz.
    public static let edges: [Double] = [20, 60, 250, 500, 2_000, 16_000]

    public init(subBass: Float, bass: Float, lowMid: Float, mid: Float, high: Float) {
        self.subBass = subBass
        self.bass = bass
        self.lowMid = lowMid
        self.mid = mid
        self.high = high
    }

    public static let zero = AudioBands(subBass: 0, bass: 0, lowMid: 0, mid: 0, high: 0)

    /// `subBass, bass, lowMid, mid, high, 0, 0, 0`: one value to hand to a
    /// shader (two `float4`).
    public var packed: SIMD8<Float> {
        SIMD8(subBass, bass, lowMid, mid, high, 0, 0, 0)
    }

    public subscript(index: Int) -> Float {
        get {
            switch index {
            case 0: subBass
            case 1: bass
            case 2: lowMid
            case 3: mid
            default: high
            }
        }
        set {
            switch index {
            case 0: subBass = newValue
            case 1: bass = newValue
            case 2: lowMid = newValue
            case 3: mid = newValue
            default: high = newValue
            }
        }
    }

    public func scaled(by factor: Float) -> AudioBands {
        AudioBands(subBass: subBass * factor, bass: bass * factor, lowMid: lowMid * factor, mid: mid * factor, high: high * factor)
    }
}

/// Supplies the latest audio features. Called from render loops on any
/// thread at display rate: implementations never block, never allocate
/// and return within microseconds.
public protocol AudioFeatureSource: AnyObject, Sendable {
    /// The features now.
    func currentFeatures() -> AudioFeatures
    /// The features as they should look at `time` (``AudioClock`` seconds),
    /// e.g. the target timestamp of the frame being rendered, so the beat
    /// pulse is exact for that frame.
    func features(at time: Double) -> AudioFeatures
}

extension AudioFeatureSource {
    public func features(at time: Double) -> AudioFeatures {
        currentFeatures()
    }
}

/// The clock every audio timestamp uses: seconds on the host's uptime clock,
/// the same base as `CACurrentMediaTime()` and `CADisplayLink.timestamp`
/// (it does not advance while the Mac sleeps).
public enum AudioClock {
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
