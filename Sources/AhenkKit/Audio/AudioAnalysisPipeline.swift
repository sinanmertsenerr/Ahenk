import Accelerate
import Foundation

/// Moves audio from the ring buffer through the analyzer into the store.
///
/// The producer (a process tap's I/O thread, or the demo synthesizer)
/// writes mono samples into ``ring``; the analysis queue calls
/// ``pump(now:)`` about a hundred times a second, which drains the ring,
/// analyses what arrived and publishes one frame on the host clock.
///
/// - **Music gate**: while closed (paused, a video, an advert) the samples
///   are drained and dropped and the store holds silence.
/// - **Sensitivity**: a gain on every level, clamped to 1.
/// - **Presentation delay**: frames wait until the sound they describe
///   reaches the speakers (Bluetooth headphones lag by 100–250 ms), so the
///   light does not run ahead of the music.
///
/// Confined to one queue; allocation-free after `configure`.
public final class AudioAnalysisPipeline: @unchecked Sendable {
    public let ring: AudioRingBuffer
    public let store: AudioFeatureStore
    public private(set) var analyzer: AudioAnalyzer?
    /// Gain on every level (Settings › Sound › Sensitivity).
    public var sensitivity: Float = 1
    /// Seconds between the samples reaching Ahenk and the sound reaching
    /// the listener (the output device's latency). Clamped to 0...0.5.
    public var presentationDelay: Double = 0 {
        didSet { presentationDelay = min(0.5, max(0, presentationDelay)) }
    }
    public private(set) var isGateOpen = false
    /// Seconds of consecutive digital silence (peak below −100 dBFS) in the
    /// samples drained, whether or not the gate is open. A tap on the
    /// wrong process delivers exactly this.
    public private(set) var digitalSilence: Double = 0
    /// Seconds of audio analysed since `configure`.
    public private(set) var analysedSeconds: Double = 0

    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 4096
    private let pendingCapacity = 64
    private let pending: UnsafeMutablePointer<AudioFeatureFrame>
    private var pendingStart = 0
    private var pendingCount = 0
    /// Host time minus analyzer time, smoothed.
    private var clockOffset: Double?
    private var gateClosedAt: Double?

    public init(store: AudioFeatureStore, ringCapacity: Int = 1 << 17) {
        self.store = store
        ring = AudioRingBuffer(capacity: ringCapacity)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        pending = .allocate(capacity: pendingCapacity)
        pending.initialize(repeating: .silence, count: pendingCapacity)
    }

    deinit {
        scratch.deallocate()
        pending.deallocate()
    }

    /// Prepares the analyzer for `sampleRate`; keeps the current one (and
    /// its tempo) if the rate did not change.
    public func configure(sampleRate: Double) {
        if analyzer?.sampleRate != sampleRate {
            analyzer = AudioAnalyzer(sampleRate: sampleRate)
            clockOffset = nil
        }
        ring.reader.skipAll()
        digitalSilence = 0
    }

    /// Opens or closes the music gate. Reopening after more than a second
    /// starts the analysis fresh (the song moved on meanwhile).
    public func setGate(open: Bool, at now: Double) {
        guard open != isGateOpen else { return }
        isGateOpen = open
        if open {
            if let closed = gateClosedAt, now - closed > 1 {
                analyzer?.reset()
                clockOffset = nil
            }
            gateClosedAt = nil
            ring.reader.skipAll()
        } else {
            gateClosedAt = now
            clearPending()
            store.publishSilence(at: now)
        }
    }

    /// A new song: forget the tempo, keep the levels.
    public func resetTempo() {
        analyzer?.resetTempo()
    }

    /// Stops feeding the store (the tap went away): silence, a clean slate.
    public func stop(at now: Double) {
        ring.reader.skipAll()
        analyzer?.reset()
        clockOffset = nil
        clearPending()
        digitalSilence = 0
        store.publishSilence(at: now)
    }

    /// Drains and analyses what arrived; publishes the frame due at `now`
    /// (``AudioClock`` seconds).
    public func pump(now: Double) {
        guard let analyzer else {
            ring.reader.skipAll()
            return
        }
        var drained = 0
        var peak: Float = 0
        while true {
            let count = ring.reader.read(into: scratch, maxCount: scratchCapacity)
            guard count > 0 else { break }
            var chunkPeak: Float = 0
            vDSP_maxmgv(scratch, 1, &chunkPeak, vDSP_Length(count))
            peak = max(peak, chunkPeak)
            drained += count
            if isGateOpen {
                analyzer.process(scratch, count: count)
            }
        }
        if drained > 0 {
            let seconds = Double(drained) / analyzer.sampleRate
            digitalSilence = peak < 1e-5 ? digitalSilence + seconds : 0
            if isGateOpen { analysedSeconds += seconds }
        }
        guard isGateOpen else { return }

        if drained > 0 {
            // The newest sample arrived just now; smooth out the pump's
            // jitter, follow real jumps (a stall, a restart) at once.
            let measured = now - analyzer.time
            if let offset = clockOffset, abs(measured - offset) < 0.1 {
                clockOffset = offset + (measured - offset) * 0.05
            } else {
                clockOffset = measured
            }
            enqueue(hostFrame(analyzer.frame, offset: (clockOffset ?? measured) + presentationDelay))
        }
        // The newest frame whose sound is being heard now.
        var due: AudioFeatureFrame?
        while pendingCount > 0, pending[pendingStart].time <= now + 0.0005 {
            due = pending[pendingStart]
            pendingStart = (pendingStart + 1) % pendingCapacity
            pendingCount -= 1
        }
        if let due { store.publish(due) }
    }

    private func hostFrame(_ frame: AudioFeatureFrame, offset: Double) -> AudioFeatureFrame {
        var result = frame
        result.time += offset
        result.beatTime += offset
        result.previousBeatTime += offset
        if sensitivity != 1 {
            let gain = max(0, sensitivity)
            let one = SIMD32<Float>(repeating: 1)
            var features = frame.features
            features.energy = min(1, features.energy * gain)
            features.bands = AudioBands(
                subBass: min(1, features.bands.subBass * gain), bass: min(1, features.bands.bass * gain),
                lowMid: min(1, features.bands.lowMid * gain), mid: min(1, features.bands.mid * gain),
                high: min(1, features.bands.high * gain)
            )
            features.spectrum = pointwiseMin(features.spectrum * gain, one)
            features.onset = min(1, features.onset * gain)
            result.features = features
            result.beatStrength = min(1, frame.beatStrength * gain)
            result.previousBeatStrength = min(1, frame.previousBeatStrength * gain)
        }
        return result
    }

    private func enqueue(_ frame: AudioFeatureFrame) {
        if pendingCount == pendingCapacity {
            // Full (a delay beyond 0.6 s of frames): drop the oldest.
            pendingStart = (pendingStart + 1) % pendingCapacity
            pendingCount -= 1
        }
        pending[(pendingStart + pendingCount) % pendingCapacity] = frame
        pendingCount += 1
    }

    private func clearPending() {
        pendingStart = 0
        pendingCount = 0
    }
}
