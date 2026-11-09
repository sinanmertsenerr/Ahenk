import Foundation
import os
import Testing
@testable import AhenkKit

@Suite("Lyrics auto-sync")
struct LyricsAutoSyncTests {
    /// Triangular bumps at `times` over a low floor: a stand-in onset curve.
    static func curve(_ times: [Double], duration: Double = 25, hop: Double = 0.032) -> OnsetNovelty.Curve {
        let frames = Int(duration / hop)
        var values = [Float](repeating: 0.05, count: frames)
        let width = max(1, Int(0.1 / hop))
        for time in times {
            let center = Int(time / hop)
            for delta in -width...width where (0..<frames).contains(center + delta) {
                values[center + delta] = max(values[center + delta], 1 - Float(abs(delta)) / Float(width + 1))
            }
        }
        return OnsetNovelty.Curve(values: values, hopSeconds: hop)
    }

    static let lines: [Double] = [3, 7.5, 11, 15.5, 19, 22]

    @Test("The estimator finds a known shift either way, and none when there is none")
    func estimator() throws {
        let late = try #require(LyricOffsetEstimator.estimate(novelty: Self.curve(Self.lines.map { $0 + 0.6 }), lineOffsets: Self.lines))
        #expect(abs(late.leadSeconds - 0.6) < 0.1)
        let early = try #require(LyricOffsetEstimator.estimate(novelty: Self.curve(Self.lines.map { $0 - 0.5 }), lineOffsets: Self.lines))
        #expect(abs(early.leadSeconds + 0.5) < 0.1)
        let aligned = try #require(LyricOffsetEstimator.estimate(novelty: Self.curve(Self.lines), lineOffsets: Self.lines))
        #expect(abs(aligned.leadSeconds) < 0.1)
    }

    @Test("Doubt means no answer: too few lines, a flat curve, an even beat everywhere")
    func rejections() {
        #expect(LyricOffsetEstimator.estimate(novelty: Self.curve([3.6, 9.6, 15.6]), lineOffsets: [3, 9, 15]) == nil)
        #expect(LyricOffsetEstimator.estimate(novelty: OnsetNovelty.Curve(values: [Float](repeating: 0.05, count: 780), hopSeconds: 0.032), lineOffsets: Self.lines) == nil)
        let beat = stride(from: 0.5, to: 24.5, by: 0.7).map { $0 }
        #expect(LyricOffsetEstimator.estimate(novelty: Self.curve(beat), lineOffsets: Self.lines) == nil)
    }

    @Test("One window never decides; two that agree do")
    func session() {
        var session = LyricsSyncSession(key: "song", fingerprint: "fp")
        let first = LyricOffsetEstimator.diagnose(novelty: Self.curve(Self.lines.map { $0 + 0.6 }), lineOffsets: Self.lines)
        session.beginWindow()
        #expect(session.add(first) == nil, "a single window changes nothing")
        let second = LyricOffsetEstimator.diagnose(novelty: Self.curve(Self.lines.map { $0 + 0.62 }), lineOffsets: Self.lines)
        session.beginWindow()
        let offset = session.add(second)
        #expect(offset.map { abs($0 + 0.6) < 0.1 } == true, "lyrics that run early are shown later")
        #expect(session.isFinished && session.attempts == 2)

        var stubborn = LyricsSyncSession(key: "song", fingerprint: "fp")
        for _ in 0..<LyricsSyncSession.maximumWindows { stubborn.beginWindow() }
        #expect(stubborn.isFinished && stubborn.offset == nil)
    }

    @Test("The capture averages 48 kHz down to 16 kHz and knows when its first sample played")
    func capture() {
        let done = OSAllocatedUnfairLock(initialState: false)
        let capture = LyricsSyncCapture(seconds: 1) { _ in done.withLock { $0 = true } }
        let chunk = [Float](repeating: 0.5, count: 4_800)
        chunk.withUnsafeBufferPointer { buffer in
            for index in 0..<10 {
                capture.append(buffer.baseAddress!, count: buffer.count, rate: 48_000, hostTime: 100 + Double(index) * 0.1)
            }
        }
        #expect(capture.sampleRate == 16_000 && capture.startHostTime == 100)
        #expect(capture.samples.count == 16_000 && capture.samples.allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(done.withLock { $0 } && capture.isFinished)
        // Rates that do not divide stay as they are.
        let odd = LyricsSyncCapture(seconds: 1) { _ in }
        [Float](repeating: 0, count: 100).withUnsafeBufferPointer { odd.append($0.baseAddress!, count: 100, rate: 44_100, hostTime: 0) }
        #expect(odd.sampleRate == 44_100 / 3 || odd.sampleRate == 44_100)
    }

    @Test("Windows hold enough lines with room on both sides, and stop before the song ends")
    func plan() throws {
        let starts = stride(from: 4.0, through: 80, by: 4).map { $0 }
        let seconds = try #require(LyricsSyncPlan.window(starts: starts, from: 0, songEnd: 92))
        #expect(seconds >= LyricsSyncPlan.minimumSeconds && seconds <= LyricsSyncPlan.maximumSeconds)
        #expect(LyricsSyncPlan.offsets(starts: starts, windowStart: 0, duration: seconds).count >= LyricOffsetEstimator.minimumLines)
        #expect(LyricsSyncPlan.window(starts: starts, from: 70, songEnd: 92) == nil, "too few lines left")
        #expect(LyricsSyncPlan.window(starts: [1, 50, 99, 150, 200, 250], from: 0, songEnd: nil) == nil, "lines too far apart")
        let offsets = LyricsSyncPlan.offsets(starts: starts, windowStart: 10, duration: 20)
        #expect(offsets.allSatisfy { $0 >= LyricsSyncPlan.margin && $0 <= 20 - LyricsSyncPlan.margin })
    }

    /// The demo beat from `from` for `seconds`, with an invented "sung"
    /// tone starting `shift` seconds after each line start (none if nil).
    static func song(from: Double, seconds: Double, starts: [Double], shift: Double?) -> [Float] {
        let rate = LyricsSyncCapture.analysisRate
        var samples = DemoAudioSynth(sampleRate: rate).render(seconds: seconds, from: from)
        guard let shift else { return samples }
        for start in starts {
            let onset = start + shift - from
            guard onset >= 0, onset < seconds else { continue }
            let first = Int(onset * rate)
            // A sung phrase after a breath: six syllables of a voice with
            // eight harmonics, each a short attack, a vowel and a gap.
            let pitches = [233.0, 262, 294, 262, 233, 220]
            for (syllable, pitch) in pitches.enumerated() {
                let syllableStart = first + Int(Double(syllable) * 0.42 * rate)
                for index in 0..<Int(0.36 * rate) where syllableStart + index < samples.count {
                    let t = Double(index) / rate
                    let envelope = min(1, t / 0.015) * min(1, (0.36 - t) / 0.05)
                    var tone = 0.0
                    for harmonic in 1...8 {
                        let frequency = pitch * Double(harmonic)
                        tone += sin(2 * .pi * frequency * t + 0.012 * frequency / 5 * sin(2 * .pi * 5 * t)) / Double(harmonic)
                    }
                    samples[syllableStart + index] += Float(0.3 * envelope * tone / 2.7)
                }
            }
        }
        return samples
    }

    @Test("On generated audio the measurement never moves lines the wrong way")
    func neverWrong() {
        let starts = DemoCatalog.songs[0].lyrics.lines.map(\.start)
        for shift in [nil, 0.85] as [Double?] {
            var session = LyricsSyncSession(key: "song", fingerprint: "fp")
            for (from, seconds) in [(2.0, 32.0), (50.0, 32.0)] {
                session.beginWindow()
                // The analysis tracks the demo's 120 BPM: a beat every half second.
                let audio = Self.song(from: from, seconds: seconds, starts: starts, shift: shift)
                session.add(LyricsSyncSession.measure(audio, sampleRate: LyricsSyncCapture.analysisRate, starts: starts, position: from, beatPeriod: 0.5))
            }
            if let shift {
                #expect(session.offset.map { abs($0 + shift) < 0.1 } ?? true, "either nothing or the true correction")
            } else {
                #expect(session.offset == nil, "a beat without singing must not move the lines")
            }
        }
    }

    @Test("The tracked beat turns a backbeat match into an alias")
    func trackedBeat() {
        var window = LyricOffsetEstimator.Diagnostics(stage: .accepted, leadSeconds: -1.536, prominence: 0.3, zScore: 5, dominantPeriodSeconds: 0.992)
        #expect(LyricOffsetEstimator.consensus(window, window) != nil, "the novelty's own period misses it")
        window.trackedBeatSeconds = 0.5
        #expect(LyricOffsetEstimator.consensus(window, window) == nil)
        #expect(LyricsSyncSession.beatPeriod(bpm: 120, confidence: 0.8) == 0.5)
        #expect(LyricsSyncSession.beatPeriod(bpm: 120, confidence: 0.1) == nil)
        #expect(LyricsSyncSession.beatPeriod(bpm: 0, confidence: 1) == nil)
    }
}
