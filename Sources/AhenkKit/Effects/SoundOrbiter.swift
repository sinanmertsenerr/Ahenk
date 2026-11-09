import Foundation

/// Moves a stereo sound slowly from one ear to the other and back ("8D
/// Audio"): the two channels are folded towards the middle and that middle
/// is panned along a sine, with equal power so the loudness stays even.
///
/// A plain value with its own phase; `process` works in place on the
/// buffers it is given and is real-time safe (no allocation, no locks).
public struct SoundOrbiter: Sendable {
    public var orbit: SoundOrbit
    public private(set) var phase = 0.0

    public init(orbit: SoundOrbit) {
        self.orbit = orbit
    }

    /// The position at `phase` (a share of one trip): −1 left, +1 right.
    public static func position(phase: Double, depth: Double) -> Double {
        sin(phase * 2 * .pi) * depth
    }

    /// Equal-power gains of the two ears for a position in −1...1.
    public static func gains(position: Double) -> (left: Float, right: Float) {
        let angle = (min(1, max(-1, position)) + 1) * .pi / 4
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Pans `frames` frames in place. The gains move in steps of 64 frames
    /// (about a millisecond), far finer than the ear follows.
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        guard frames > 0, sampleRate > 0, orbit.depth > 0 else { return }
        let step = 1 / (orbit.period * sampleRate)
        // How much of each channel's own side survives at the edges.
        let width = Float(1 - orbit.depth)
        let root2 = Float(2).squareRoot()
        var done = 0
        while done < frames {
            let count = min(64, frames - done)
            let gains = Self.gains(position: Self.position(phase: phase, depth: orbit.depth))
            for index in done..<(done + count) {
                let l = left[index]
                let r = right[index]
                let middle = (l + r) * 0.5
                let side = (l - r) * 0.5 * width
                left[index] = (middle + side) * gains.left * root2
                right[index] = (middle - side) * gains.right * root2
            }
            done += count
            phase += step * Double(count)
            if phase >= 1 { phase -= phase.rounded(.down) }
        }
    }
}
