import Foundation
import Testing
@testable import AhenkKit

private func features(beatIndex: Int, beatPhase: Float = 0, bpm: Float = 120, energy: Float = 0.8, silent: Bool = false) -> AudioFeatures {
    AudioFeatures(
        energy: silent ? 0 : energy, bands: .zero, spectrum: .zero, onset: 0, beat: silent ? 0 : 0.5,
        beatPhase: beatPhase, beatIndex: beatIndex, bpm: bpm, tempoConfidence: bpm > 0 ? 0.8 : 0, isSilent: silent
    )
}

@Suite("Dock art")
struct DockArtTests {
    @Test("The mode follows the setting, the song, the play state and the power state")
    func policy() {
        #expect(DockArtPolicy.mode(DockArtInputs()) == .animated(framesPerSecond: DockArtPolicy.normalFramesPerSecond))
        #expect(DockArtPolicy.mode(DockArtInputs(enabled: false)) == .appIcon)
        #expect(DockArtPolicy.mode(DockArtInputs(hasCover: false)) == .appIcon, "nothing to show: the app's icon")
        #expect(DockArtPolicy.mode(DockArtInputs(isPlaying: false)) == .still, "paused: the cover, still")
        #expect(DockArtPolicy.mode(DockArtInputs(beatRing: false)) == .still)
        #expect(DockArtPolicy.mode(DockArtInputs(isLowPowerMode: true)) == .still)
        #expect(DockArtPolicy.mode(DockArtInputs(isThermallyConstrained: true)) == .still)
        #expect(DockArtPolicy.mode(DockArtInputs(optimizedMode: true)) == .animated(framesPerSecond: DockArtPolicy.lighterFramesPerSecond))
        #expect(DockArtPolicy.mode(DockArtInputs(isOnBattery: true)) == .animated(framesPerSecond: DockArtPolicy.lighterFramesPerSecond))
        #expect(DockArtPolicy.mode(DockArtInputs(lighterOnBattery: false, isOnBattery: true, isLowPowerMode: true)) == .animated(framesPerSecond: DockArtPolicy.normalFramesPerSecond),
                "with \u{201C}run lighter on battery\u{201D} off, battery and Low Power Mode change nothing")
        #expect(DockArtPolicy.normalFramesPerSecond <= 12 && DockArtPolicy.lighterFramesPerSecond < DockArtPolicy.normalFramesPerSecond)
    }

    @Test("A beat swells the ring at once and it fades within the beat, also when frames are far apart")
    func beatSwell() {
        var motion = DockRingMotion()
        _ = motion.frame(features: features(beatIndex: 10), at: 0, progress: 0.2, isPlaying: true)
        // The next beat, seen 30 ms after it happened (a slow reader).
        let beat = motion.frame(features: features(beatIndex: 11, beatPhase: 0.06), at: 1.0, progress: 0.2, isPlaying: true)
        #expect(beat.pulse > 0.7 && beat.pulse <= 1)
        let later = motion.frame(features: features(beatIndex: 11, beatPhase: 0.3), at: 1.12, progress: 0.2, isPlaying: true)
        #expect(later.pulse < beat.pulse && later.pulse > 0.2, "still visible a frame later at 10 fps")
        let end = motion.frame(features: features(beatIndex: 11, beatPhase: 0.9), at: 1.42, progress: 0.2, isPlaying: true)
        #expect(end.pulse < 0.1, "faded before the next beat at 120 BPM")
        // Without a known tempo the swell starts at the moment it is seen.
        let untimed = motion.frame(features: features(beatIndex: 12, beatPhase: 0, bpm: 0), at: 2.0, progress: 0.2, isPlaying: true)
        #expect(untimed.pulse > 0.85)
    }

    @Test("The swell is the same at 10 and at 5 frames a second for the same moments")
    func frameRateIndependent() {
        func run(step: Double) -> [Double: Double] {
            var motion = DockRingMotion()
            var samples: [Double: Double] = [:]
            var time = 0.0
            var index = 0
            while time < 4 {
                // A beat every 0.5 s; the reader sees it at its own pace.
                let beats = Int(time / 0.5)
                let phase = Float((time - Double(beats) * 0.5) / 0.5)
                let frame = motion.frame(features: features(beatIndex: beats, beatPhase: phase), at: time, progress: 0, isPlaying: true)
                samples[(time * 10).rounded() / 10] = frame.pulse
                index += 1
                time = Double(index) * step
            }
            return samples
        }
        let fast = run(step: 0.1), slow = run(step: 0.2)
        for (time, pulse) in slow where time >= 1 {
            let other = fast[time] ?? -1
            #expect(abs(other - pulse) < 0.02, "at \(time) s: \(pulse) vs \(other)")
        }
    }

    @Test("Silence and pauses give a still ring; the colours step on with every beat")
    func stillAndTurning() {
        var motion = DockRingMotion()
        let quiet = motion.frame(features: features(beatIndex: 3, silent: true), at: 0, progress: 0.5, isPlaying: true)
        #expect(!quiet.isPlaying && quiet.pulse == 0 && quiet.progress == 0.5)
        _ = motion.frame(features: features(beatIndex: 3), at: 1, progress: 0.5, isPlaying: true)
        let first = motion.frame(features: features(beatIndex: 4), at: 2, progress: 0.5, isPlaying: true)
        let settled = motion.frame(features: features(beatIndex: 4, beatPhase: 0.9), at: 2.45, progress: 0.5, isPlaying: true)
        #expect(abs(settled.turn - DockRingMotion.turnPerBeat) < 1e-9)
        #expect(first.turn < settled.turn)
        let paused = motion.frame(features: features(beatIndex: 4), at: 3, progress: 0.6, isPlaying: false)
        #expect(paused == .still(progress: 0.6, turn: settled.turn), "a pause keeps the colours where they were")
    }

    @Test("Frames that would look the same are not sent to the Dock")
    func differs() {
        let base = DockArtFrame(pulse: 0.5, level: 0.6, progress: 0.25, turn: 0.1, isPlaying: true)
        #expect(DockRingMotion.differs(base, from: nil))
        #expect(!DockRingMotion.differs(base, from: base))
        var tiny = base
        tiny.pulse += 0.02
        tiny.level += 0.03
        tiny.progress += 0.001
        #expect(!DockRingMotion.differs(tiny, from: base))
        var pulse = base
        pulse.pulse += 0.08
        #expect(DockRingMotion.differs(pulse, from: base))
        var progress = base
        progress.progress += 2.0 / 360
        #expect(DockRingMotion.differs(progress, from: base))
        // Across the colours' seam: 0.999 and 0.001 are 0.72° apart.
        let a = DockArtFrame(pulse: 0, level: 0, progress: 0, turn: 0.999, isPlaying: true)
        let b = DockArtFrame(pulse: 0, level: 0, progress: 0, turn: 0.001, isPlaying: true)
        #expect(!DockRingMotion.differs(a, from: b))
        #expect(DockRingMotion.differs(DockArtFrame.still(progress: 0.25, turn: 0.1), from: base))
    }

    @Test("The ring grows with the swell and always fits in the tile")
    func geometry() {
        let calm = DockRingGeometry.of(DockArtFrame(pulse: 0, level: 0.5, progress: 0, turn: 0, isPlaying: true))
        let full = DockRingGeometry.of(DockArtFrame(pulse: 1, level: 1, progress: 0, turn: 0, isPlaying: true))
        let paused = DockRingGeometry.of(.still(progress: 0))
        #expect(full.ringWidth > calm.ringWidth && full.glowOpacity > calm.glowOpacity && full.ringRadius > calm.ringRadius)
        #expect(paused.glowRadius == 0 && paused.ringWidth < calm.ringWidth)
        for geometry in [calm, full, paused] {
            #expect(geometry.outerReach <= 0.5, "the ring stays inside the tile")
            #expect(geometry.ringRadius - geometry.ringWidth / 2 > geometry.coverRadius, "the ring never covers the cover")
        }
        let clamped = DockArtFrame(pulse: 4, level: -1, progress: 2, turn: -0.25, isPlaying: true)
        #expect(clamped.pulse == 1 && clamped.level == 0 && clamped.progress == 1 && abs(clamped.turn - 0.75) < 1e-12)
    }
}
