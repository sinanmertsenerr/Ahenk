import Foundation
import Testing
@testable import AhenkKit

@Suite("Audio feature store")
struct AudioFeatureStoreTests {
    private func frame(beat: Double, period: Double = 0.5, time: Double = 10) -> AudioFeatureFrame {
        var features = AudioFeatures.silence
        features.isSilent = false
        features.energy = 0.8
        features.beatIndex = 7
        return AudioFeatureFrame(
            features: features, time: time, beatTime: beat, previousBeatTime: beat - period,
            beatStrength: 1, previousBeatStrength: 0.5, beatPeriod: period, pulseDecay: 0.1
        )
    }

    @Test("The pulse decays from the beat and the phase follows the period")
    func pulseAndPhase() {
        let frame = frame(beat: 10)
        let onBeat = frame.features(at: 10)
        #expect(onBeat.beat == 1)
        #expect(onBeat.beatPhase == 0)
        #expect(onBeat.beatIndex == 7)
        let later = frame.features(at: 10.1)
        #expect(abs(later.beat - Float(exp(-1.0))) < 1e-4)
        #expect(abs(later.beatPhase - 0.2) < 1e-4)
        #expect(frame.features(at: 10.6).beatPhase < 1)
    }

    @Test("An announced beat shows only once its time has come")
    func announcedBeat() {
        // Predicted beats are published ~30 ms early.
        let frame = frame(beat: 10.03)
        let before = frame.features(at: 10)
        #expect(before.beatIndex == 6)
        #expect(abs(before.beat - 0.5 * Float(exp(-0.47 / 0.1))) < 1e-4)
        let after = frame.features(at: 10.03)
        #expect(after.beatIndex == 7)
        #expect(after.beat == 1)
    }

    @Test("A frame nobody refreshes fades to silence")
    func staleness() {
        let frame = frame(beat: 9.9, time: 10)
        #expect(frame.features(at: 10.2).energy == 0.8)
        let fading = frame.features(at: 10 + AudioFeatureStore.staleAfter + AudioFeatureStore.staleFade / 2)
        #expect(abs(fading.energy - 0.4) < 0.01)
        let gone = frame.features(at: 11)
        #expect(gone.isSilent && gone.energy == 0 && gone.beat == 0)
        #expect(gone.beatIndex == 7, "the beat counter survives")
    }

    @Test("Silence and unknown beats read as zero")
    func silenceFrame() {
        let silent = AudioFeatureFrame.silence.features(at: 3)
        #expect(silent.isSilent && silent.beat == 0 && silent.beatPhase == 0)
        // A silent frame shows no pulse even right after its last beat.
        var quiet = frame(beat: 10)
        quiet.features.isSilent = true
        #expect(quiet.features(at: 10.01).beat == 0 && quiet.features(at: 10.01).beatPhase == 0)
        let store = AudioFeatureStore()
        #expect(store.currentFeatures().isSilent)
        #expect(!store.isActive)
    }

    @Test("Readers on other threads never see a torn frame")
    func concurrentReads() async {
        let store = AudioFeatureStore()
        let writes = 50_000
        let writer = Task.detached {
            for index in 1...writes {
                var features = AudioFeatures.silence
                features.energy = Float(index)
                features.spectrum = SIMD32(repeating: Float(index))
                features.beatIndex = index
                features.isSilent = false
                store.publish(AudioFeatureFrame(features: features, time: Double(index), beatTime: Double(index), beatPeriod: Double(index)))
            }
        }
        let readers = (0..<3).map { _ in
            Task.detached { () -> Int in
                var torn = 0
                for _ in 0..<40_000 {
                    let frame = store.latestFrame()
                    let value = frame.features.beatIndex
                    if value == 0 { continue }
                    if frame.features.energy != Float(value) || frame.features.spectrum[31] != Float(value)
                        || frame.time != Double(value) || frame.beatPeriod != Double(value) {
                        torn += 1
                    }
                }
                return torn
            }
        }
        await writer.value
        for reader in readers {
            #expect(await reader.value == 0)
        }
        #expect(store.latestFrame().features.beatIndex == writes)
    }

    @Test("Observers hear the switches between silent and active")
    func activity() {
        let store = AudioFeatureStore()
        let heard = Recorder<Bool>()
        let observation = store.observeActivity { heard.append($0) }
        var active = AudioFeatureFrame.silence
        active.features.isSilent = false
        active.time = AudioClock.now()
        store.publish(active)
        store.publish(active)
        store.publishSilence()
        #expect(heard.values == [true, false])
        observation.cancel()
        store.publish(active)
        #expect(heard.values == [true, false])
    }
}
