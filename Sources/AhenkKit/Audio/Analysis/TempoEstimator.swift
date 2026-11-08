import Foundation

/// Finds the tempo and the beat grid in the last eight seconds of the onset
/// envelope (one value per analysis frame, ~94 per second).
///
/// Every candidate tempo from 60 to 200 BPM (half-BPM steps) lays a grid
/// over the envelope at its best phase and is scored by
/// - **explained**: the share of all onset peaks that fall on the grid,
/// - **fill**: how evenly the grid points are hit (a grid at twice the
///   real tempo explains every kick too, but half of its points are empty),
/// - a mild preference for tempos near 120 BPM (one octave wide).
///
/// `explained × fill² × prior` picks the beat level without octave errors on
/// steady patterns: a kick on every beat reads as its own tempo from 60 to
/// 200 BPM, kick + snare + off-beat hats read as the quarter notes. The
/// confidence compares the winner with the average candidate, so noise (no
/// candidate stands out) stays near 0.
///
/// Fixed-size buffers allocated once; `estimate()` allocates nothing.
final class TempoEstimator {
    struct Estimate: Sendable, Equatable {
        var bpm: Double
        /// `0...1`.
        var confidence: Float
        /// Absolute frame index (fractional) of the newest grid beat.
        var lastBeatFrame: Double
        /// Beat length in frames.
        var period: Double
        /// Share of the onset peaks on the grid, `0...1` (diagnostics).
        var explained: Float
        var fill: Float
    }

    static let minimumBPM = 60.0
    static let maximumBPM = 200.0
    static let bpmStep = 0.5
    static let preferredBPM = 120.0
    /// Width of the tempo preference in octaves (one standard deviation).
    static let preferenceWidth = 1.0
    static let historySeconds = 8.0
    static let minimumSeconds = 2.5

    let frameRate: Double
    let capacity: Int
    private let minimumFrames: Int
    private let candidateCount: Int
    private let history: UnsafeMutablePointer<Float>
    private let linear: UnsafeMutablePointer<Float>
    private let pooled: UnsafeMutablePointer<Float>
    private let grid: UnsafeMutablePointer<Float>
    private let gridCapacity: Int
    private let scores: UnsafeMutablePointer<Float>
    private let priors: UnsafeMutablePointer<Float>
    /// Frames pushed in total.
    private(set) var frameCount = 0

    init(frameRate: Double) {
        self.frameRate = frameRate
        capacity = Int((Self.historySeconds * frameRate).rounded(.up))
        minimumFrames = Int(Self.minimumSeconds * frameRate)
        candidateCount = Int(((Self.maximumBPM - Self.minimumBPM) / Self.bpmStep).rounded()) + 1
        history = .allocate(capacity: capacity)
        history.initialize(repeating: 0, count: capacity)
        linear = .allocate(capacity: capacity)
        linear.initialize(repeating: 0, count: capacity)
        pooled = .allocate(capacity: capacity)
        pooled.initialize(repeating: 0, count: capacity)
        // At most one grid point per minimum beat length, plus slack.
        gridCapacity = Int(Self.historySeconds * Self.maximumBPM / 60) + 4
        grid = .allocate(capacity: gridCapacity)
        grid.initialize(repeating: 0, count: gridCapacity)
        scores = .allocate(capacity: candidateCount)
        scores.initialize(repeating: 0, count: candidateCount)
        priors = .allocate(capacity: candidateCount)
        for index in 0..<candidateCount {
            let bpm = Self.minimumBPM + Double(index) * Self.bpmStep
            let octaves = log2(bpm / Self.preferredBPM) / Self.preferenceWidth
            (priors + index).initialize(to: Float(exp(-0.5 * octaves * octaves)))
        }
    }

    deinit {
        history.deallocate()
        linear.deallocate()
        pooled.deallocate()
        grid.deallocate()
        scores.deallocate()
        priors.deallocate()
    }

    func push(_ value: Float) {
        history[frameCount % capacity] = value
        frameCount += 1
    }

    func reset() {
        frameCount = 0
        history.update(repeating: 0, count: capacity)
    }

    /// The best tempo for the envelope so far; `nil` until there are a few
    /// seconds of it or while it holds no onsets.
    func estimate() -> Estimate? {
        let available = min(frameCount, capacity)
        guard available >= minimumFrames else { return nil }
        // Oldest first.
        let oldest = frameCount - available
        for index in 0..<available {
            linear[index] = history[(oldest + index) % capacity]
        }
        // Onset mass: the height of every local peak.
        var peakSum: Float = 0
        var peakCount = 0
        // The three highest peaks, highest first.
        var first: Float = 0
        var second: Float = 0
        var third: Float = 0
        for index in 1..<(available - 1) {
            let value = linear[index]
            if value > 1e-6, value > linear[index - 1], value >= linear[index + 1] {
                peakSum += value
                peakCount += 1
                if value > first {
                    (first, second, third) = (value, first, second)
                } else if value > second {
                    (second, third) = (value, second)
                } else if value > third {
                    third = value
                }
            }
        }
        // A tempo needs a few clear onsets; a lone attack (a tone that
        // started once) fits every grid. "Clear" is measured against the
        // third-highest peak, so one or two huge hits do not hide the rest.
        guard peakSum > 1e-6, peakCount >= Self.minimumOnsets else { return nil }
        var clearPeaks = 0
        for index in 1..<(available - 1) {
            let value = linear[index]
            if value >= 0.2 * third, value > linear[index - 1], value >= linear[index + 1] { clearPeaks += 1 }
        }
        guard clearPeaks >= Self.minimumOnsets else { return nil }
        // ±1 frame of timing tolerance.
        pooled[0] = max(linear[0], linear[1])
        pooled[available - 1] = max(linear[available - 2], linear[available - 1])
        for index in 1..<(available - 1) {
            pooled[index] = max(linear[index - 1], max(linear[index], linear[index + 1]))
        }

        var best = -1
        var bestScore: Float = 0
        var bestPhase = 0.0
        var bestExplained: Float = 0
        var bestFill: Float = 0
        var scoreSum: Float = 0
        for candidate in 0..<candidateCount {
            let bpm = Self.minimumBPM + Double(candidate) * Self.bpmStep
            let period = frameRate * 60 / bpm
            let (phase, sum) = strongestPhase(period: period, available: available)
            let explained = min(1, sum / peakSum)
            let fill = self.fill(period: period, phase: phase, available: available)
            let score = explained * fill * fill * priors[candidate]
            scores[candidate] = score
            scoreSum += score
            if score > bestScore {
                bestScore = score
                best = candidate
                bestPhase = phase
                bestExplained = explained
                bestFill = fill
            }
        }
        guard best >= 0, bestScore > 0 else { return nil }

        // Sub-step tempo from a parabola through the neighbours.
        var bpm = Self.minimumBPM + Double(best) * Self.bpmStep
        if best > 0, best < candidateCount - 1 {
            let left = scores[best - 1]
            let right = scores[best + 1]
            let denominator = left - 2 * bestScore + right
            if denominator < 0 {
                let shift = Double(0.5 * (left - right) / denominator)
                bpm += max(-0.5, min(0.5, shift)) * Self.bpmStep
            }
        }
        let period = frameRate * 60 / bpm

        // How far the winner stands out from the average candidate.
        let mean = scoreSum / Float(candidateCount)
        let contrast = mean > 0 ? bestScore / mean : 0
        let confidence = min(1, max(0, (contrast - Self.contrastFloor) / Self.contrastSpan))
            * min(1, bestExplained / Self.explainedForFullConfidence)
            * min(1, bestFill / Self.fillForFullConfidence)

        // The newest grid beat whose neighbourhood is complete, snapped to
        // the envelope peak next to it.
        var position = bestPhase
        let lastUsable = Double(available - 3)
        if position <= lastUsable {
            position += ((lastUsable - position) / period).rounded(.down) * period
        }
        position = refinedPeak(near: position, available: available)
        return Estimate(
            bpm: bpm, confidence: confidence, lastBeatFrame: Double(oldest) + position, period: period,
            explained: bestExplained, fill: bestFill
        )
    }

    /// Score contrast (winner / average candidate) at which confidence starts…
    static let contrastFloor: Float = 1.8
    /// …and the extra contrast for full confidence.
    static let contrastSpan: Float = 2.2
    /// A winner explaining less than this share of the onsets is trusted less…
    static let explainedForFullConfidence: Float = 0.3
    /// …and so is one whose grid misses many beats.
    static let fillForFullConfidence: Float = 0.75
    /// Clear onsets needed in the window before any tempo is guessed.
    static let minimumOnsets = 4

    /// The grid phase (in frames, `0..<period`) that collects the most onset
    /// strength, and that strength.
    private func strongestPhase(period: Double, available: Int) -> (phase: Double, sum: Float) {
        let phases = Int(period.rounded(.up))
        var bestSum: Float = -1
        var bestPhase = 0
        for phase in 0..<phases {
            var sum: Float = 0
            var position = Double(phase)
            while position < Double(available) - 0.5 {
                sum += pooled[Int(position + 0.5)]
                position += period
            }
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
        }
        return (Double(bestPhase), max(0, bestSum))
    }

    /// The share of grid points that hit an onset: each point counts fully
    /// once it reaches half the typical strong onset, so weaker beats in an
    /// accent pattern (kick, then kick + snare) still count while empty
    /// points do not. 1 for a grid on every beat, 0.5 for a grid at twice
    /// the real tempo.
    private func fill(period: Double, phase: Double, available: Int) -> Float {
        var count = 0
        var position = phase
        while position < Double(available) - 0.5, count < gridCapacity {
            let value = pooled[Int(position + 0.5)]
            // Insertion sort, descending (at most ~30 values).
            var slot = count
            while slot > 0, grid[slot - 1] < value {
                grid[slot] = grid[slot - 1]
                slot -= 1
            }
            grid[slot] = value
            count += 1
            position += period
        }
        guard count >= 2 else { return 0 }
        let strong = (count + 1) / 2
        var strongTotal: Float = 0
        for index in 0..<strong { strongTotal += grid[index] }
        guard strongTotal > 0 else { return 0 }
        let full = 0.5 * strongTotal / Float(strong)
        var hits: Float = 0
        for index in 0..<count { hits += min(1, grid[index] / full) }
        return hits / Float(count)
    }

    /// The envelope peak within two frames of `position`, with sub-frame
    /// precision; `position` itself if there is no peak there.
    private func refinedPeak(near position: Double, available: Int) -> Double {
        let center = Int(position.rounded())
        var peak = -1
        var peakValue: Float = 0
        for index in max(1, center - 2)...min(available - 2, center + 2) where linear[index] > peakValue {
            peakValue = linear[index]
            peak = index
        }
        guard peak > 0, peakValue > 1e-6 else { return position }
        let left = linear[peak - 1]
        let right = linear[peak + 1]
        let denominator = left - 2 * peakValue + right
        let shift = denominator < 0 ? Double(0.5 * (left - right) / denominator) : 0
        return Double(peak) + max(-0.5, min(0.5, shift))
    }
}
