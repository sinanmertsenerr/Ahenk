import Accelerate
import Foundation

/// Which FFT bins make up each band: the 32 log-spaced spectrum bands and
/// the five summary bands. Built once per sample rate; plain values only,
/// so reading it on the hot path costs no reference counting.
struct BandLayout: Sendable {
    let binCount: Int
    let binHz: Double

    /// Spectrum band `b` averages bins `start[b] ..< end[b]`; a band narrower
    /// than one bin (the lowest ones) interpolates at its centre instead.
    let spectrumStart: SIMD32<Int32>
    let spectrumEnd: SIMD32<Int32>
    let interpolationBin: SIMD32<Int32>
    let interpolationFraction: SIMD32<Float>
    /// Centre frequency of each band in Hz.
    let spectrumCenter: SIMD32<Float>
    /// dB added before display so typical music looks level rather than
    /// sloping down: +3 dB per octave around 500 Hz.
    let spectrumTilt: SIMD32<Float>
    /// 1 for bands below the Nyquist limit, 0 above.
    let spectrumActive: SIMD32<Float>
    /// Spectrum bands below ~160 Hz carry the kick drum.
    let kickBandCount: Int

    /// Summary band `j` sums bins `summaryStart[j] ..< summaryEnd[j]`.
    let summaryStart: SIMD8<Int32>
    let summaryEnd: SIMD8<Int32>
    /// Bins of the kick region (40–150 Hz) for the kick detector.
    let kickBins: Range<Int>

    /// dB added to each summary band so the bands of typical music land at
    /// a similar height (music carries far more power low than high).
    static let summaryOffsets = SIMD8<Float>(2, 0, 6, 7, 12, 0, 0, 0)
    static let tiltPerOctave: Float = 3
    static let tiltPivot: Double = 500

    init(fftSize: Int, sampleRate: Double) {
        binCount = fftSize / 2
        binHz = sampleRate / Double(fftSize)
        let nyquistLimit = sampleRate * 0.48
        let low = AudioFeatures.spectrumRange.lowerBound
        let high = AudioFeatures.spectrumRange.upperBound
        let count = AudioFeatures.spectrumCount

        var start = SIMD32<Int32>.zero
        var end = SIMD32<Int32>.zero
        var interpolationBin = SIMD32<Int32>.zero
        var interpolationFraction = SIMD32<Float>.zero
        var center = SIMD32<Float>.zero
        var tilt = SIMD32<Float>.zero
        var active = SIMD32<Float>.zero
        var kickBands = 0
        for band in 0..<count {
            let lower = low * pow(high / low, Double(band) / Double(count))
            let upper = low * pow(high / low, Double(band + 1) / Double(count))
            let middle = (lower * upper).squareRoot()
            // Bins whose centre lies in [lower, upper).
            let first = max(1, Int((lower / binHz).rounded(.up)))
            let last = min(binCount, Int((upper / binHz).rounded(.up)))
            start[band] = Int32(first)
            end[band] = Int32(max(first, last))
            let position = min(Double(binCount - 2), max(1, middle / binHz))
            interpolationBin[band] = Int32(position.rounded(.down))
            interpolationFraction[band] = Float(position - position.rounded(.down))
            center[band] = Float(middle)
            tilt[band] = Self.tiltPerOctave * Float(log2(middle / Self.tiltPivot))
            active[band] = middle < nyquistLimit ? 1 : 0
            if upper <= 165 { kickBands = band + 1 }
        }
        spectrumStart = start
        spectrumEnd = end
        self.interpolationBin = interpolationBin
        self.interpolationFraction = interpolationFraction
        spectrumCenter = center
        spectrumTilt = tilt
        spectrumActive = active
        kickBandCount = max(1, kickBands)

        var summaryStart = SIMD8<Int32>.zero
        var summaryEnd = SIMD8<Int32>.zero
        let edges = AudioBands.edges
        for band in 0..<AudioBands.count {
            let first = max(1, Int((edges[band] / binHz).rounded(.up)))
            let last = min(binCount, Int((min(edges[band + 1], nyquistLimit) / binHz).rounded(.up)))
            summaryStart[band] = Int32(first)
            summaryEnd[band] = Int32(max(first + 1, last))
        }
        self.summaryStart = summaryStart
        self.summaryEnd = summaryEnd
        let kickFirst = max(1, Int((40 / binHz).rounded(.down)))
        let kickLast = max(kickFirst + 1, Int((150 / binHz).rounded(.up)))
        kickBins = kickFirst..<min(binCount, kickLast)
    }

    /// Mean power per bin of every spectrum band (a power density, so
    /// narrow and wide bands compare).
    func spectrumPower(_ power: UnsafePointer<Float>) -> SIMD32<Float> {
        var result = SIMD32<Float>.zero
        for band in 0..<AudioFeatures.spectrumCount {
            let first = Int(spectrumStart[band])
            let last = Int(spectrumEnd[band])
            if last > first {
                var sum: Float = 0
                vDSP_sve(power + first, 1, &sum, vDSP_Length(last - first))
                result[band] = sum / Float(last - first)
            } else {
                let bin = Int(interpolationBin[band])
                let fraction = interpolationFraction[band]
                result[band] = power[bin] * (1 - fraction) + power[bin + 1] * fraction
            }
        }
        return result
    }

    /// Total power of each summary band.
    func summaryPower(_ power: UnsafePointer<Float>) -> SIMD8<Float> {
        var result = SIMD8<Float>.zero
        for band in 0..<AudioBands.count {
            let first = Int(summaryStart[band])
            let last = Int(summaryEnd[band])
            var sum: Float = 0
            vDSP_sve(power + first, 1, &sum, vDSP_Length(max(0, last - first)))
            result[band] = sum
        }
        return result
    }

    func kickPower(_ power: UnsafePointer<Float>) -> Float {
        var sum: Float = 0
        vDSP_sve(power + kickBins.lowerBound, 1, &sum, vDSP_Length(kickBins.count))
        return sum
    }
}
