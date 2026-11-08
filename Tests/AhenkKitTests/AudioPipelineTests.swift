import Foundation
import Testing
@testable import AhenkKit

@Suite("Audio analysis pipeline")
struct AudioPipelineTests {
    static let rate = 48_000.0

    /// Feeds `samples` in real-time-sized chunks, pumping after each with a
    /// clock that advances with the audio.
    private func play(_ samples: [Float], through pipeline: AudioAnalysisPipeline, start: Double = 100) -> Double {
        var now = start
        samples.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(480, buffer.count - offset)
                pipeline.ring.writer.write(buffer.baseAddress! + offset, count: count)
                offset += count
                now += Double(count) / Self.rate
                pipeline.pump(now: now)
            }
        }
        return now
    }

    private func makePipeline() -> AudioAnalysisPipeline {
        let pipeline = AudioAnalysisPipeline(store: AudioFeatureStore(), ringCapacity: 1 << 15)
        pipeline.configure(sampleRate: Self.rate)
        pipeline.setGate(open: true, at: 100)
        return pipeline
    }

    @Test("Samples written to the ring come out of the store on the host clock")
    func endToEnd() {
        let pipeline = makePipeline()
        let samples = SyntheticSignal.kickTrain(bpm: 120, seconds: 9, sampleRate: Self.rate).samples
        let end = play(samples, through: pipeline)
        let frame = pipeline.store.latestFrame()
        #expect(abs(frame.time - end) < 0.02, "frames are stamped with the host time of their sound")
        let features = pipeline.store.features(at: end)
        #expect(!features.isSilent && abs(features.bpm - 120) <= 2)
        // The newest beat is a kick less than one beat ago (or announced).
        #expect(frame.beatTime > end - 0.55 && frame.beatTime < end + 0.05)
        #expect(pipeline.analysedSeconds > 8.9)
        #expect(pipeline.digitalSilence == 0)
    }

    @Test("A closed gate publishes silence at once and drops what arrives")
    func gate() {
        let pipeline = makePipeline()
        let end = play(SyntheticSignal.drumPattern(bpm: 120, seconds: 3, sampleRate: Self.rate).samples, through: pipeline)
        #expect(!pipeline.store.features(at: end).isSilent)
        pipeline.setGate(open: false, at: end)
        #expect(pipeline.store.features(at: end).isSilent)
        let later = play(SyntheticSignal.drumPattern(bpm: 120, seconds: 1, sampleRate: Self.rate).samples, through: pipeline, start: end)
        #expect(pipeline.store.features(at: later).isSilent)
        #expect(pipeline.ring.availableSamples == 0)
        pipeline.setGate(open: true, at: later)
        let reopened = play(SyntheticSignal.drumPattern(bpm: 120, seconds: 0.5, sampleRate: Self.rate).samples, through: pipeline, start: later)
        #expect(!pipeline.store.features(at: reopened).isSilent)
    }

    @Test("Sensitivity scales the levels and clamps them at 1")
    func sensitivity() {
        let quiet = makePipeline()
        let loud = makePipeline()
        loud.sensitivity = 3
        let samples = SyntheticSignal.drumPattern(bpm: 120, seconds: 3, sampleRate: Self.rate).samples
        let end = play(samples, through: quiet)
        _ = play(samples, through: loud)
        let a = quiet.store.latestFrame().features
        let b = loud.store.latestFrame().features
        #expect(b.energy == min(1, a.energy * 3))
        #expect(b.bands.high == min(1, a.bands.high * 3))
        #expect((0..<AudioFeatures.spectrumCount).allSatisfy { b.spectrum[$0] <= 1 })
        #expect(b.bpm == a.bpm, "timing is untouched")
        #expect(quiet.store.features(at: end).beatIndex == loud.store.features(at: end).beatIndex)
    }

    @Test("The presentation delay holds frames until their sound is heard")
    func presentationDelay() {
        let pipeline = makePipeline()
        pipeline.presentationDelay = 0.2
        let end = play(SyntheticSignal.drumPattern(bpm: 120, seconds: 2, sampleRate: Self.rate).samples, through: pipeline)
        let frame = pipeline.store.latestFrame()
        // The newest published frame describes sound heard by now, which
        // left the ring 0.2 s ago.
        #expect(frame.time <= end + 0.001)
        #expect(frame.time > end - 0.03)
        let direct = makePipeline()
        _ = play(SyntheticSignal.drumPattern(bpm: 120, seconds: 2, sampleRate: Self.rate).samples, through: direct)
        #expect(direct.analyzer!.time - pipeline.analyzer!.time == 0, "both analysed everything")
        pipeline.presentationDelay = 5
        #expect(pipeline.presentationDelay == 0.5)
    }

    @Test("Digital silence is counted while the gate is closed too")
    func digitalSilence() {
        let pipeline = makePipeline()
        pipeline.setGate(open: false, at: 100)
        _ = play(SyntheticSignal.silence(seconds: 2, sampleRate: Self.rate), through: pipeline)
        #expect(abs(pipeline.digitalSilence - 2) < 0.02)
        _ = play(SyntheticSignal.sine(frequency: 200, seconds: 0.1, sampleRate: Self.rate), through: pipeline)
        #expect(pipeline.digitalSilence == 0)
    }

    @Test("Stopping publishes silence and starts over")
    func stop() {
        let pipeline = makePipeline()
        let end = play(SyntheticSignal.kickTrain(bpm: 120, seconds: 4, sampleRate: Self.rate).samples, through: pipeline)
        let index = pipeline.store.latestFrame().features.beatIndex
        pipeline.stop(at: end)
        let features = pipeline.store.features(at: end)
        #expect(features.isSilent && features.energy == 0)
        #expect(features.beatIndex == index)
        #expect(pipeline.analyzer!.time == 0)
    }

    @Test("A new sample rate replaces the analyzer, the same one keeps it")
    func configure() {
        let pipeline = makePipeline()
        let first = pipeline.analyzer
        pipeline.configure(sampleRate: Self.rate)
        #expect(pipeline.analyzer === first)
        pipeline.configure(sampleRate: 44_100)
        #expect(pipeline.analyzer !== first && pipeline.analyzer?.sampleRate == 44_100)
    }

    @Test("The beat counter never goes backwards, not even with a new sample rate")
    func beatCounterContinues() {
        let pipeline = makePipeline()
        let end = play(SyntheticSignal.kickTrain(bpm: 120, seconds: 4, sampleRate: Self.rate).samples, through: pipeline)
        let counted = pipeline.store.features(at: end).beatIndex
        #expect(counted >= 6)
        pipeline.stop(at: end)
        pipeline.configure(sampleRate: 44_100)
        #expect(pipeline.analyzer?.frame.features.beatIndex == counted)
        pipeline.setGate(open: true, at: end)
        var now = end
        let kicks = SyntheticSignal.kickTrain(bpm: 120, seconds: 2, sampleRate: 44_100).samples
        kicks.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(441, buffer.count - offset)
                pipeline.ring.writer.write(buffer.baseAddress! + offset, count: count)
                offset += count
                now += Double(count) / 44_100
                pipeline.pump(now: now)
            }
        }
        #expect(pipeline.store.features(at: now).beatIndex > counted)
    }
}
