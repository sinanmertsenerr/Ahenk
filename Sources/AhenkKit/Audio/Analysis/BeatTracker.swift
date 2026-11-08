import Foundation

/// A beat the analyzer found, in audio seconds (the analyzer's timeline).
public struct BeatEvent: Sendable, Equatable {
    public var time: Double
    public var index: Int
    /// `0...1`.
    public var strength: Float
    /// True when it came from the tempo grid, false when a kick triggered it.
    public var isPredicted: Bool
}

/// Turns tempo estimates and onsets into beats.
///
/// - **Locked** (a confident tempo): beats are predicted on the grid and
///   announced `anticipation` early, so they land on time despite the
///   analysis latency. Every onset near a beat nudges the phase and the
///   period (a phase-locked loop); a new tempo must win three estimates in
///   a row before it replaces the current one.
/// - **Unlocked** (the first seconds, music without a steady beat): a beat
///   is a strong kick, at most one per refractory period.
struct BeatTracker: Sendable {
    static let lockConfidence: Float = 0.35
    static let unlockConfidence: Float = 0.2
    /// Low-confidence estimates in a row (about half a second apart) before
    /// the lock is dropped.
    static let unlockAfter = 4
    static let anticipation = 0.03
    /// Shortest time between two kick-triggered beats.
    static let refractory = 0.28

    private(set) var isLocked = false
    /// Seconds per beat (0 while unlocked).
    private(set) var period: Double = 0
    private(set) var nextBeat: Double = 0
    private(set) var beatTime: Double = -.infinity
    private(set) var previousBeatTime: Double = -.infinity
    private(set) var beatStrength: Float = 0
    private(set) var previousBeatStrength: Float = 0
    private(set) var beatIndex = 0
    private(set) var confidence: Float = 0
    /// Typical strength of the onsets that land on beats.
    private var accent: Float = 0.8
    private var lowConfidenceCount = 0
    private var pendingBPM = 0.0
    private var pendingCount = 0
    private var phaseMisses = 0

    var bpm: Double { isLocked && period > 0 ? 60 / period : 0 }

    mutating func reset() {
        let index = beatIndex
        self = BeatTracker()
        beatIndex = index
    }

    /// Continues the beat counter from `index` (a new analyzer replacing
    /// one that already counted beats).
    mutating func continueCounting(from index: Int) {
        beatIndex = max(beatIndex, index)
    }

    /// Forgets the tempo but keeps the beat counter (and the last beat, so
    /// a pulse in progress can finish).
    mutating func unlock() {
        isLocked = false
        period = 0
        confidence = 0
        lowConfidenceCount = 0
        pendingCount = 0
        phaseMisses = 0
    }

    /// A new tempo estimate; `gridBeat` is its newest grid beat (seconds),
    /// `now` the time of the current frame.
    mutating func apply(bpm: Double, confidence: Float, gridBeat: Double, now: Double) {
        self.confidence = confidence
        let estimatedPeriod = 60 / bpm
        guard confidence >= Self.lockConfidence else {
            if confidence < Self.unlockConfidence, isLocked {
                lowConfidenceCount += 1
                if lowConfidenceCount >= Self.unlockAfter { unlock() }
            }
            return
        }
        lowConfidenceCount = 0
        guard isLocked else {
            lock(period: estimatedPeriod, gridBeat: gridBeat, now: now)
            return
        }
        if abs(estimatedPeriod / period - 1) < 0.04 {
            pendingCount = 0
            period += 0.3 * (estimatedPeriod - period)
            let error = phaseError(of: gridBeat)
            if abs(error) < 0.25 * period {
                nextBeat += 0.4 * error
                phaseMisses = 0
            } else {
                phaseMisses += 1
                if phaseMisses >= 2 {
                    lock(period: period, gridBeat: gridBeat, now: now)
                }
            }
        } else {
            if pendingBPM > 0, abs(bpm / pendingBPM - 1) < 0.04 {
                pendingCount += 1
            } else {
                pendingBPM = bpm
                pendingCount = 1
            }
            if pendingCount >= 3 {
                lock(period: estimatedPeriod, gridBeat: gridBeat, now: now)
            }
        }
    }

    /// An onset at `time` with normalized `strength`: corrects the phase
    /// when it lands near a beat.
    mutating func onset(at time: Double, strength: Float) {
        guard isLocked, strength >= 0.15 else { return }
        let toPrevious = beatTime.isFinite ? time - beatTime : .infinity
        let toNext = time - nextBeat
        let error = abs(toPrevious) <= abs(toNext) ? toPrevious : toNext
        guard abs(error) <= 0.15 * period else { return }
        nextBeat += 0.3 * error
        period = min(60 / TempoEstimator.minimumBPM, max(60 / TempoEstimator.maximumBPM, period + 0.03 * error))
        accent += (min(1, strength) - accent) * 0.2
        if abs(toPrevious) <= abs(toNext) {
            beatStrength = max(beatStrength, min(1, 0.4 + 0.6 * strength))
        }
    }

    /// A kick at `time`: a beat of its own while no tempo is locked.
    mutating func kick(at time: Double, strength: Float, emit: (BeatEvent) -> Void) {
        guard !isLocked, time - beatTime >= Self.refractory else { return }
        beat(at: time, strength: min(1, 0.5 + 0.5 * strength), predicted: false, emit: emit)
    }

    /// Emits the predicted beats due by `now` (plus the anticipation).
    mutating func advance(to now: Double, emit: (BeatEvent) -> Void) {
        guard isLocked, period > 0 else { return }
        // After a gap (silence, a stall) skip the beats that were missed
        // rather than firing them all at once.
        if nextBeat < now - period {
            nextBeat += ((now - nextBeat) / period).rounded(.down) * period
        }
        while now + Self.anticipation >= nextBeat {
            if nextBeat - beatTime >= 0.5 * period {
                beat(at: nextBeat, strength: min(1, max(0.4, accent)), predicted: true, emit: emit)
            }
            nextBeat += period
        }
    }

    private mutating func beat(at time: Double, strength: Float, predicted: Bool, emit: (BeatEvent) -> Void) {
        previousBeatTime = beatTime
        previousBeatStrength = beatStrength
        beatTime = time
        beatStrength = strength
        beatIndex += 1
        emit(BeatEvent(time: time, index: beatIndex, strength: strength, isPredicted: predicted))
    }

    private mutating func lock(period: Double, gridBeat: Double, now: Double) {
        isLocked = true
        self.period = period
        pendingCount = 0
        phaseMisses = 0
        lowConfidenceCount = 0
        let steps = ((now + Self.anticipation - gridBeat) / period).rounded(.up)
        nextBeat = gridBeat + max(0, steps) * period
    }

    /// `gridBeat` minus the nearest beat of the current grid, in
    /// `-period/2 ... period/2`.
    private func phaseError(of gridBeat: Double) -> Double {
        let steps = ((nextBeat - gridBeat) / period).rounded()
        return gridBeat - (nextBeat - steps * period)
    }
}
