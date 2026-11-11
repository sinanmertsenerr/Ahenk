import AhenkKit
import Foundation

/// Hears where the song falls in its clip: reads the sound the clip's
/// player holds, a window after the other from where the player stands
/// (the clip runs beside the song from a guessed place, so what it holds
/// is what is sung about now, not an intro), has whisper write down the
/// words, and looks them up in the song's timed lyrics
/// (`LyricShiftEstimator`) until enough of them agree: a window or two.
/// Nothing is kept of the sound or the words but the one number.
@MainActor
enum SongClipOffsetFinder {
    static let windowSeconds = 12.0
    /// Three minutes of the clip at most.
    static let maximumWindows = 15
    /// The player holds no more yet: asked again this often, this many times in a row.
    static let waitForMore: Duration = .milliseconds(400)
    static let maximumMisses = 90
    static let maximumFailures = 60

    enum Outcome: Equatable {
        case heard(LyricShift)
        /// Everything it could read did not say (or there was nothing to read).
        case cannotTell(String)
    }

    /// - Parameters:
    ///   - range: the offsets that are possible at all (`SongClip.possibleOffsets`).
    ///   - onLikely: called with an answer that is likely but not yet
    ///     sure (`LyricShift.isLikely`), so the clip can be moved at once.
    static func hear(
        _ media: YouTubeMediaView, lines: [LyricLine], runner: WhisperRunner, log: AhenkLogger,
        within range: ClosedRange<Double>? = nil, onLikely: (@MainActor (LyricShift) -> Void)? = nil
    ) async -> Outcome {
        var words: [RecognizedWord] = []
        var from = 0.0
        var windows = 0
        var misses = 0
        var failures = 0
        var best: LyricShift?
        let length = media.candidate.duration ?? .infinity
        while windows < maximumWindows, from + 6 < length {
            if Task.isCancelled { return .cannotTell("stopped") }
            switch await media.sound(from: from, seconds: min(windowSeconds, length - from)) {
            case .failed(let reason):
                // The player starts a new stream now and then (another
                // quality): for a moment it holds none whose start it knows.
                failures += 1
                if failures >= maximumFailures { return .cannotTell("the player did not give its sound (\(reason))") }
                try? await Task.sleep(for: waitForMore)
            case .notYet:
                misses += 1
                if misses >= maximumMisses { return .cannotTell("the player holds no more of the clip's sound (\(Int(from)) s read)") }
                try? await Task.sleep(for: waitForMore)
            case .sound(let sound):
                misses = 0
                failures = 0
                windows += 1
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-clip-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                let started = Date()
                do {
                    try await Task.detached(priority: .utility) { try WhisperAudio.write(sound.samples, rate: sound.sampleRate, to: wav) }.value
                    let transcript = try await runner.transcribe(wav, timeout: 180)
                    words += transcript.words.map { RecognizedWord(text: $0.text, start: $0.start + sound.start, end: $0.end + sound.start, confidence: $0.confidence) }
                    best = LyricShiftEstimator.estimate(lines: lines, words: words, within: range)
                    // Counts only: words are never written to the log.
                    let evidence = best.map { "\($0.lines) lines and \($0.words) words say \(String(format: "%+.1f", $0.seconds)) s, \(String(format: "%.1f", $0.score)) against \(String(format: "%.1f", $0.rivalScore))" } ?? "none of them in the lyrics"
                    log.info("Read \(transcript.words.count) words in \(Int(sound.seconds.rounded())) s of the clip from \(Int(sound.start)) s (\(String(format: "%.1f", Date().timeIntervalSince(started))) s): \(evidence)")
                } catch {
                    log.error("whisper did not read a window of the clip: \(error)")
                }
                from = sound.start + sound.seconds
                if let best, best.isConfident { return .heard(best) }
                if let best, best.isLikely { onLikely?(best) }
            }
        }
        return .cannotTell("\(windows) windows of the clip did not say where the song falls in it")
    }
}
