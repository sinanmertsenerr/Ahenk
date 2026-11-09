import Accelerate
import Foundation
import os

/// One window of the analysed audio for automatic lyrics sync: mono samples
/// from the analysis pump, averaged down to about 16 kHz, with the host
/// time (``AudioClock``) of the first one. Lives in memory until analysed;
/// nothing is written anywhere.
///
/// `append` is called on the analysis queue; the rest is read once the
/// window is complete (`onComplete`, called on that queue).
public final class LyricsSyncCapture: @unchecked Sendable {
    public static let analysisRate = 16_000.0

    public let seconds: Double
    public private(set) var sampleRate: Double = 0
    /// Host time of the first kept sample.
    public private(set) var startHostTime: Double?
    public private(set) var samples: [Float] = []
    private var factor = 1
    private var pending: [Float] = []
    private var isComplete = false
    private let onComplete: @Sendable (LyricsSyncCapture) -> Void

    public init(seconds: Double, onComplete: @escaping @Sendable (LyricsSyncCapture) -> Void) {
        self.seconds = seconds
        self.onComplete = onComplete
    }

    /// Seconds collected so far.
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    /// The window is full (the pump lets go of it).
    public var isFinished: Bool { isComplete }

    /// Adds `count` samples at `rate` whose first one played at `hostTime`.
    public func append(_ chunk: UnsafePointer<Float>, count: Int, rate: Double, hostTime: Double) {
        guard !isComplete, count > 0, rate > 0 else { return }
        if startHostTime == nil {
            let ratio = (rate / Self.analysisRate).rounded()
            factor = ratio > 1 && rate.truncatingRemainder(dividingBy: ratio) == 0 ? Int(ratio) : 1
            sampleRate = rate / Double(factor)
            startHostTime = hostTime
            samples.reserveCapacity(Int(seconds * sampleRate) + 1024)
        }
        if factor == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: chunk, count: count))
        } else {
            pending.append(contentsOf: UnsafeBufferPointer(start: chunk, count: count))
            let blocks = pending.count / factor
            if blocks > 0 {
                var output = [Float](repeating: 0, count: blocks)
                let weights = [Float](repeating: 1 / Float(factor), count: factor)
                pending.withUnsafeBufferPointer { input in
                    vDSP_desamp(input.baseAddress!, factor, weights, &output, vDSP_Length(blocks), vDSP_Length(factor))
                }
                samples.append(contentsOf: output)
                pending.removeFirst(blocks * factor)
            }
        }
        if duration >= seconds {
            isComplete = true
            onComplete(self)
        }
    }
}

/// Where and how long to listen, and which lines fall in the window.
public enum LyricsSyncPlan {
    /// The estimator needs this many lines in a window.
    public static let minimumLines = LyricOffsetEstimator.minimumLines + 1
    public static let minimumSeconds = 12.0
    public static let maximumSeconds = 32.0
    /// Lines this close to a window's edges are left out: the lag search
    /// reaches this far in both directions.
    public static let margin = LyricOffsetEstimator.maximumLagSeconds + 0.5

    /// Seconds to listen from `position` so that enough line starts fall
    /// inside with room for the lag search; nil when the rest of the song
    /// has too few lines (or the window would run past its end).
    public static func window(starts: [Double], from position: Double, songEnd: Double?) -> Double? {
        let ahead = starts.filter { $0 >= position + margin }.sorted()
        guard ahead.count >= minimumLines else { return nil }
        let needed = ahead[minimumLines - 1] + margin - position
        guard needed <= maximumSeconds else { return nil }
        let duration = max(minimumSeconds, needed)
        if let songEnd, songEnd > 0, position + duration > songEnd - 0.5 { return nil }
        return duration
    }

    /// The line starts inside a window, relative to its start, without
    /// the ones too close to its edges.
    public static func offsets(starts: [Double], windowStart: Double, duration: Double) -> [Double] {
        starts.map { $0 - windowStart }.filter { $0 >= margin && $0 <= duration - margin }.sorted()
    }
}

/// One song's automatic sync: windows measured so far and the decision.
/// No single window changes the timing; two independent windows must
/// agree (`LyricOffsetEstimator.consensusSelection`). At most
/// `maximumWindows` windows per song and run.
public struct LyricsSyncSession: Sendable {
    public static let maximumWindows = 4

    public let key: String
    public let fingerprint: String
    public private(set) var windows: [LyricOffsetEstimator.Diagnostics] = []
    public private(set) var attempts = 0
    /// The measured offset once two windows agreed (positive shows the
    /// lines earlier).
    public private(set) var offset: Double?

    public init(key: String, fingerprint: String) {
        self.key = key
        self.fingerprint = fingerprint
    }

    public var isFinished: Bool { offset != nil || attempts >= Self.maximumWindows }

    /// A window starts. It counts against the budget even if it cannot be
    /// measured in the end (a seek, a pause, the song changed).
    public mutating func beginWindow() {
        attempts += 1
    }

    /// Adds a measured window; returns the offset when it settles the song.
    @discardableResult
    public mutating func add(_ window: LyricOffsetEstimator.Diagnostics) -> Double? {
        defer { windows.append(window) }
        guard offset == nil, let estimate = LyricOffsetEstimator.consensus(priors: windows, current: window) else { return nil }
        // Lyrics that run early (positive lead) are shown later.
        offset = -estimate.leadSeconds
        return offset
    }

    /// Analyses a finished window: the novelty of its audio against the
    /// lines' raw starts (`starts`) from `position`, the song's position at
    /// the window's first sample. `beatPeriod` is the beat the audio
    /// analysis tracked (60 / BPM), when locked: a lead on a whole number
    /// of beats is the beat grid, not the singing.
    public static func measure(_ samples: [Float], sampleRate: Double, starts: [Double], position: Double, beatPeriod: Double?) -> LyricOffsetEstimator.Diagnostics {
        let novelty = OnsetNovelty.compute(samples: samples, sampleRate: sampleRate)
        let duration = Double(samples.count) / max(1, sampleRate)
        let offsets = LyricsSyncPlan.offsets(starts: starts, windowStart: position, duration: duration)
        var diagnostics = LyricOffsetEstimator.diagnose(novelty: novelty, lineOffsets: offsets)
        diagnostics.trackedBeatSeconds = beatPeriod.flatMap { $0.isFinite && $0 > 0.25 && $0 < 1.5 ? $0 : nil }
        return diagnostics
    }

    /// The beat period of a tempo, when the tracker is locked.
    public static func beatPeriod(bpm: Float, confidence: Float) -> Double? {
        guard bpm >= 60, bpm <= 200, confidence >= 0.35 else { return nil }
        return 60 / Double(bpm)
    }
}
