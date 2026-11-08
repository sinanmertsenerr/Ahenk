import Foundation

/// The demo's beat as sound: a 120 BPM four-on-the-floor kick (accented on
/// each bar), a snare on 2 and 4, off-beat hi-hats, a bass line that ducks
/// under the kick and a chord pad that swells over 32 seconds, at about
/// −15 dBFS.
///
/// `--demo` plays it through the real analyzer instead of a process tap,
/// so the light, the Settings monitor and the tests see what music looks
/// like. Every sample is a pure function of its position in the song, so a
/// render is exactly reproducible and can start anywhere. Nothing here is
/// recorded audio.
public final class DemoAudioSynth: Sendable {
    public let sampleRate: Double
    public let bpm: Double
    private let kick: [Float]
    private let snare: [Float]
    private let hat: [Float]

    /// Root note (Hz) and pad chord of each bar, a four-bar loop.
    private static let progression: [(root: Double, chord: [Double])] = [
        (55.00, [220.00, 261.63, 329.63]),
        (43.65, [174.61, 220.00, 261.63]),
        (65.41, [261.63, 329.63, 392.00]),
        (49.00, [196.00, 246.94, 293.66]),
    ]

    public init(sampleRate: Double, bpm: Double = DemoBeat.bpm) {
        self.sampleRate = sampleRate
        self.bpm = bpm
        kick = SyntheticSignal.kick(sampleRate: sampleRate, amplitude: 0.62, length: 0.4)
        let tone = (0..<Int(0.12 * sampleRate)).map { index in
            Float(0.12 * sin(2 * Double.pi * 185 * Double(index) / sampleRate) * exp(-Double(index) / sampleRate / 0.04))
        }
        var snare = SyntheticSignal.burst(sampleRate: sampleRate, length: 0.2, decay: 0.05, amplitude: 0.3, highPass: 0.35, seed: 11)
        SyntheticSignal.add(tone, to: &snare, at: 0)
        self.snare = snare
        hat = SyntheticSignal.burst(sampleRate: sampleRate, length: 0.07, decay: 0.014, amplitude: 0.13, highPass: 0.9, seed: 12)
    }

    /// Writes `count` samples of the song from `position` seconds on.
    public func render(into output: UnsafeMutablePointer<Float>, count: Int, from position: Double) {
        let beatLength = 60 / bpm
        let start = Int64((max(0, position) * sampleRate).rounded())
        for offset in 0..<count {
            let time = Double(start + Int64(offset)) / sampleRate
            let beats = time / beatLength
            let beat = Int(beats.rounded(.down))
            let sinceBeat = time - Double(beat) * beatLength
            let bar = (beat / 4) % Self.progression.count
            let step = Self.progression[bar]

            var sample: Float = 0
            let kickIndex = Int(sinceBeat * sampleRate)
            if kickIndex < kick.count {
                sample += kick[kickIndex] * (beat % 4 == 0 ? 1 : 0.82)
            }
            if beat % 2 == 1, kickIndex < snare.count {
                sample += snare[kickIndex]
            }
            let sinceOffBeat = sinceBeat - beatLength / 2
            if sinceOffBeat >= 0 {
                let hatIndex = Int(sinceOffBeat * sampleRate)
                if hatIndex < hat.count { sample += hat[hatIndex] }
            }
            // Bass ducks under each kick and comes back within ~150 ms.
            let duck = 1 - 0.8 * exp(-sinceBeat / 0.07)
            sample += Float(0.2 * duck * sin(2 * Double.pi * step.root * time))
            // Pad, swelling over 32 s.
            let swell = 0.75 + 0.25 * sin(2 * Double.pi * time / 32)
            var pad = 0.0
            for frequency in step.chord {
                pad += sin(2 * Double.pi * frequency * time)
            }
            sample += Float(0.035 * swell * pad)
            output[offset] = sample
        }
    }

    /// `seconds` of the song from `position` (tests, the smoke check).
    public func render(seconds: Double, from position: Double = 0) -> [Float] {
        var output = [Float](repeating: 0, count: Int(seconds * sampleRate))
        output.withUnsafeMutableBufferPointer { buffer in
            render(into: buffer.baseAddress!, count: buffer.count, from: position)
        }
        return output
    }
}
