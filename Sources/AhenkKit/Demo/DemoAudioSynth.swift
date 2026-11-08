import Foundation

/// The demo's beat as sound: a 120 BPM four-on-the-floor kick (accented on
/// each bar), a snare on 2 and 4, off-beat hi-hats and plucks, a shaker on
/// every sixteenth, a bass line that ducks under the kick and a chord pad
/// that swells over 32 seconds, at about −14 dBFS.
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
    private let shaker: [Float]
    /// One cycle of a sine and of a bright tone (four harmonics), read with
    /// linear interpolation: far cheaper than calling `sin` per voice.
    private let sine: [Float]
    private let bright: [Float]
    private static let tableSize = 2_048

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
        var snare = SyntheticSignal.burst(sampleRate: sampleRate, length: 0.22, decay: 0.06, amplitude: 0.32, highPass: 0.45, seed: 11)
        SyntheticSignal.add(tone, to: &snare, at: 0)
        self.snare = snare
        hat = SyntheticSignal.burst(sampleRate: sampleRate, length: 0.1, decay: 0.022, amplitude: 0.2, highPass: 0.9, seed: 12)
        shaker = SyntheticSignal.burst(sampleRate: sampleRate, length: 0.04, decay: 0.008, amplitude: 0.07, highPass: 0.95, seed: 13)
        let size = Self.tableSize
        sine = (0...size).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        bright = (0...size).map { index in
            let x = 2 * Double.pi * Double(index) / Double(size)
            return Float((sin(x) + sin(2 * x) / 2 + sin(3 * x) / 3 + sin(4 * x) / 4) / 1.5)
        }
    }

    /// Writes `count` samples of the song from `position` seconds on.
    public func render(into output: UnsafeMutablePointer<Float>, count: Int, from position: Double) {
        let beatLength = 60 / bpm
        let sixteenth = beatLength / 4
        let start = Int64((max(0, position) * sampleRate).rounded())
        for offset in 0..<count {
            let time = Double(start + Int64(offset)) / sampleRate
            let beat = Int((time / beatLength).rounded(.down))
            let sinceBeat = time - Double(beat) * beatLength
            let bar = (beat / 4) % Self.progression.count
            let step = Self.progression[bar]

            var sample: Float = 0
            let index = Int(sinceBeat * sampleRate)
            if index < kick.count {
                sample += kick[index] * (beat % 4 == 0 ? 1 : 0.82)
            }
            if beat % 2 == 1, index < snare.count {
                sample += snare[index]
            }
            let sinceOffBeat = sinceBeat - beatLength / 2
            if sinceOffBeat >= 0 {
                let hatIndex = Int(sinceOffBeat * sampleRate)
                if hatIndex < hat.count { sample += hat[hatIndex] }
                // A pluck an octave above the chord's root on every off-beat.
                let pluck = Float(exp(-sinceOffBeat / 0.11))
                sample += 0.09 * pluck * lookup(bright, step.chord[0] * 2 * time)
            }
            let shakerIndex = Int((time - (time / sixteenth).rounded(.down) * sixteenth) * sampleRate)
            if shakerIndex < shaker.count { sample += shaker[shakerIndex] }
            // Bass ducks under each kick and comes back within ~150 ms.
            let duck = Float(1 - 0.8 * exp(-sinceBeat / 0.07))
            sample += 0.2 * duck * lookup(sine, step.root * time)
            // Pad, swelling over 32 s.
            let swell = Float(0.75 + 0.25 * sin(2 * Double.pi * time / 32))
            var pad: Float = 0
            for frequency in step.chord {
                pad += lookup(bright, frequency * time)
            }
            sample += 0.032 * swell * pad
            output[offset] = sample
        }
    }

    /// The table's value at `cycles` (only the fraction matters).
    @inline(__always)
    private func lookup(_ table: [Float], _ cycles: Double) -> Float {
        let phase = (cycles - cycles.rounded(.down)) * Double(Self.tableSize)
        let index = Int(phase)
        let fraction = Float(phase - Double(index))
        return table[index] + (table[index + 1] - table[index]) * fraction
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
