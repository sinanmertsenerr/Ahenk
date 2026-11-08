import Foundation
import Testing
@testable import AhenkKit

/// Runs samples through an analyzer in 512-sample chunks (a Core Audio
/// buffer) and records what it reports.
final class AnalysisRun {
    let analyzer: AudioAnalyzer
    private(set) var beats: [BeatEvent] = []
    private(set) var onsets: [Double] = []
    /// `(time, frame)` after every chunk.
    private(set) var frames: [(time: Double, frame: AudioFeatureFrame)] = []

    init(sampleRate: Double) {
        analyzer = AudioAnalyzer(sampleRate: sampleRate)
        analyzer.onBeat = { [unowned self] in beats.append($0) }
        analyzer.onOnset = { [unowned self] time, _ in onsets.append(time) }
    }

    @discardableResult
    func feed(_ samples: [Float], chunk: Int = 512) -> AnalysisRun {
        samples.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(chunk, buffer.count - offset)
                analyzer.process(buffer.baseAddress! + offset, count: count)
                offset += count
                frames.append((analyzer.time, analyzer.frame))
            }
        }
        return self
    }

    var features: AudioFeatures { analyzer.frame.features }

    /// Beats at or after `time`.
    func beats(after time: Double) -> [BeatEvent] { beats.filter { $0.time >= time } }

    /// The first analyser time at or after `start` whose frame satisfies `condition`.
    func firstTime(after start: Double, where condition: (AudioFeatureFrame) -> Bool) -> Double? {
        frames.first { $0.time >= start && condition($0.frame) }?.time
    }
}

@Suite("Audio analyzer")
struct AudioAnalyzerTests {
    static let rate = 48_000.0

    /// Every beat in `beats` is within `tolerance` of one of `truth`.
    private func largestError(_ beats: [BeatEvent], _ truth: [Double]) -> Double {
        beats.map { beat in truth.map { abs($0 - beat.time) }.min() ?? .infinity }.max() ?? 0
    }

    @Test("Kick trains: tempo within ±2 BPM and every beat within ±50 ms", arguments: [70.0, 90, 120, 128, 140, 174])
    func kickTrainTempoAndTiming(bpm: Double) {
        let (samples, truth) = SyntheticSignal.kickTrain(bpm: bpm, seconds: 14, sampleRate: Self.rate)
        let run = AnalysisRun(sampleRate: Self.rate).feed(samples)
        #expect(abs(Double(run.features.bpm) - bpm) <= 2, "read \(run.features.bpm) BPM")
        #expect(run.features.tempoConfidence >= 0.8)
        // After the lock-in, beats come from the tempo grid, on time.
        let settled = run.beats(after: 6)
        let expected = truth.filter { $0 >= 6 && $0 <= 14 - 0.05 }.count
        #expect(abs(settled.count - expected) <= 1, "\(settled.count) beats for \(expected) kicks")
        #expect(settled.allSatisfy { $0.isPredicted })
        #expect(largestError(settled, truth) <= 0.05, "largest error \(largestError(settled, truth) * 1000) ms")
        // Indices count up by one.
        #expect(zip(settled, settled.dropFirst()).allSatisfy { $1.index == $0.index + 1 })
    }

    @Test("A kick + snare + hi-hat pattern reads as its quarter notes", arguments: [95.0, 120, 150])
    func drumPattern(bpm: Double) {
        let (samples, truth) = SyntheticSignal.drumPattern(bpm: bpm, seconds: 14, sampleRate: Self.rate)
        let run = AnalysisRun(sampleRate: Self.rate).feed(samples)
        #expect(abs(Double(run.features.bpm) - bpm) <= 2, "read \(run.features.bpm) BPM, not half or double")
        #expect(largestError(run.beats(after: 6), truth) <= 0.05)
    }

    @Test("The tempo is the same at 44.1 kHz and 96 kHz", arguments: [44_100.0, 96_000])
    func otherSampleRates(rate: Double) {
        let (samples, truth) = SyntheticSignal.kickTrain(bpm: 124, seconds: 12, sampleRate: rate)
        let run = AnalysisRun(sampleRate: rate).feed(samples)
        #expect(run.analyzer.frameInterval > 0.009 && run.analyzer.frameInterval < 0.012)
        #expect(abs(Double(run.features.bpm) - 124) <= 2)
        #expect(largestError(run.beats(after: 6), truth) <= 0.05)
    }

    @Test("The demo synthesizer reads as 120 BPM on the beat")
    func demoSynth() {
        let synth = DemoAudioSynth(sampleRate: Self.rate)
        let start = 3.1
        let samples = synth.render(seconds: 14, from: start)
        // Beats of the song, on the render's own timeline.
        let truth = stride(from: 0.0, through: 14, by: 0.5).map { $0 + (0.5 - start.truncatingRemainder(dividingBy: 0.5)) }
        let run = AnalysisRun(sampleRate: Self.rate).feed(samples)
        #expect(abs(run.features.bpm - 120) <= 2)
        #expect(largestError(run.beats(after: 6), truth) <= 0.05)
        #expect(run.features.bands.bass > run.features.bands.high)
        #expect(!run.features.isSilent)
    }

    @Test("Silence turns isSilent on within the gate time and sound turns it off at once")
    func silenceGate() throws {
        let sound = SyntheticSignal.drumPattern(bpm: 120, seconds: 6, sampleRate: Self.rate).samples
        let quiet = SyntheticSignal.silence(seconds: 3, sampleRate: Self.rate)
        let again = SyntheticSignal.drumPattern(bpm: 120, seconds: 2, sampleRate: Self.rate).samples
        let run = AnalysisRun(sampleRate: Self.rate).feed(sound + quiet + again)

        #expect(run.firstTime(after: 0, where: { !$0.features.isSilent }).map { $0 < 0.3 } == true)
        // Kick tails ring out briefly; the gate then waits 0.35 s.
        let closed = try #require(run.firstTime(after: 6, where: { $0.features.isSilent }))
        #expect(closed - 6 <= 0.8, "silent after \(closed - 6) s")
        let silentFrame = try #require(run.frames.first { $0.time >= 7.5 }?.frame)
        #expect(silentFrame.features.energy == 0 && silentFrame.features.bands == .zero && silentFrame.features.onset == 0)
        #expect(run.beats.filter { $0.time > 7 && $0.time < 9 }.isEmpty, "no beats in silence")
        // Over 2.5 s of silence the tempo is forgotten (the next song may differ).
        #expect(try #require(run.frames.last { $0.time < 9 }?.frame).features.bpm == 0)
        // The pattern's first kick comes 0.25 s into it.
        let reopened = try #require(run.firstTime(after: 9, where: { !$0.features.isSilent }))
        #expect(reopened - 9.25 <= 0.05)
    }

    @Test("Digital silence from the start stays silent with no beats")
    func pureSilence() {
        let run = AnalysisRun(sampleRate: Self.rate).feed(SyntheticSignal.silence(seconds: 4, sampleRate: Self.rate))
        #expect(run.features.isSilent)
        #expect(run.beats.isEmpty && run.onsets.isEmpty)
        #expect(run.features == .silence)
    }

    @Test("A low sine lights the low bands, a high sine the high band")
    func bandSanity() {
        func bands(_ frequency: Double) -> AudioFeatures {
            AnalysisRun(sampleRate: Self.rate).feed(SyntheticSignal.sine(frequency: frequency, seconds: 2, sampleRate: Self.rate)).features
        }
        let low = bands(45)
        #expect(low.bands.subBass >= 0.9)
        #expect(low.bands.subBass > low.bands.bass)
        #expect(low.bands.mid < 0.05 && low.bands.high < 0.05)

        let bass = bands(120)
        #expect(bass.bands.bass >= 0.9 && bass.bands.high < 0.05)

        let middle = bands(1_000)
        #expect(middle.bands.mid >= 0.9)
        #expect(middle.bands.subBass < 0.05 && middle.bands.high < 0.05)

        let high = bands(8_000)
        #expect(high.bands.high >= 0.9)
        #expect(high.bands.subBass < 0.05 && high.bands.bass < 0.05 && high.bands.mid < 0.05)

        // The spectrum peaks in the band that holds the frequency.
        for frequency in [45.0, 120, 1_000, 8_000] {
            let spectrum = bands(frequency).spectrum
            let peak = (0..<AudioFeatures.spectrumCount).max { spectrum[$0] < spectrum[$1] }!
            let range = AudioFeatures.spectrumRange
            let expected = Int(Double(AudioFeatures.spectrumCount) * log(frequency / range.lowerBound) / log(range.upperBound / range.lowerBound))
            #expect(abs(peak - expected) <= 1, "\(frequency) Hz peaks in band \(peak), expected \(expected)")
        }
    }

    @Test("A steady tone has no tempo and no beats", arguments: [60.0, 440])
    func steadyTone(frequency: Double) {
        let run = AnalysisRun(sampleRate: Self.rate).feed(SyntheticSignal.sine(frequency: frequency, seconds: 8, sampleRate: Self.rate))
        #expect(run.features.bpm == 0)
        #expect(run.features.tempoConfidence < BeatTracker.lockConfidence)
        #expect(run.beats.count <= 1, "at most the tone's own start")
    }

    @Test("White noise does not produce a beat storm", arguments: [UInt64(1), 2, 3])
    func noise(seed: UInt64) {
        let run = AnalysisRun(sampleRate: Self.rate).feed(SyntheticSignal.noise(seconds: 16, sampleRate: Self.rate, seed: seed))
        #expect(run.beats.count <= 4, "\(run.beats.count) beats in 16 s of noise")
        #expect(run.beats.allSatisfy { !$0.isPredicted })
        #expect(run.features.bpm == 0)
        #expect(run.features.tempoConfidence < BeatTracker.lockConfidence)
        let onsets = run.frames.filter { $0.time > 2 }.map(\.frame.features.onset)
        #expect(onsets.reduce(0, +) / Float(onsets.count) < 0.1, "noise barely flickers the onset")
        #expect(!run.features.isSilent)
    }

    @Test("Kicks under noise still lock to the tempo")
    func kicksInNoise() {
        var (samples, truth) = SyntheticSignal.kickTrain(bpm: 120, seconds: 14, sampleRate: Self.rate)
        let noise = SyntheticSignal.noise(seconds: 14, sampleRate: Self.rate, amplitude: 0.1, seed: 9)
        for index in samples.indices { samples[index] += noise[index] }
        let run = AnalysisRun(sampleRate: Self.rate).feed(samples)
        #expect(abs(run.features.bpm - 120) <= 2)
        #expect(largestError(run.beats(after: 6), truth) <= 0.05)
    }

    @Test("Kicks trigger beats before the tempo is known")
    func reactiveBeats() {
        let (samples, truth) = SyntheticSignal.kickTrain(bpm: 120, seconds: 2.4, sampleRate: Self.rate)
        let run = AnalysisRun(sampleRate: Self.rate).feed(samples)
        let early = run.beats.filter { !$0.isPredicted }
        #expect(early.count >= 3)
        #expect(largestError(early, truth) <= 0.05)
    }

    @Test("Every value stays finite and in range")
    func ranges() {
        let rate = Self.rate
        let signal = SyntheticSignal.drumPattern(bpm: 128, seconds: 5, sampleRate: rate).samples
            + SyntheticSignal.silence(seconds: 1, sampleRate: rate)
            + SyntheticSignal.noise(seconds: 2, sampleRate: rate, amplitude: 0.9, seed: 5)
            + SyntheticSignal.sine(frequency: 30, seconds: 1, sampleRate: rate, amplitude: 1)
            + [Float](repeating: 1, count: 4_800) + [Float](repeating: -1, count: 4_800)
        let run = AnalysisRun(sampleRate: rate).feed(signal, chunk: 333)
        for (_, frame) in run.frames {
            let f = frame.features
            let levels = [f.energy, f.onset, f.tempoConfidence, f.bands.subBass, f.bands.bass, f.bands.lowMid, f.bands.mid, f.bands.high]
            #expect(levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            #expect((0..<AudioFeatures.spectrumCount).allSatisfy { f.spectrum[$0].isFinite && f.spectrum[$0] >= 0 && f.spectrum[$0] <= 1 })
            #expect(f.bpm == 0 || (f.bpm >= 60 && f.bpm <= 200))
            #expect(frame.beatStrength >= 0 && frame.beatStrength <= 1)
        }
    }

    @Test("Chunk size does not change the result")
    func chunking() {
        let samples = SyntheticSignal.drumPattern(bpm: 110, seconds: 9, sampleRate: Self.rate).samples
        let small = AnalysisRun(sampleRate: Self.rate).feed(samples, chunk: 97)
        let large = AnalysisRun(sampleRate: Self.rate).feed(samples, chunk: 4_096)
        #expect(small.beats == large.beats)
        #expect(small.analyzer.frame == large.analyzer.frame)
    }

    @Test("Reset starts over but keeps counting beats")
    func reset() {
        let run = AnalysisRun(sampleRate: Self.rate).feed(SyntheticSignal.kickTrain(bpm: 120, seconds: 8, sampleRate: Self.rate).samples)
        let counted = run.features.beatIndex
        #expect(counted >= 12)
        run.analyzer.reset()
        #expect(run.analyzer.time == 0)
        #expect(run.features.isSilent && run.features.bpm == 0)
        #expect(run.features.beatIndex == counted)
        run.feed(SyntheticSignal.kickTrain(bpm: 120, seconds: 2, sampleRate: Self.rate).samples)
        #expect(run.features.beatIndex > counted)
    }

    @Test("A new song forgets the tempo but not the levels")
    func resetTempo() {
        let run = AnalysisRun(sampleRate: Self.rate).feed(SyntheticSignal.kickTrain(bpm: 90, seconds: 8, sampleRate: Self.rate).samples)
        #expect(abs(run.features.bpm - 90) <= 2)
        run.analyzer.resetTempo()
        run.feed(SyntheticSignal.kickTrain(bpm: 140, seconds: 0.1, sampleRate: Self.rate).samples)
        #expect(run.features.bpm == 0)
        run.feed(SyntheticSignal.kickTrain(bpm: 140, seconds: 8, sampleRate: Self.rate).samples)
        #expect(abs(run.features.bpm - 140) <= 2)
    }
}
