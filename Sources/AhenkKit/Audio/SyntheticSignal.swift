import Foundation

/// Generated test signals for the analyzer: kick drums at a known tempo,
/// sines, noise. Used by the unit tests and the `--smoke` audio check; no
/// recorded audio is involved anywhere.
public enum SyntheticSignal {
    /// A kick drum: a pitch drop from 150 Hz to 50 Hz under a fast decay.
    public static func kick(sampleRate: Double, amplitude: Float = 0.8, length: Double = 0.35) -> [Float] {
        let count = Int(length * sampleRate)
        var output = [Float](repeating: 0, count: count)
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let frequency = 50 + 100 * exp(-time / 0.03)
            phase += 2 * Double.pi * frequency / sampleRate
            let envelope = exp(-time / 0.12) * min(1, time / 0.001)
            output[index] = amplitude * Float(envelope * sin(phase))
        }
        return output
    }

    /// Kicks on every beat at `bpm` for `seconds`; the first one at
    /// `offset`. Returns the samples and the true beat times.
    public static func kickTrain(
        bpm: Double, seconds: Double, sampleRate: Double, offset: Double = 0.25,
        amplitude: Float = 0.8, accentEvery: Int = 0
    ) -> (samples: [Float], beats: [Double]) {
        var output = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let kick = kick(sampleRate: sampleRate, amplitude: amplitude)
        let quiet = kick.map { $0 * 0.6 }
        var beats: [Double] = []
        var time = offset
        var index = 0
        while time < seconds {
            beats.append(time)
            let accented = accentEvery <= 0 || index % accentEvery == 0
            add(accented ? kick : quiet, to: &output, at: Int((time * sampleRate).rounded()))
            time += 60 / bpm
            index += 1
        }
        return (output, beats)
    }

    /// Kick on every beat, a snare-like noise burst on beats 2 and 4, and a
    /// hi-hat on every off-beat: a basic pop/house pattern at `bpm`.
    public static func drumPattern(bpm: Double, seconds: Double, sampleRate: Double, seed: UInt64 = 7) -> (samples: [Float], beats: [Double]) {
        var (output, beats) = kickTrain(bpm: bpm, seconds: seconds, sampleRate: sampleRate, amplitude: 0.7)
        let snare = burst(sampleRate: sampleRate, length: 0.18, decay: 0.05, amplitude: 0.35, highPass: 0.3, seed: seed)
        let hat = burst(sampleRate: sampleRate, length: 0.06, decay: 0.012, amplitude: 0.18, highPass: 0.9, seed: seed &+ 1)
        let beat = 60 / bpm
        for (index, time) in beats.enumerated() {
            if index % 2 == 1 { add(snare, to: &output, at: Int(time * sampleRate)) }
            add(hat, to: &output, at: Int((time + beat / 2) * sampleRate))
        }
        return (output, beats)
    }

    public static func sine(frequency: Double, seconds: Double, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    /// Uniform white noise in `-amplitude...amplitude`, reproducible per seed.
    public static func noise(seconds: Double, sampleRate: Double, amplitude: Float = 0.3, seed: UInt64 = 1) -> [Float] {
        var random = SplitMix64(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in
            amplitude * (Float(random.next() >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    public static func silence(seconds: Double, sampleRate: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Adds `sound` into `output` from `start` on (clipped at the end).
    public static func add(_ sound: [Float], to output: inout [Float], at start: Int) {
        guard start < output.count else { return }
        for index in 0..<min(sound.count, output.count - start) where start + index >= 0 {
            output[start + index] += sound[index]
        }
    }

    /// A noise burst with an exponential decay; `highPass` (0...1) mixes in
    /// a first difference to brighten it.
    static func burst(sampleRate: Double, length: Double, decay: Double, amplitude: Float, highPass: Float, seed: UInt64) -> [Float] {
        var random = SplitMix64(seed: seed)
        var previous: Float = 0
        return (0..<Int(length * sampleRate)).map { index in
            let white = Float(random.next() >> 40) / Float(1 << 24) * 2 - 1
            let bright = white - previous
            previous = white
            let envelope = Float(exp(-Double(index) / sampleRate / decay))
            return amplitude * envelope * ((1 - highPass) * white + highPass * 0.5 * bright)
        }
    }
}
