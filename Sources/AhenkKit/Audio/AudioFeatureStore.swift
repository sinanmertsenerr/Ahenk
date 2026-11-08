import Foundation
import os

/// What the analysis publishes about a hundred times a second. Readers
/// derive the time-dependent parts (beat pulse and phase) at the moment
/// they read, so the light stays smooth at 60 or 120 Hz.
public struct AudioFeatureFrame: Sendable, Equatable, BitwiseCopyable {
    /// The levels as of `time`. Its `beat` and `beatPhase` are recomputed
    /// by the reader.
    public var features: AudioFeatures
    /// When the sound of this frame is heard (``AudioClock`` seconds).
    public var time: Double
    /// The newest beat (``AudioClock`` seconds). Predicted beats are
    /// announced a few milliseconds early, so this may lie in the future;
    /// readers then still show `previousBeatTime`. `-infinity` if none.
    public var beatTime: Double
    public var previousBeatTime: Double
    public var beatStrength: Float
    public var previousBeatStrength: Float
    /// Length of a beat in seconds; 0 while the tempo is unknown.
    public var beatPeriod: Double
    /// Time constant of the beat pulse's exponential decay, in seconds.
    public var pulseDecay: Float

    public init(
        features: AudioFeatures, time: Double,
        beatTime: Double = -.infinity, previousBeatTime: Double = -.infinity,
        beatStrength: Float = 0, previousBeatStrength: Float = 0,
        beatPeriod: Double = 0, pulseDecay: Float = 0.12
    ) {
        self.features = features
        self.time = time
        self.beatTime = beatTime
        self.previousBeatTime = previousBeatTime
        self.beatStrength = beatStrength
        self.previousBeatStrength = previousBeatStrength
        self.beatPeriod = beatPeriod
        self.pulseDecay = pulseDecay
    }

    public static let silence = AudioFeatureFrame(features: .silence, time: -.infinity)

    /// The features as seen at `time` (``AudioClock`` seconds).
    public func features(at now: Double) -> AudioFeatures {
        var result = features
        var beatAt = beatTime
        var strength = beatStrength
        if now < beatAt {
            // An announced beat that has not come yet.
            beatAt = previousBeatTime
            strength = previousBeatStrength
            result.beatIndex -= 1
        }
        if beatAt.isFinite, now >= beatAt {
            let since = now - beatAt
            result.beat = strength * Float(exp(-since / Double(max(0.01, pulseDecay))))
            result.beatPhase = beatPeriod > 0 ? Float(min(0.9999, since / beatPeriod)) : 0
        } else {
            result.beat = 0
            result.beatPhase = 0
        }
        // A producer that stopped publishing (the tap went away) must not
        // leave the light frozen: fade to silence.
        let age = now - time
        if age > AudioFeatureStore.staleAfter {
            let fade = 1 - (age - AudioFeatureStore.staleAfter) / AudioFeatureStore.staleFade
            guard fade > 0 else {
                var silent = AudioFeatures.silence
                silent.beatIndex = result.beatIndex
                return silent
            }
            result = result.scaled(by: Float(fade))
        }
        return result
    }
}

/// Where the analysis publishes and every consumer reads: the edge light's
/// render thread, the Settings monitor, the Dock ring.
///
/// Reading (``currentFeatures()``, ``features(at:)``) is lock-free and
/// allocation-free from any thread: a seqlock copy of a 300-byte frame plus
/// a few multiplications. Publishing is for one producer at a time (the
/// analysis queue).
public final class AudioFeatureStore: AudioFeatureSource, @unchecked Sendable {
    /// A frame older than this starts fading out…
    public static let staleAfter: Double = 0.3
    /// …and is silent this much later.
    public static let staleFade: Double = 0.3

    private let box = SeqlockBox(AudioFeatureFrame.silence)
    private let observers = OSAllocatedUnfairLock(initialState: [UUID: @Sendable (Bool) -> Void]())
    /// Producer-confined.
    private var wasActive = false

    public init() {}

    // MARK: Reading

    public func currentFeatures() -> AudioFeatures {
        box.read().features(at: AudioClock.now())
    }

    /// The features as they should look at `time` (``AudioClock`` seconds),
    /// e.g. a display link's target timestamp.
    public func features(at time: Double) -> AudioFeatures {
        box.read().features(at: time)
    }

    /// The raw frame (diagnostics, tests).
    public func latestFrame() -> AudioFeatureFrame {
        box.read()
    }

    // MARK: Publishing

    /// Publishes `frame`. Call from one producer at a time.
    public func publish(_ frame: AudioFeatureFrame) {
        box.write(frame)
        let active = !frame.features.isSilent
        if active != wasActive {
            wasActive = active
            let handlers = observers.withLock { Array($0.values) }
            for handler in handlers { handler(active) }
        }
    }

    /// Publishes silence (keeping the beat counter).
    public func publishSilence(at time: Double = AudioClock.now()) {
        var frame = AudioFeatureFrame.silence
        frame.features.beatIndex = box.read().features.beatIndex
        frame.time = time
        publish(frame)
    }

    // MARK: Activity

    /// Calls `handler` (on the producer's thread) whenever the features
    /// switch between silent and active, so idle UI can stop its display
    /// link and start it again when music comes. Keep the returned token.
    public func observeActivity(_ handler: @escaping @Sendable (Bool) -> Void) -> AudioActivityObservation {
        let key = UUID()
        observers.withLock { $0[key] = handler }
        return AudioActivityObservation { [weak self] in
            self?.observers.withLock { _ = $0.removeValue(forKey: key) }
        }
    }

    /// True while the newest frame is not silent.
    public var isActive: Bool { !box.read().features.isSilent }
}

/// Ends an activity observation when cancelled or released.
public final class AudioActivityObservation: Sendable {
    private let cancellation: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    init(_ cancel: @escaping @Sendable () -> Void) {
        cancellation = OSAllocatedUnfairLock(initialState: cancel)
    }

    public func cancel() {
        let cancel = cancellation.withLock { state -> (@Sendable () -> Void)? in
            defer { state = nil }
            return state
        }
        cancel?()
    }

    deinit {
        cancel()
    }
}
