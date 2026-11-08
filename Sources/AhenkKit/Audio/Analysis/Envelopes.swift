import Foundation

/// One-pole attack/release smoothing at a fixed frame rate: rises with the
/// attack time constant, falls with the release one.
struct EnvelopeFollower: Sendable {
    let attack: Float
    let release: Float
    private(set) var value: Float = 0

    /// Time constants in seconds; `frameInterval` is the time between updates.
    init(attack: Double, release: Double, frameInterval: Double) {
        self.attack = Self.coefficient(attack, frameInterval)
        self.release = Self.coefficient(release, frameInterval)
    }

    static func coefficient(_ timeConstant: Double, _ frameInterval: Double) -> Float {
        timeConstant <= 0 ? 1 : Float(1 - exp(-frameInterval / timeConstant))
    }

    @discardableResult
    mutating func update(_ input: Float) -> Float {
        value += (input - value) * (input > value ? attack : release)
        return value
    }

    mutating func reset() { value = 0 }
}

/// The same smoothing for every lane of a SIMD vector.
struct VectorEnvelope<Vector: SIMD & Sendable>: Sendable where Vector.Scalar == Float {
    let attack: Float
    let release: Float
    private(set) var value: Vector = .zero

    init(attack: Double, release: Double, frameInterval: Double) {
        self.attack = EnvelopeFollower.coefficient(attack, frameInterval)
        self.release = EnvelopeFollower.coefficient(release, frameInterval)
    }

    @discardableResult
    mutating func update(_ input: Vector) -> Vector {
        let rising = input .> value
        var rate = Vector(repeating: release)
        rate.replace(with: Vector(repeating: attack), where: rising)
        value += (input - value) * rate
        return value
    }

    mutating func reset() { value = .zero }
}

/// A slowly falling peak level in dB: jumps up to anything louder, then
/// sinks by `fallPerSecond` toward quieter material, never below `floor`.
/// Levels are drawn relative to it, so loud and quiet songs both fill the
/// range while a quiet bridge after a loud chorus still looks quieter for a
/// while.
struct PeakReference: Sendable {
    let fallPerFrame: Float
    let floor: Float
    private(set) var value: Float

    init(fallPerSecond: Double, floor: Float, frameInterval: Double) {
        fallPerFrame = Float(fallPerSecond * frameInterval)
        self.floor = floor
        value = floor
    }

    @discardableResult
    mutating func update(_ level: Float) -> Float {
        value = max(level, max(floor, value - fallPerFrame))
        return value
    }

    mutating func reset() { value = floor }
}

/// Exponential moving mean and mean absolute deviation, for adaptive
/// thresholds.
struct RunningStatistics: Sendable {
    let rate: Float
    let initialMean: Float
    private(set) var mean: Float
    private(set) var deviation: Float = 0

    init(timeConstant: Double, frameInterval: Double, initialMean: Float = 0) {
        rate = EnvelopeFollower.coefficient(timeConstant, frameInterval)
        self.initialMean = initialMean
        mean = initialMean
    }

    mutating func update(_ value: Float) {
        mean += (value - mean) * rate
        deviation += (abs(value - mean) - deviation) * rate
    }

    mutating func reset() {
        mean = initialMean
        deviation = 0
    }
}

/// Decides when the input counts as silence: below `closeBelow` dBFS for
/// `holdSeconds`, and open again as soon as it rises above `openAbove`.
struct SilenceGate: Sendable {
    let closeBelow: Float
    let openAbove: Float
    let holdFrames: Int
    private(set) var isSilent = true
    private(set) var quietFrames = 0
    /// Frames since the gate closed (0 while open).
    private(set) var silentFrames = 0

    init(closeBelow: Float, openAbove: Float, holdSeconds: Double, frameInterval: Double) {
        self.closeBelow = closeBelow
        self.openAbove = openAbove
        holdFrames = max(1, Int((holdSeconds / frameInterval).rounded()))
    }

    mutating func update(levelDB: Float) {
        if isSilent {
            if levelDB > openAbove {
                isSilent = false
                quietFrames = 0
                silentFrames = 0
            } else {
                silentFrames += 1
            }
            return
        }
        if levelDB < closeBelow {
            quietFrames += 1
            if quietFrames >= holdFrames {
                isSilent = true
                silentFrames = 0
            }
        } else {
            quietFrames = 0
        }
    }

    mutating func reset() {
        isSilent = true
        quietFrames = 0
        silentFrames = 0
    }
}

/// `level` on a window of `range` dB that ends at `reference`, as `0...1`.
@inline(__always)
func normalizedLevel(_ level: Float, reference: Float, range: Float) -> Float {
    min(1, max(0, (level - (reference - range)) / range))
}

/// Power to dB, with a floor for silence.
@inline(__always)
func decibels(power: Float) -> Float {
    10 * log10(max(power, 1e-14))
}
