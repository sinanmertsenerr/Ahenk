import Foundation
import Accelerate

/// Onset-strength ("novelty") curve of a mono audio buffer — the DSP half of
/// automatic lyrics sync (ported from DynamicIsland, same author, MIT). MIR recipe with a percussion-suppression stage:
/// STFT → vocal-band magnitude (200–4000 Hz) → HPSS harmonic soft-mask
/// (median filtering per Fitzgerald 2010 / librosa `decompose.hpss`) →
/// log compression → half-wave-rectified spectral flux → local-mean detrend →
/// [0,1] normalize. Pure and deterministic; the audio never leaves this
/// function.
///
/// Why HPSS: spectral flux is documented to be percussion-biased and weakest
/// on singing voice, and the 200–4000 Hz band restriction does not fix that
/// (kick/snare/hat energy lives there too). On dense-beat tracks the drum
/// grid dominated the flux and made the lyric offset formally unidentifiable
/// (near-equal correlation peaks one beat period apart). The harmonic mask
/// suppresses broadband percussive verticals at the source, so the flux
/// tracks voiced-energy change instead of the beat grid.
public enum OnsetNovelty {
    public struct Curve: Sendable, Equatable {
        public var values: [Float]
        /// Seconds between consecutive novelty frames.
        public var hopSeconds: Double
        /// The same flux computed WITHOUT the HPSS mask. The estimator's
        /// beat-alias rejection needs the track's periodicity at its
        /// strongest — measuring it on the masked signal would let the alias
        /// gate silently stop firing exactly when the mask leaves residual
        /// beat energy for the correlation to alias on. Empty in synthetic
        /// test curves; consumers fall back to `values`.
        public var rawValues: [Float] = []

        public init(
            values: [Float],
            hopSeconds: Double,
            rawValues: [Float] = []
        ) {
            self.values = values
            self.hopSeconds = hopSeconds
            self.rawValues = rawValues
        }

        /// Re-labels the curve's wall-clock hop on the media timeline. Sample
        /// values stay identical; at 2× playback each wall second represents
        /// two media seconds. Running the estimator in this coordinate system
        /// keeps its lag, jitter, split-half, and beat-alias thresholds valid.
        public func convertedToMediaTime(playbackRate: Double) -> Self {
            var converted = self
            converted.hopSeconds *= playbackRate
            return converted
        }
    }

    static let fftSize = 1024
    static let hopSize = 512

    /// HPSS median-filter spans, in physical units so the tap counts follow
    /// the ACTUAL analysis geometry (decimation falls back to the original
    /// rate for non-divisible inputs — a hardcoded tap count would silently
    /// change its physical meaning there). librosa's defaults (31 taps at
    /// 22.05 kHz / n_fft 2048 / hop 512) correspond to ~720 ms of time
    /// context and ~330 Hz of frequency context.
    static let hpssTimeSpanSeconds = 0.72
    static let hpssFrequencySpanHz = 330.0
    /// Below this many frames a time median is statistically meaningless
    /// (mostly reflected duplicates) — skip HPSS, keep the raw flux.
    static let hpssMinimumFrames = 5

    public static func compute(samples: [Float], sampleRate: Double) -> Curve {
        let hopSeconds = Double(hopSize) / sampleRate
        guard samples.count >= fftSize * 2,
              let fft = vDSP.FFT(
                  log2n: vDSP_Length(log2(Double(fftSize))),
                  radix: .radix2,
                  ofType: DSPSplitComplex.self
              )
        else { return Curve(values: [], hopSeconds: hopSeconds) }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: fftSize, isHalfWindow: false)
        let binHz = sampleRate / Double(fftSize)
        let lowBin = max(1, Int(200 / binHz))
        let highBin = min(fftSize / 2 - 1, Int(4000 / binHz))
        guard lowBin < highBin else { return Curve(values: [], hopSeconds: hopSeconds) }
        let bandBins = highBin - lowBin + 1

        // Pass 1: vocal-band magnitude matrix (frames × bandBins). HPSS needs
        // future frames for its time-axis median, so the old single-pass
        // streaming flux is now a buffered two-pass pipeline. 12…32s at 16 kHz
        // is at most ~1,000 × 245 floats ≈ 1 MB — a one-shot burst allocation.
        let frameCount = (samples.count - fftSize) / hopSize + 1
        var band = [Float](repeating: 0, count: frameCount * bandBins)
        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        for frame in 0..<frameCount {
            let start = frame * hopSize
            samples.withUnsafeBufferPointer { buffer in
                vDSP_vmul(buffer.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            windowed.withUnsafeBufferPointer { input in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imag.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!
                        )
                        input.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: fftSize / 2
                        ) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                        fft.forward(input: split, output: &split)
                        vDSP.squareMagnitudes(split, result: &magnitudes)
                    }
                }
            }
            for (index, bin) in (lowBin...highBin).enumerated() {
                band[frame * bandBins + index] = magnitudes[bin].squareRoot()
            }
        }

        // Pass 2: harmonic soft-mask on the band matrix, then flux from both
        // the masked (production signal) and unmasked (alias-gate reference)
        // magnitudes in one sweep.
        let masked = harmonicMasked(
            band, frames: frameCount, bins: bandBins,
            hopSeconds: hopSeconds, binHz: binHz
        )
        var flux = [Float](repeating: 0, count: frameCount)
        var rawFlux = [Float](repeating: 0, count: frameCount)
        var previous = [Float](repeating: 0, count: bandBins)
        var previousRaw = [Float](repeating: 0, count: bandBins)
        for frame in 0..<frameCount {
            var sum: Float = 0
            var rawSum: Float = 0
            for index in 0..<bandBins {
                let cell = frame * bandBins + index
                let magnitude = log1p(10 * masked[cell])
                sum += max(0, magnitude - previous[index])
                previous[index] = magnitude
                let rawMagnitude = log1p(10 * band[cell])
                rawSum += max(0, rawMagnitude - previousRaw[index])
                previousRaw[index] = rawMagnitude
            }
            flux[frame] = sum
            rawFlux[frame] = rawSum
        }
        if !flux.isEmpty {  // first frame's flux is pure spectrum, not an onset
            flux[0] = 0
            rawFlux[0] = 0
        }

        return Curve(
            values: finished(flux),
            hopSeconds: hopSeconds,
            rawValues: finished(rawFlux)
        )
    }

    /// Local-mean detrend (flattens verse/chorus level differences) + [0,1]
    /// peak normalize.
    private static func finished(_ flux: [Float]) -> [Float] {
        let detrended = detrend(flux, window: 15)
        let peak = detrended.max() ?? 0
        guard peak > 0 else { return detrended }
        return vDSP.divide(detrended, peak)
    }

    /// Fitzgerald-2010 harmonic/percussive soft-mask applied to the band
    /// magnitude matrix (row-major frames × bins): harmonic estimate =
    /// median across TIME, percussive estimate = median across FREQUENCY,
    /// mask = h² / (h² + p²) with librosa's Z-clamp (a silent bin's 0/0 must
    /// become mask 0, never NaN — one NaN frame would poison the flux peak
    /// normalization downstream). Margin stays 1.0 (Fitzgerald baseline):
    /// consonant onsets are half-percussive, and a stricter margin would
    /// starve the very onsets the correlation needs.
    static func harmonicMasked(
        _ band: [Float], frames: Int, bins: Int,
        hopSeconds: Double, binHz: Double
    ) -> [Float] {
        let timeTaps = oddTaps(hpssTimeSpanSeconds / hopSeconds, limit: frames)
        let freqTaps = oddTaps(hpssFrequencySpanHz / binHz, limit: bins)
        guard frames >= hpssMinimumFrames, timeTaps >= 3, freqTaps >= 3 else {
            return band  // identity: too little context for a meaningful median
        }

        var harmonic = [Float](repeating: 0, count: band.count)
        var percussive = [Float](repeating: 0, count: band.count)
        var scratch = [Float](repeating: 0, count: max(timeTaps, freqTaps))

        // Harmonic: median across time (per bin column). Reflect boundary.
        let timeHalf = timeTaps / 2
        for bin in 0..<bins {
            for frame in 0..<frames {
                for tap in 0..<timeTaps {
                    let sample = reflected(frame - timeHalf + tap, count: frames)
                    scratch[tap] = band[sample * bins + bin]
                }
                harmonic[frame * bins + bin] = median(&scratch, count: timeTaps)
            }
        }
        // Percussive: median across frequency (per frame row). Reflect boundary.
        let freqHalf = freqTaps / 2
        for frame in 0..<frames {
            for bin in 0..<bins {
                for tap in 0..<freqTaps {
                    let sample = reflected(bin - freqHalf + tap, count: bins)
                    scratch[tap] = band[frame * bins + sample]
                }
                percussive[frame * bins + bin] = median(&scratch, count: freqTaps)
            }
        }

        var masked = [Float](repeating: 0, count: band.count)
        for cell in 0..<band.count {
            let h = harmonic[cell] * harmonic[cell]
            let p = percussive[cell] * percussive[cell]
            let denom = h + p
            masked[cell] = denom > Float.leastNormalMagnitude
                ? band[cell] * (h / denom)
                : 0
        }
        return masked
    }

    /// Physical span → odd tap count, clamped to the available extent (an
    /// even median has no unambiguous center tap).
    private static func oddTaps(_ ideal: Double, limit: Int) -> Int {
        var taps = max(1, Int(ideal.rounded()))
        if taps % 2 == 0 { taps += 1 }
        let bound = limit % 2 == 0 ? limit - 1 : limit
        return min(taps, max(1, bound))
    }

    /// Reflect (mirror-without-repeat) index for boundary handling, matching
    /// scipy `mode="reflect"` used by librosa's HPSS.
    private static func reflected(_ index: Int, count: Int) -> Int {
        if index >= 0 && index < count { return index }
        if index < 0 { return min(-index, count - 1) }
        return max(0, 2 * count - 2 - index)
    }

    /// In-place quickselect median. HPSS calls this roughly half a million
    /// times for a 32-second window; fully insertion-sorting every 21–23 value
    /// neighborhood was O(k²) and dominated end-to-end latency (~2.1s on the
    /// reference machine). Quickselect partitions only until the middle value
    /// is fixed: expected O(k), still allocation-free and deterministic.
    private static func median(_ scratch: inout [Float], count: Int) -> Float {
        let target = count / 2
        var low = 0
        var high = count - 1
        while low < high {
            let pivot = scratch[(low + high) / 2]
            var left = low
            var right = high
            while left <= right {
                while scratch[left] < pivot { left += 1 }
                while scratch[right] > pivot { right -= 1 }
                if left <= right {
                    let value = scratch[left]
                    scratch[left] = scratch[right]
                    scratch[right] = value
                    left += 1
                    right -= 1
                }
            }
            if target <= right {
                high = right
            } else if target >= left {
                low = left
            } else {
                break
            }
        }
        return scratch[target]
    }

    private static func detrend(_ values: [Float], window: Int) -> [Float] {
        guard !values.isEmpty else { return values }
        var result = [Float](repeating: 0, count: values.count)
        let half = window / 2
        for index in values.indices {
            let low = max(0, index - half)
            let high = min(values.count - 1, index + half)
            var mean: Float = 0
            vDSP_meanv(Array(values[low...high]), 1, &mean, vDSP_Length(high - low + 1))
            result[index] = max(0, values[index] - mean)
        }
        return result
    }

    /// 48 kHz capture → 16 kHz analysis rate (÷3 block average). Anything
    /// non-divisible falls back to the original rate — correctness over speed.
    public static func decimated(_ samples: [Float], from rate: Double) -> (samples: [Float], rate: Double) {
        let factor = Int((rate / 16_000).rounded())
        // Empty input must bail here: an empty buffer's baseAddress may be nil,
        // which the vDSP call below force-unwraps.
        guard factor > 1, !samples.isEmpty,
              rate.truncatingRemainder(dividingBy: Double(factor)) == 0 else {
            return (samples, rate)
        }
        let outCount = samples.count / factor
        var output = [Float](repeating: 0, count: outCount)
        samples.withUnsafeBufferPointer { buffer in
            vDSP_desamp(
                buffer.baseAddress!, factor,
                [Float](repeating: 1 / Float(factor), count: factor),
                &output, vDSP_Length(outCount), vDSP_Length(factor)
            )
        }
        return (output, rate / Double(factor))
    }
}
