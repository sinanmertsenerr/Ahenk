import Accelerate
import Foundation

/// Estimates the constant time-shift between community LRC timestamps and the
/// actually-playing audio by correlating the lyric line starts against the
/// onset-novelty curve. The design constraint is asymmetric: a WRONG
/// correction is worse than none, so every ambiguous case returns nil and the
/// lyrics stay untouched.
///
/// Ported from DynamicIsland (same author, MIT). Acceptance is decided by
/// three cooperating measures (calibrated there against synthetic
/// beat-periodic music, 440+ runs, zero wrong accepts):
/// - **z-score**: the winning lag's correlation peak against the median/MAD of
///   the whole lag-score curve. Replaces the old `peak > mean*1.5` absolute
///   floor, which was mathematically unpassable for busy high-mean novelty
///   (dense beats) and silently rejected ~100% of real strong-beat tracks.
/// - **alias-aware prominence**: runner-up peaks sitting at the winner ±k×beat
///   period are correlation ALIASES of the winner, not competitors — but only
///   when clearly below it (`aliasDominance`); a near-equal alias means genuine
///   periodic ambiguity (instrumental, lines on the beat grid) and still rejects.
/// - **split-half rescue**: a borderline peak is accepted only when odd and
///   even lyric lines independently lock onto the same lag (±`splitAgreeSeconds`)
///   — periodic content can't fake agreement across two disjoint line sets
///   while also clearing the rescue z/prominence floors.
public enum LyricOffsetEstimator {
    public struct Estimate: Sendable, Equatable {
        /// How early the LRC runs relative to the audio, in seconds
        /// (positive = lyric timestamps fire before the sung audio). The
        /// correction to apply in user-offset space (positive = lyrics
        /// earlier) is `-leadSeconds`.
        public var leadSeconds: Double
        /// Peak quality, 0…1 (prominence on the primary path, fixed 0.5 on
        /// the split-half rescue path).
        public var confidence: Double
    }

    /// The estimate and its diagnostics from one shared correlation pass.
    /// Callers that need both must use this value instead of analyzing the
    /// same audio twice (which used to double the hottest DSP work).
    public struct Decision: Sendable {
        public var estimate: Estimate?
        public var diagnostics: Diagnostics
    }

    /// The consensus result plus the earlier window that corroborated it.
    /// Keeping this arbitration in the estimator lets callers retain the
    /// matching capture metadata without reimplementing consensus selection.
    public struct ConsensusSelection: Sendable, Equatable {
        public let estimate: Estimate
        public let priorIndex: Int

        init(estimate: Estimate, priorIndex: Int) {
            self.estimate = estimate
            self.priorIndex = priorIndex
        }
    }

    /// Why (and how) a measurement was decided — for the caller's logging
    /// only, so live rejections stop being a black box. Adding this as a
    /// SEPARATE api keeps `estimate`'s widely-consumed signature untouched.
    /// Also the cross-window consensus currency: a rejected-but-measurable
    /// window's diagnostics can later corroborate a second window's.
    public struct Diagnostics: Sendable {
        public enum Stage: String, Sendable {
            case empty
            case tooFewLines = "too-few-lines"
            case flatNovelty = "flat-novelty"
            case windowTooShort = "window-too-short"
            case noPeak = "no-peak"
            case edgePeak = "edge-peak"
            case accepted
            case weakPeak = "weak-peak"
            case rescueNoHalves = "rescue-no-halves"
            case halvesDisagree = "halves-disagree"
            case acceptedSplitHalf = "accepted-split-half"
        }

        public var stage: Stage
        public var leadSeconds: Double
        public var prominence: Double
        public var zScore: Double
        /// Beat period of the analyzed window's novelty curve (nil when the
        /// window isn't meaningfully periodic). Consensus uses it to refuse
        /// beat-alias agreement.
        public var dominantPeriodSeconds: Double?
        /// The beat period the audio analysis tracked during the window
        /// (Ahenk's tempo tracker), when it was locked. Novelty
        /// autocorrelation can settle on a backbeat (two beats) and miss
        /// aliases at odd numbers of beats; the tracked beat catches them.
        public var trackedBeatSeconds: Double?

        public init(
            stage: Stage,
            leadSeconds: Double,
            prominence: Double,
            zScore: Double,
            dominantPeriodSeconds: Double? = nil
        ) {
            self.stage = stage
            self.leadSeconds = leadSeconds
            self.prominence = prominence
            self.zScore = zScore
            self.dominantPeriodSeconds = dominantPeriodSeconds
        }
    }

    /// Minimum lyric lines inside the window for the impulse train to have
    /// enough correlation structure.
    public static let minimumLines = 5
    /// Largest correction the estimator can search in either direction.
    /// Capture planning uses the same value to retain enough tail context.
    public static let maximumLagSeconds = 2.0
    /// Triangular pulse half-width around each line start — sized to absorb
    /// the human jitter in community LRC annotations (0.12 was too tight:
    /// sloppy-but-usable LRCs smeared their own correlation peak away).
    static let pulseHalfWidthSeconds = 0.22
    /// Runner-up peaks within this distance of the winner are the same
    /// (possibly smeared) peak.
    static let peakExclusionSeconds = 0.30
    /// An alias is excused from the runner-up only below this fraction of the
    /// winner; at or above it the field is genuinely ambiguous.
    static let aliasDominance = 0.85
    static let prominenceThreshold = 0.25
    static let zThreshold = 3.0
    static let rescueZThreshold = 2.2
    static let rescueProminenceThreshold = 0.12
    static let splitAgreeSeconds = 0.16
    /// Two windows must land within this distance of each other for
    /// cross-window consensus.
    public static let consensusAgreeSeconds = 0.15
    /// Corrections below this magnitude use the stricter micro evidence class.
    public static let microCorrectionThresholdSeconds = 0.15
    /// Two fully-qualified micro windows must agree within this distance.
    public static let microConsensusAgreeSeconds = 0.10
    /// Consensus loosens the CORROBORATION requirement (cross-window
    /// agreement replaces in-window split-half agreement) — never the
    /// per-window quality floor. Candidates must still clear the rescue
    /// floors; anything weaker is indistinguishable from noise.
    static let consensusZFloor = rescueZThreshold
    static let consensusProminenceFloor = rescueProminenceThreshold
    /// Witness tier: dense beats destroy PROMINENCE specifically (the beat
    /// grid is a forest of runner-up peaks) while the z-score of a real lock
    /// survives — live tracks measured lead pairs 0.032s/0.064s apart whose
    /// second window sat at prominence 0.02–0.05 and died on the floor. A
    /// window that fails only the prominence floor may therefore CORROBORATE
    /// (never lead): its z must still clear the rescue floor and its lead must
    /// land inside this tighter tolerance of a fully-qualified candidate. The
    /// applied lead is the qualified window's, not the average.
    public static let witnessAgreeSeconds = 0.10
    static let witnessZFloor = rescueZThreshold
    // NOTE (signal v2, deliberate omission): PHAT-style whitening of the
    // novelty curve was prototyped here and REVERTED — flattening the
    // spectrum destroys the "near-equal beat aliases → prominence ≈ 0"
    // natural defense and let a beat-aligned instrumental pass the
    // split-half rescue in the adversarial suite (a false accept, the worst
    // failure class). Whitening may return only together with a
    // surrogate-null recalibration of every gate threshold.
    /// Agreement lags this close to a beat-period multiple are refused —
    /// beat-grid aliasing is deterministic per track, so two windows of the
    /// same song agreeing at an alias is expected, not corroboration.
    static let consensusAliasToleranceSeconds = 0.10
    /// Stages whose diagnostics carry a trustworthy measured peak and may
    /// take part in consensus. A window whose own odd/even lyric subsets
    /// disagree (or cannot be evaluated) is not independent evidence: in
    /// the field, pairing one such window with a primary peak moved already
    /// correct lyrics two thirds of a second early. `weakPeak` remains
    /// witness-only below; it can never lead a correction by itself.
    ///
    /// Even a primary `accepted` result is only a candidate: any single
    /// real-music window can produce a convincing false peak.
    static let consensusEligibleStages: Set<Diagnostics.Stage> = [
        .accepted, .weakPeak, .acceptedSplitHalf,
    ]
    /// Only fully accepted windows may become drift/model observations. Weak
    /// peaks are allowed solely as a tightly agreeing second opinion for the
    /// initial constant; they must never steer a later timing curve.
    static let timingModelEligibleStages: Set<Diagnostics.Stage> = [
        .accepted, .acceptedSplitHalf,
    ]

    /// - Parameters:
    ///   - novelty: normalized onset curve of the captured window.
    ///   - lineOffsets: LRC line starts in seconds RELATIVE to the window
    ///     start, for lines that fall inside the window.
    public static func estimate(
        novelty: OnsetNovelty.Curve,
        lineOffsets: [Double]
    ) -> Estimate? {
        evaluate(novelty: novelty, lineOffsets: lineOffsets).estimate
    }

    /// Same decision pipeline, but always returns the measured values and the
    /// gate that decided — never changes what `estimate` would have returned.
    public static func diagnose(
        novelty: OnsetNovelty.Curve,
        lineOffsets: [Double]
    ) -> Diagnostics {
        evaluate(novelty: novelty, lineOffsets: lineOffsets).diagnostics
    }

    /// Runs the estimator once and returns both the public estimate and the
    /// diagnostics used for cross-window arbitration.
    public static func evaluate(
        novelty: OnsetNovelty.Curve,
        lineOffsets: [Double]
    ) -> Decision {
        decide(novelty: novelty, lineOffsets: lineOffsets)
    }

    // MARK: Decision core

    private static func decide(
        novelty: OnsetNovelty.Curve,
        lineOffsets: [Double]
    ) -> Decision {
        func rejected(_ stage: Diagnostics.Stage) -> Decision {
            Decision(estimate: nil, diagnostics: Diagnostics(
                stage: stage, leadSeconds: 0, prominence: 0, zScore: 0,
                dominantPeriodSeconds: nil
            ))
        }

        let hop = novelty.hopSeconds
        let frames = novelty.values.count
        guard hop > 0, frames > 0 else { return rejected(.empty) }
        let duration = Double(frames) * hop

        let sortedUsable = lineOffsets.filter { $0 >= 0 && $0 < duration }.sorted()
        let usable = sortedUsable.reduce(into: [Double]()) { unique, value in
            if unique.last.map({ value - $0 >= 0.05 }) ?? true {
                unique.append(value)
            }
        }
        guard usable.count >= minimumLines else { return rejected(.tooFewLines) }

        // The pre-HPSS flux when the curve carries it. Two gates key off it:
        // - Flatness is a property of the CAPTURED AUDIO, not of the masked
        //   signal — a clean post-HPSS curve is legitimately sparse (a
        //   handful of vocal onsets and silence between them; the lab case
        //   measured 1.8% active on a perfect extraction), and judging it
        //   with the silence heuristic rejects exactly the success case.
        // - Beat-alias safety needs the track's periodicity at its
        //   strongest: the harmonic mask deliberately weakens the beat grid
        //   in `values`, and an alias gate fed the masked signal would
        //   silently stop firing while residual beat energy still aliases
        //   the correlation.
        let aliasReference = novelty.rawValues.isEmpty ? novelty.values : novelty.rawValues

        // A near-flat capture (no onsets at all — silence or a sustained
        // pad) can't anchor anything.
        let activeFraction = Double(aliasReference.filter { $0 > 0.1 }.count)
            / Double(aliasReference.count)
        guard activeFraction > 0.02 else { return rejected(.flatNovelty) }

        let maxLag = Int(maximumLagSeconds / hop)
        guard maxLag > 0, frames > maxLag else { return rejected(.windowTooShort) }

        let period = dominantPeriod(novelty: aliasReference, hop: hop)
        let correlationInput = novelty.values

        guard let full = analyze(
            novelty: correlationInput, hop: hop, lines: usable, maxLag: maxLag, period: period
        ) else { return rejected(.noPeak) }
        let diagnostics = Diagnostics(
            stage: .empty,
            leadSeconds: Double(full.lag) * hop,
            prominence: full.prominence,
            zScore: full.z,
            dominantPeriodSeconds: period
        )

        // A boundary-hit peak usually means the true lag is outside the
        // window (or nothing correlates) — not a trustworthy match.
        guard abs(full.lag) < maxLag else {
            return Decision(estimate: nil, diagnostics: with(diagnostics, stage: .edgePeak))
        }

        // Primary gate: the winner clearly rises out of the lag-score field
        // AND beats every non-alias competitor.
        if full.z >= zThreshold, full.prominence >= prominenceThreshold {
            return Decision(
                estimate: Estimate(
                    leadSeconds: Double(full.lag) * hop,
                    confidence: min(1, full.prominence)
                ),
                diagnostics: with(diagnostics, stage: .accepted)
            )
        }

        // Rescue gate: borderline peak, but two disjoint half-sets of lines
        // independently lock onto the same lag.
        guard full.z >= rescueZThreshold, full.prominence >= rescueProminenceThreshold else {
            return Decision(estimate: nil, diagnostics: with(diagnostics, stage: .weakPeak))
        }
        let odd = usable.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let even = usable.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        guard odd.count >= 2, even.count >= 2,
              let oddPeak = analyze(
                  novelty: correlationInput, hop: hop, lines: odd, maxLag: maxLag, period: period
              ),
              let evenPeak = analyze(
                  novelty: correlationInput, hop: hop, lines: even, maxLag: maxLag, period: period
              )
        else {
            return Decision(
                estimate: nil, diagnostics: with(diagnostics, stage: .rescueNoHalves)
            )
        }
        let tolerance = Int(splitAgreeSeconds / hop)
        guard abs(oddPeak.lag - evenPeak.lag) <= tolerance,
              abs(oddPeak.lag - full.lag) <= tolerance,
              abs(evenPeak.lag - full.lag) <= tolerance
        else {
            return Decision(
                estimate: nil, diagnostics: with(diagnostics, stage: .halvesDisagree)
            )
        }
        return Decision(
            estimate: Estimate(leadSeconds: Double(full.lag) * hop, confidence: 0.5),
            diagnostics: with(diagnostics, stage: .acceptedSplitHalf)
        )
    }

    private static func with(
        _ diagnostics: Diagnostics, stage: Diagnostics.Stage
    ) -> Diagnostics {
        var updated = diagnostics
        updated.stage = stage
        return updated
    }

    // MARK: Cross-window consensus

    /// Corroboration across two INDEPENDENT capture windows of the same track:
    /// the same lag — either two accepted windows clearing the quality floors
    /// (strict tier), or one accepted window seconded by a prominence-starved
    /// witness at a tighter tolerance (witness tier). Windows whose internal
    /// lyric subsets disagree are deliberately excluded. Periodic content can fake
    /// this (beat aliasing is a property of the TRACK, identical in every
    /// window), so agreement at a beat-period multiple of either window is
    /// refused outright — consensus is STRICTER on periodic content, not
    /// looser. The asymmetric design constraint stands: any doubt → nil.
    public static func consensus(
        _ first: Diagnostics, _ second: Diagnostics
    ) -> Estimate? {
        guard consensusEligibleStages.contains(first.stage),
              consensusEligibleStages.contains(second.stage),
              hasFiniteConsensusMeasurement(first),
              hasFiniteConsensusMeasurement(second)
        else { return nil }

        let agreed: Double
        let firstFullyQualified = isFullyQualifiedConsensusWindow(first)
        let secondFullyQualified = isFullyQualifiedConsensusWindow(second)
        if firstFullyQualified, secondFullyQualified {
            guard abs(first.leadSeconds - second.leadSeconds) <= consensusAgreeSeconds
            else { return nil }
            agreed = (first.leadSeconds + second.leadSeconds) / 2

            // Sub-150 ms corrections use a stricter evidence class: both
            // windows must point in the same nonzero direction (or both be
            // exactly zero) and land within 100 ms. There is deliberately no
            // minimum nonzero magnitude or rounding deadband here.
            if isMicroCorrection(agreed) {
                guard abs(first.leadSeconds - second.leadSeconds) <= microConsensusAgreeSeconds,
                      haveCompatibleMicroDirections(first, second)
                else { return nil }
            }
        } else if firstFullyQualified || secondFullyQualified {
            // Witness tier: the weak window corroborates but never leads —
            // z floor holds (prominence is what dense beats destroy), the
            // agreement tolerance tightens, and the qualified lead applies.
            let qualified = firstFullyQualified ? first : second
            let witness = firstFullyQualified ? second : first
            guard witness.zScore >= witnessZFloor,
                  abs(qualified.leadSeconds - witness.leadSeconds) <= witnessAgreeSeconds
            else { return nil }
            agreed = qualified.leadSeconds

            // A weak witness retains the established large-correction recall
            // path, but can never authorize a micro correction.
            guard !isMicroCorrection(agreed) else { return nil }
        } else {
            return nil  // agreement between two noise-floor windows is not evidence
        }
        guard !isBeatAlias(leadSeconds: agreed, windows: [first, second])
        else { return nil }
        return Estimate(leadSeconds: agreed, confidence: 0.5)
    }

    /// Pure cross-window arbitration that returns both the estimate and the
    /// prior that produced it. If a micro candidate exists, every other
    /// fully-qualified prior must join the same directionally-consistent
    /// 100 ms cluster; one contradictory strong window vetoes the correction.
    public static func consensusSelection(
        priors: [Diagnostics], current: Diagnostics
    ) -> ConsensusSelection? {
        var firstLargeSelection: ConsensusSelection?
        var bestMicroSelection: ConsensusSelection?
        var bestMicroDistance = Double.infinity

        for (index, prior) in priors.enumerated() {
            guard let estimate = consensus(prior, current) else { continue }
            let selection = ConsensusSelection(estimate: estimate, priorIndex: index)
            if isMicroCorrection(estimate.leadSeconds) {
                let distance = abs(prior.leadSeconds - current.leadSeconds)
                if distance < bestMicroDistance {
                    bestMicroSelection = selection
                    bestMicroDistance = distance
                }
            } else if firstLargeSelection == nil {
                // Preserve the established large-correction selection order.
                firstLargeSelection = selection
            }
        }

        guard let microSelection = bestMicroSelection else {
            return firstLargeSelection
        }

        let fullyQualifiedPriors = priors.filter(isFullyQualifiedConsensusWindow)
        guard microClusterIsCoherent(
            priors: fullyQualifiedPriors,
            current: current
        ) else { return nil }
        return microSelection
    }

    /// Consensus-only state-machine boundary: no current window can produce
    /// an estimate when `priors` is empty, regardless of how strong it looks.
    /// A result is returned only when an independent earlier window agrees.
    public static func consensus(
        priors: [Diagnostics], current: Diagnostics
    ) -> Estimate? {
        consensusSelection(priors: priors, current: current)?.estimate
    }

    private static func hasFiniteConsensusMeasurement(_ window: Diagnostics) -> Bool {
        guard window.leadSeconds.isFinite,
              window.zScore.isFinite,
              window.prominence.isFinite
        else { return false }
        guard let period = window.dominantPeriodSeconds else { return true }
        return period.isFinite && period > 0
    }

    private static func isFullyQualifiedConsensusWindow(_ window: Diagnostics) -> Bool {
        timingModelEligibleStages.contains(window.stage)
            && hasFiniteConsensusMeasurement(window)
            && window.zScore >= consensusZFloor
            && window.prominence >= consensusProminenceFloor
    }

    private static func isMicroCorrection(_ leadSeconds: Double) -> Bool {
        abs(leadSeconds) < microCorrectionThresholdSeconds
    }

    private static func haveCompatibleMicroDirections(
        _ first: Diagnostics, _ second: Diagnostics
    ) -> Bool {
        let bothZero = first.leadSeconds == 0 && second.leadSeconds == 0
        let sameNonzeroDirection = first.leadSeconds != 0
            && second.leadSeconds != 0
            && (first.leadSeconds > 0) == (second.leadSeconds > 0)
        return bothZero || sameNonzeroDirection
    }

    private static func microClusterIsCoherent(
        priors: [Diagnostics], current: Diagnostics
    ) -> Bool {
        guard isFullyQualifiedConsensusWindow(current), !priors.isEmpty else {
            return false
        }

        var minimumLead = current.leadSeconds
        var maximumLead = current.leadSeconds
        for prior in priors {
            guard let estimate = consensus(prior, current),
                  isMicroCorrection(estimate.leadSeconds)
            else { return false }
            minimumLead = min(minimumLead, prior.leadSeconds)
            maximumLead = max(maximumLead, prior.leadSeconds)
        }
        return maximumLead - minimumLead <= microConsensusAgreeSeconds
    }

    private static func isBeatAlias(
        leadSeconds: Double, windows: [Diagnostics]
    ) -> Bool {
        let periods = windows.compactMap(\.dominantPeriodSeconds) + windows.compactMap(\.trackedBeatSeconds)
        for period in periods where period > 0 {
            let distance = abs(leadSeconds).truncatingRemainder(dividingBy: period)
            let toNearestMultiple = min(distance, period - distance)
            let periods = (abs(leadSeconds) / period).rounded()
            if periods >= 1, toNearestMultiple <= consensusAliasToleranceSeconds {
                return true
            }
        }
        return false
    }

    /// A later position may disagree with the initial constant because of real
    /// clock drift. Such a window can join a multi-position model only when it
    /// independently clears the full quality floor and is not itself explained
    /// by an integer multiple of the window's beat grid. Weak witness windows
    /// remain useful for the initial constant consensus, never for drift.
    public static func qualifiesForTimingModel(_ window: Diagnostics) -> Bool {
        guard timingModelEligibleStages.contains(window.stage),
              window.leadSeconds.isFinite,
              abs(window.leadSeconds) <= maximumLagSeconds,
              window.zScore >= consensusZFloor,
              window.prominence >= consensusProminenceFloor
        else { return false }
        guard let period = window.dominantPeriodSeconds,
              period.isFinite, period > 0
        else { return true }
        let distance = abs(window.leadSeconds).truncatingRemainder(dividingBy: period)
        let toNearestMultiple = min(distance, period - distance)
        let periods = (abs(window.leadSeconds) / period).rounded()
        return periods < 1 || toNearestMultiple > consensusAliasToleranceSeconds
    }

    private struct Peak {
        var lag: Int
        var value: Double
        var prominence: Double
        var z: Double
    }

    /// Correlates the line impulse train against the novelty curve
    /// and grades the winning lag (z-score vs the lag-score field, alias-aware
    /// prominence). `period` is the track's dominant beat period measured on
    /// the UNMASKED flux — passed in rather than recomputed here so alias
    /// excusing keys off the track's real grid (see `decide`).
    private static func analyze(
        novelty: [Float], hop: Double, lines: [Double], maxLag: Int, period: Double?
    ) -> Peak? {
        let frames = novelty.count

        // Impulse train: triangular pulses at each line start.
        var train = [Float](repeating: 0, count: frames)
        let pulseFrames = max(1, Int(pulseHalfWidthSeconds / hop))
        for offset in lines {
            let center = Int(offset / hop)
            for delta in -pulseFrames...pulseFrames {
                let index = center + delta
                guard index >= 0, index < frames else { continue }
                let weight = 1 - Float(abs(delta)) / Float(pulseFrames + 1)
                train[index] = max(train[index], weight)
            }
        }

        // Direct correlation over the lag range — the signals are short
        // (~1.4k frames), so O(N·L) is microseconds; no FFT needed.
        var scores = [Double](repeating: 0, count: 2 * maxLag + 1)
        for (slot, lag) in (-maxLag...maxLag).enumerated() {
            var sum: Double = 0
            var count = 0
            for index in 0..<frames {
                let noveltyIndex = index + lag
                guard noveltyIndex >= 0, noveltyIndex < frames else { continue }
                if train[index] > 0 {
                    sum += Double(novelty[noveltyIndex]) * Double(train[index])
                    count += 1
                }
            }
            scores[slot] = count > 0 ? sum / Double(count) : 0
        }

        guard let peakValue = scores.max(), peakValue > 0,
              let peakSlot = scores.firstIndex(of: peakValue)
        else { return nil }
        let peakLag = peakSlot - maxLag

        // z-score of the winner against the lag-score field. Median/MAD is
        // robust to the peak itself and to a handful of alias peaks.
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = scores.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let sigma = Swift.max(mad * 1.4826, 1e-9)
        let z = (peakValue - median) / sigma

        // Prominence vs the best peak OUTSIDE the winner's neighborhood,
        // excusing clearly-dominated beat aliases of the winner.
        let exclusion = max(1, Int(peakExclusionSeconds / hop))
        let aliasTolerance = max(2, Int(0.08 / hop))
        var runnerUp: Double = 0
        for (slot, value) in scores.enumerated() where abs(slot - peakSlot) > exclusion {
            if let period, value < aliasDominance * peakValue {
                let framesPerPeriod = period / hop
                let deltaPeriods = Double(abs(slot - peakSlot)) / framesPerPeriod
                let nearestK = deltaPeriods.rounded()
                if nearestK >= 1,
                   abs(Double(abs(slot - peakSlot)) - nearestK * framesPerPeriod)
                       <= Double(aliasTolerance) {
                    continue
                }
            }
            runnerUp = max(runnerUp, value)
        }
        let prominence = (peakValue - runnerUp) / peakValue
        return Peak(lag: peakLag, value: peakValue, prominence: prominence, z: z)
    }

    /// Dominant periodicity of the novelty curve (the beat period) via
    /// autocorrelation over the 0.24–1.2s range; nil when the curve isn't
    /// meaningfully periodic (then no alias excusing happens at all).
    static func dominantPeriod(novelty: [Float], hop: Double) -> Double? {
        let count = novelty.count
        guard count > 0 else { return nil }
        let mean = novelty.reduce(0) { $0 + Double($1) } / Double(count)
        let centered = novelty.map { Double($0) - mean }
        var norm: Double = 0
        for value in centered { norm += value * value }
        guard norm > 0 else { return nil }
        let minLag = max(1, Int(0.24 / hop))
        let maxLag = min(count - 1, Int(1.2 / hop))
        guard minLag < maxLag else { return nil }
        var best = 0.0
        var bestLag = 0
        for lag in minLag...maxLag {
            var sum: Double = 0
            for index in 0..<(count - lag) { sum += centered[index] * centered[index + lag] }
            let correlation = sum / norm
            if correlation > best {
                best = correlation
                bestLag = lag
            }
        }
        guard best > 0.15 else { return nil }
        return Double(bestLag) * hop
    }
}
