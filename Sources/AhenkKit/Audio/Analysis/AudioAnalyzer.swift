import Accelerate
import Foundation

/// Turns mono samples into ``AudioFeatures``: windowed FFT, log-spaced bands,
/// RMS loudness, spectral-flux onsets, a kick detector, tempo and beat
/// tracking, attack/release smoothing and a silence gate.
///
/// Geometry follows the sample rate: a Hann window of ~43 ms (2048 samples
/// at 44.1/48 kHz, 4096 at 88.2/96 kHz) every ~10.7 ms (a quarter window),
/// so about 94 analysis frames per second.
///
/// Times are on the analyzer's own timeline: seconds of audio fed since the
/// start (or the last ``reset()``). ``frame`` holds the latest result with
/// its beat times on that timeline; the pipeline shifts it to the host
/// clock.
///
/// Not thread-safe: feed and read it from one queue. Every buffer is
/// allocated in `init`; ``process(_:count:)`` allocates nothing.
public final class AudioAnalyzer {
    public let sampleRate: Double
    public let fftSize: Int
    public let hopSize: Int
    /// Seconds between analysis frames.
    public let frameInterval: Double
    /// How far an onset's reported time trails the moment it happens in the
    /// newest analysed frame (compensated in every reported time).
    public let onsetLatency: Double

    /// The latest result (times on the analyzer's timeline).
    public private(set) var frame = AudioFeatureFrame.silence
    /// RMS of the newest hop in dBFS (a full-scale sine is −3 dBFS).
    public private(set) var levelDB: Float = -140
    /// Seconds of audio analysed since the start or the last reset.
    public var time: Double { Double(totalSamples) / sampleRate }
    /// The newest tempo estimate (diagnostics, tests).
    private(set) var lastEstimate: TempoEstimator.Estimate?

    /// Called for every beat, inside `process` (tests, diagnostics).
    public var onBeat: ((BeatEvent) -> Void)?
    /// Called for every onset with its time and normalized strength.
    public var onOnset: ((Double, Float) -> Void)?

    // MARK: Tuning

    /// The silence gate closes below −60 dBFS (after 0.35 s) and opens
    /// above −54 dBFS.
    static let silenceCloseDB: Float = -60
    static let silenceOpenDB: Float = -54
    static let silenceHold = 0.35
    /// After this much silence the tempo is forgotten (a new song follows).
    static let tempoMemoryInSilence = 2.5
    /// dB windows the levels are drawn on, ending at their peak reference.
    static let energyRange: Float = 24
    static let bandRange: Float = 30
    static let spectrumRange: Float = 42
    /// A kick must lift the 40–150 Hz energy this far above its recent mean
    /// (noise reaches +5 dB now and then, a kick drum +10–25 dB).
    static let kickRise: Float = 6.5
    /// Tempo estimates per second.
    static let estimatesPerSecond = 2.0

    // MARK: Buffers

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    /// The newest `fftSize` samples, oldest first.
    private let samples: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let powerScale: Float
    private var pending = 0
    private var totalSamples = 0
    private var frameIndex = 0

    // MARK: State

    private let layout: BandLayout
    private let tempo: TempoEstimator
    private let estimateInterval: Int
    private var framesSinceEstimate = 0
    /// Analyzer frame that is the tempo history's frame 0.
    private var tempoFrameOffset = 0
    private var tracker = BeatTracker()
    private var gate: SilenceGate
    private var energyEnvelope: EnvelopeFollower
    private var onsetEnvelope: EnvelopeFollower
    private var bandEnvelope: VectorEnvelope<SIMD8<Float>>
    private var spectrumEnvelope: VectorEnvelope<SIMD32<Float>>
    private var energyReference: PeakReference
    private var bandReference: PeakReference
    private var spectrumReference: PeakReference
    private var fluxFloorReference: PeakReference
    private var fluxStatistics: RunningStatistics
    private var lowFluxStatistics: RunningStatistics
    private var kickStatistics: RunningStatistics
    private var previousBandDB = SIMD32<Float>(repeating: -140)
    /// One frame of look-ahead for peak picking: the previous two frames.
    private var flux1: Float = 0
    private var flux2: Float = 0
    private var threshold1: Float = .infinity
    private var lowFlux1: Float = 0
    private var lowFlux2: Float = 0
    private var lowThreshold1: Float = .infinity
    private var kickRise1: Float = 0
    private var lastOnsetTime = -Double.infinity
    private var onsetPeak: Float = 1
    private let onsetPeakDecay: Float

    public init(sampleRate: Double) {
        precondition(sampleRate >= 8_000 && sampleRate <= 384_000, "Unsupported sample rate \(sampleRate)")
        self.sampleRate = sampleRate
        // ~43 ms window: 2048 at 44.1/48 kHz.
        var size = 256
        while Double(size) < sampleRate * 0.0427 * 0.999 { size <<= 1 }
        fftSize = size
        hopSize = size / 4
        frameInterval = Double(hopSize) / sampleRate
        // Half a hop of frame quantization plus the Hann window's soft
        // leading edge (an attack registers once ~16 % of the window has
        // passed it); measured with kick trains at 44.1 and 48 kHz.
        onsetLatency = (0.5 * Double(size / 4) + 0.16 * Double(size)) / sampleRate
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        window = .allocate(capacity: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        samples = .allocate(capacity: size)
        samples.initialize(repeating: 0, count: size)
        windowed = .allocate(capacity: size)
        windowed.initialize(repeating: 0, count: size)
        real = .allocate(capacity: size / 2)
        real.initialize(repeating: 0, count: size / 2)
        imaginary = .allocate(capacity: size / 2)
        imaginary.initialize(repeating: 0, count: size / 2)
        power = .allocate(capacity: size / 2)
        power.initialize(repeating: 0, count: size / 2)
        // vDSP's real FFT returns twice the DFT; with a Hann window a
        // full-scale sine on a bin then reads as power 1 (0 dB).
        powerScale = 4 / Float(size * size)

        layout = BandLayout(fftSize: size, sampleRate: sampleRate)
        let frameRate = 1 / frameInterval
        tempo = TempoEstimator(frameRate: frameRate)
        estimateInterval = max(1, Int((frameRate / Self.estimatesPerSecond).rounded()))
        let interval = frameInterval
        gate = SilenceGate(closeBelow: Self.silenceCloseDB, openAbove: Self.silenceOpenDB, holdSeconds: Self.silenceHold, frameInterval: interval)
        energyEnvelope = EnvelopeFollower(attack: 0.025, release: 0.22, frameInterval: interval)
        onsetEnvelope = EnvelopeFollower(attack: 0, release: 0.07, frameInterval: interval)
        bandEnvelope = VectorEnvelope(attack: 0.015, release: 0.16, frameInterval: interval)
        spectrumEnvelope = VectorEnvelope(attack: 0.01, release: 0.11, frameInterval: interval)
        energyReference = PeakReference(fallPerSecond: 0.75, floor: -40, frameInterval: interval)
        bandReference = PeakReference(fallPerSecond: 0.75, floor: -60, frameInterval: interval)
        spectrumReference = PeakReference(fallPerSecond: 1, floor: -85, frameInterval: interval)
        fluxFloorReference = PeakReference(fallPerSecond: 1, floor: -100, frameInterval: interval)
        fluxStatistics = RunningStatistics(timeConstant: 0.25, frameInterval: interval)
        lowFluxStatistics = RunningStatistics(timeConstant: 0.25, frameInterval: interval)
        kickStatistics = RunningStatistics(timeConstant: 0.25, frameInterval: interval, initialMean: -140)
        // The onset reference halves in about four seconds.
        onsetPeakDecay = Float(pow(0.5, interval / 4))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        samples.deallocate()
        windowed.deallocate()
        real.deallocate()
        imaginary.deallocate()
        power.deallocate()
    }

    // MARK: Feeding

    /// Analyses `count` mono samples. Allocation-free.
    public func process(_ input: UnsafePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            let take = min(hopSize - pending, count - offset)
            (samples + (fftSize - hopSize + pending)).update(from: input + offset, count: take)
            pending += take
            offset += take
            totalSamples += take
            if pending == hopSize {
                analyzeFrame()
                memmove(samples, samples + hopSize, (fftSize - hopSize) * MemoryLayout<Float>.size)
                pending = 0
            }
        }
    }

    /// Convenience for tests and tools (not for the real-time path).
    public func process(_ input: [Float]) {
        input.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(base, count: buffer.count)
        }
    }

    /// Forgets everything except the beat counter (it keeps counting, so
    /// consumers comparing indices see the next beat as new).
    public func reset() {
        samples.update(repeating: 0, count: fftSize)
        pending = 0
        totalSamples = 0
        frameIndex = 0
        framesSinceEstimate = 0
        tempoFrameOffset = 0
        tracker.reset()
        tempo.reset()
        lastEstimate = nil
        gate.reset()
        energyEnvelope.reset()
        onsetEnvelope.reset()
        bandEnvelope.reset()
        spectrumEnvelope.reset()
        energyReference.reset()
        bandReference.reset()
        spectrumReference.reset()
        fluxFloorReference.reset()
        fluxStatistics.reset()
        lowFluxStatistics.reset()
        kickStatistics.reset()
        previousBandDB = SIMD32(repeating: -140)
        flux1 = 0
        flux2 = 0
        threshold1 = .infinity
        lowFlux1 = 0
        lowFlux2 = 0
        lowThreshold1 = .infinity
        kickRise1 = 0
        lastOnsetTime = -.infinity
        onsetPeak = 1
        levelDB = -140
        let index = frame.features.beatIndex
        frame = .silence
        frame.features.beatIndex = index
    }

    /// Forgets the tempo (a new song) but keeps the levels.
    public func resetTempo() {
        tracker.unlock()
        tempo.reset()
        tempoFrameOffset = frameIndex
        lastEstimate = nil
        framesSinceEstimate = 0
    }

    // MARK: Analysis

    /// Onset time of frame `index` (it ends at sample `(index + 1) × hop`).
    private func onsetTime(ofFrame index: Double) -> Double {
        (index + 1) * frameInterval - onsetLatency
    }

    private func analyzeFrame() {
        let current = Double(frameIndex)
        let now = onsetTime(ofFrame: current)
        frameIndex += 1

        // Loudness of the newest hop and the silence gate.
        var rms: Float = 0
        vDSP_rmsqv(samples + (fftSize - hopSize), 1, &rms, vDSP_Length(hopSize))
        levelDB = 20 * log10(max(rms, 1e-7))
        gate.update(levelDB: levelDB)
        let silent = gate.isSilent

        // Power spectrum.
        let half = fftSize / 2
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        imaginary[0] = 0 // packed Nyquist; bin 0 keeps only DC
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))
        var scale = powerScale
        vDSP_vsmul(power, 1, &scale, power, 1, vDSP_Length(half))

        // Bands in dB.
        let density = layout.spectrumPower(power)
        var bandDB = SIMD32<Float>()
        for band in 0..<AudioFeatures.spectrumCount { bandDB[band] = decibels(power: density[band]) }
        let summary = layout.summaryPower(power)
        var summaryDB = SIMD8<Float>(repeating: -140)
        for band in 0..<AudioBands.count { summaryDB[band] = decibels(power: summary[band]) + BandLayout.summaryOffsets[band] }
        let kickDB = decibels(power: layout.kickPower(power))

        // Spectral flux: how much the (floored) band levels rose. The
        // references hold through silence, so a pause changes no scaling.
        if !silent { fluxFloorReference.update(bandDB.max()) }
        let floorDB = fluxFloorReference.value - 55
        // Both frames on the current floor: the first sound after silence
        // must not count the whole climb from digital zero.
        let floor = SIMD32<Float>(repeating: floorDB)
        let floored = pointwiseMax(bandDB, floor)
        let rise = pointwiseMax(floored - pointwiseMax(previousBandDB, floor), .zero)
        previousBandDB = floored
        var flux = rise.sum() / Float(AudioFeatures.spectrumCount)
        var lowFlux: Float = 0
        for band in 0..<layout.kickBandCount { lowFlux += rise[band] }
        lowFlux /= Float(layout.kickBandCount)
        if silent || frameIndex < 3 {
            flux = 0
            lowFlux = 0
        }

        // Onsets: a peak on the previous frame above the adaptive threshold.
        fluxStatistics.update(flux)
        let threshold = fluxStatistics.mean + 1.5 * fluxStatistics.deviation + 0.3
        let previous = onsetTime(ofFrame: current - 1)
        if flux1 > threshold1, flux1 > flux2, flux1 >= flux, previous - lastOnsetTime >= 0.06 {
            let denominator = flux2 - 2 * flux1 + flux
            let shift = denominator < 0 ? Double(0.5 * (flux2 - flux) / denominator) : 0
            let time = previous + max(-0.5, min(0.5, shift)) * frameInterval
            onsetPeak = max(onsetPeak, flux1)
            let strength = min(1, max(0, (flux1 - fluxStatistics.mean) / max(onsetPeak - fluxStatistics.mean, 1)))
            lastOnsetTime = time
            tracker.onset(at: time, strength: strength)
            onOnset?(time, strength)
        }
        onsetPeak = max(1, onsetPeak * onsetPeakDecay)

        // Kicks (beats of their own until a tempo locks).
        lowFluxStatistics.update(lowFlux)
        let lowThreshold = lowFluxStatistics.mean + 2 * lowFluxStatistics.deviation + 0.5
        // A kick is a low-band peak that also lifts the whole spectrum.
        if lowFlux1 > lowThreshold1, lowFlux1 > lowFlux2, lowFlux1 >= lowFlux, kickRise1 >= Self.kickRise, flux1 > threshold1 {
            let strength = min(1, kickRise1 / 20)
            tracker.kick(at: previous, strength: strength) { onBeat?($0) }
        }
        let kickRise = kickDB - kickStatistics.mean
        kickStatistics.update(kickDB)
        flux2 = flux1
        flux1 = flux
        threshold1 = threshold
        lowFlux2 = lowFlux1
        lowFlux1 = lowFlux
        lowThreshold1 = lowThreshold
        kickRise1 = kickRise

        // Tempo: the onset envelope above its running mean.
        tempo.push(silent ? 0 : max(0, flux - fluxStatistics.mean))
        framesSinceEstimate += 1
        if framesSinceEstimate >= estimateInterval {
            framesSinceEstimate = 0
            if !silent, let estimate = tempo.estimate() {
                lastEstimate = estimate
                tracker.apply(
                    bpm: estimate.bpm, confidence: estimate.confidence,
                    gridBeat: onsetTime(ofFrame: estimate.lastBeatFrame + Double(tempoFrameOffset)), now: now
                )
            }
        }
        if silent, Double(gate.silentFrames) * frameInterval >= Self.tempoMemoryInSilence, tracker.isLocked || tempo.frameCount > 0 {
            resetTempo()
        }
        if !silent {
            tracker.advance(to: now) { onBeat?($0) }
        }

        // Levels on adaptive dB windows, then attack/release smoothing.
        var energyTarget: Float = 0
        if !silent {
            energyTarget = normalizedLevel(levelDB, reference: energyReference.update(levelDB), range: Self.energyRange)
        }
        let energy = energyEnvelope.update(energyTarget)

        var bandTarget = SIMD8<Float>.zero
        if !silent {
            var strongest: Float = -140
            for band in 0..<AudioBands.count { strongest = max(strongest, summaryDB[band]) }
            let bandReferenceDB = bandReference.update(strongest)
            for band in 0..<AudioBands.count {
                bandTarget[band] = normalizedLevel(summaryDB[band], reference: bandReferenceDB, range: Self.bandRange)
            }
        }
        let bandLevels = bandEnvelope.update(bandTarget)

        let displayDB = bandDB + layout.spectrumTilt
        var spectrumTarget = SIMD32<Float>.zero
        if !silent {
            let spectrumReferenceDB = spectrumReference.update(displayDB.max())
            let low = SIMD32<Float>(repeating: spectrumReferenceDB - Self.spectrumRange)
            spectrumTarget = (displayDB - low) / Self.spectrumRange
            spectrumTarget.clamp(lowerBound: .zero, upperBound: SIMD32(repeating: 1))
            spectrumTarget *= layout.spectrumActive
        }
        let spectrum = spectrumEnvelope.update(spectrumTarget)

        let onsetTarget = silent ? 0 : min(1, max(0, (flux - threshold) / max(onsetPeak - fluxStatistics.mean, 1)))
        var onset = onsetEnvelope.update(onsetTarget)
        var energyLevel = energy
        var bandValues = bandLevels
        var spectrumValues = spectrum
        if silent {
            // The input has been quiet for the gate's hold time, so the
            // levels have nearly faded already; silence reads exactly 0.
            energyEnvelope.reset()
            bandEnvelope.reset()
            spectrumEnvelope.reset()
            onsetEnvelope.reset()
            energyLevel = 0
            bandValues = .zero
            spectrumValues = .zero
            onset = 0
        }

        let period = tracker.isLocked ? tracker.period : 0
        let features = AudioFeatures(
            energy: energyLevel,
            bands: AudioBands(
                subBass: bandValues[0], bass: bandValues[1], lowMid: bandValues[2], mid: bandValues[3], high: bandValues[4]
            ),
            spectrum: spectrumValues,
            onset: onset,
            beat: 0,
            beatPhase: 0,
            beatIndex: tracker.beatIndex,
            bpm: Float(tracker.bpm),
            tempoConfidence: silent ? 0 : tracker.confidence,
            isSilent: silent
        )
        frame = AudioFeatureFrame(
            features: features,
            time: time,
            beatTime: tracker.beatTime,
            previousBeatTime: tracker.previousBeatTime,
            beatStrength: tracker.beatStrength,
            previousBeatStrength: tracker.previousBeatStrength,
            beatPeriod: period,
            pulseDecay: period > 0 ? Float(min(0.2, max(0.07, 0.25 * period))) : 0.12
        )
    }
}
