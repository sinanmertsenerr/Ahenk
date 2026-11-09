import AhenkKit
import AppKit

/// Smoke check `lyricAlignment`: the aligner times a demo song's invented
/// words against that song's own timing (heard in full, and with a third
/// of the words missing and strays added); a generated tone becomes the
/// WAV whisper reads; the model download's mechanics run on an invented
/// file on this disk (no network); the controller, in the demo, times the
/// playing song's words and the result is kept as the song's lyrics; and,
/// when this Mac has whisper-cli and a model, invented lines spoken by the
/// system voice into a file (never played) are recognised and timed.
@MainActor
enum LyricsAlignmentCheck {
    static func run(environment: AppEnvironment) async throws -> String {
        guard let demo = environment.demo else { throw SmokeFailure("No demo provider") }
        let song = demo.songs[0]
        let sung = song.lyrics.lines.filter { LyricsTimeline.isSung($0.text) }
        let lines = LyricAligner.plainLines(sung.map(\.text).joined(separator: "\n"))
        guard lines.count == sung.count, lines.count >= 6 else { throw SmokeFailure("the demo song has too few lines") }

        // 1. Heard in full: every line where the song has it.
        let heard = LyricsAlignmentController.asHeard(song.lyrics)
        let full = LyricAligner.align(lines: lines, words: heard, songDuration: song.track.duration)
        let worst = zip(full.lyrics.lines, sung).map { abs($0.start - $1.start) }.max() ?? 99
        guard full.quality == .good, full.anchoredLines == lines.count, worst < 0.01 else {
            throw SmokeFailure("heard in full: \(full.anchoredLines) of \(lines.count) lines, \(worst) s off at worst")
        }
        guard full.lyrics.hasWordTiming else { throw SmokeFailure("no word times") }

        // 2. A third of the words missing, strays in between: still close.
        var noisy: [RecognizedWord] = []
        for (index, word) in heard.enumerated() where index % 3 != 1 {
            noisy.append(word)
            if index % 7 == 0 { noisy.append(RecognizedWord(text: "mm", start: word.end, end: word.end + 0.05)) }
        }
        let rough = LyricAligner.align(lines: lines, words: noisy, songDuration: song.track.duration)
        let close = zip(rough.lyrics.lines, sung).filter { abs($0.start - $1.start) < 0.75 }.count
        guard rough.quality != .failed, close >= lines.count * 9 / 10 else {
            throw SmokeFailure("with a third of the words missing only \(close) of \(lines.count) lines are close")
        }

        // 3. A song file becomes the WAV whisper reads.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-smoke-align-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = folder.appendingPathComponent("tone.m4a")
        try await GeneratedSongFiles.writeM4A(GeneratedSongFiles.tone(seconds: 3, sampleRate: 44_100), sampleRate: 44_100, to: tone,
                                              title: "Generated", artist: "Ahenk Tones", album: nil)
        let wav = folder.appendingPathComponent("tone.wav")
        let seconds = try await WhisperAudio.convert(tone, to: wav)
        let header = try Data(contentsOf: wav).prefix(12)
        guard abs(seconds - 3) < 0.2, String(decoding: header.prefix(4), as: UTF8.self) == "RIFF" else {
            throw SmokeFailure("the song file was converted to \(seconds) s")
        }

        // 4. The download's mechanics, from one place on this disk to another.
        let source = folder.appendingPathComponent("ggml-smoke-source.bin")
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: source)
        let destination = folder.appendingPathComponent("Models/ggml-smoke.bin")
        let failure: Error? = await withCheckedContinuation { continuation in
            let downloader = ModelDownloader(source: source, destination: destination)
            downloader.start(onProgress: { _ in }, completion: { error in
                _ = downloader
                continuation.resume(returning: error)
            })
        }
        guard failure == nil, (try? Data(contentsOf: destination)) == payload else {
            throw SmokeFailure("the download did not arrive: \(failure.map { String(describing: $0) } ?? "other bytes")")
        }
        guard WhisperLocator.rank(ofModel: "ggml-smoke.bin") == nil else { throw SmokeFailure("the invented file counts as a model") }

        // 5. The controller, in the demo: the playing song's words are timed
        //    and kept as its lyrics; "use the lyrics Ahenk found" drops them.
        let controller = environment.lyrics
        let aligner = environment.aligner
        let settings = environment.settings
        let wasEnabled = settings.lyrics.enabled
        settings.lyrics.enabled = true
        controller.start()
        defer {
            aligner.stop()
            controller.stop()
            settings.lyrics.enabled = wasEnabled
        }
        func wait(_ what: String, seconds: Double = 6, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("\(what) within \(Int(seconds)) s") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait("no lyrics for the playing demo song") { controller.phase == .synced }
        guard let original = controller.lyrics, aligner.isDemo else { throw SmokeFailure("the aligner is not the demo's") }
        aligner.prepare()
        guard aligner.lineCount == original.lines.filter({ LyricsTimeline.isSung($0.text) }).count, aligner.canStart else {
            throw SmokeFailure("the panel did not take the song's \(original.lines.count) lines")
        }
        aligner.start()
        try await wait("the alignment did not finish") {
            if case .done = aligner.stage { return true }
            if case .failed = aligner.stage { return true }
            return false
        }
        guard case .done(let timed, let total, _) = aligner.stage else { throw SmokeFailure("the alignment failed: \(aligner.stage)") }
        guard controller.source == LyricsFinder.alignedSource, controller.choice?.provider == LyricsFinder.alignedSource,
              controller.phase == .synced, let aligned = controller.lyrics, aligned.hasWordTiming
        else { throw SmokeFailure("the aligned lyrics were not adopted") }
        let drift = zip(aligned.lines, original.lines.filter { LyricsTimeline.isSung($0.text) }).map { abs($0.start - $1.start) }.max() ?? 99
        guard drift < 0.01 else { throw SmokeFailure("the adopted lines are \(drift) s off") }
        controller.useAutomatic()
        try await wait("the found lyrics did not come back") { controller.choice == nil && controller.lyrics == original }

        // 6. The real tool, when this Mac has it.
        let tools = WhisperLocator.system.locate(
            executableOverride: settings.lyrics.whisperExecutablePath, modelOverride: settings.lyrics.whisperModelPath
        )
        var real = "whisper-cli or a model is not on this Mac (\(tools.missing.map(\.rawValue).joined(separator: ", ")) missing): the real run was skipped"
        if let executable = tools.executable, let model = tools.model {
            real = try await runRealTool(executable: executable, model: model, in: folder)
        }
        return "\(lines.count) invented lines timed against the demo song (±\(String(format: "%.3f", worst)) s heard in full; \(close) of \(lines.count) close with a third of the words missing), "
            + "a generated song file converted to \(String(format: "%.1f", seconds)) s of 16 kHz WAV, the download's mechanics on a local file, "
            + "the demo's controller timed \(timed) of \(total) lines and kept them as the song's lyrics; " + real
    }

    /// Invented lines spoken into a file by the system voice (`say -o`,
    /// which plays nothing), recognised by whisper and timed.
    private static func runRealTool(executable: URL, model: URL, in folder: URL) async throws -> String {
        let lines = ["The lantern keeps a quiet road", "We count the windows of the rain", "A paper boat is going home"]
        let spoken = folder.appendingPathComponent("lines.aiff")
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", spoken.path, lines.joined(separator: ". [[slnc 900]] ") + "."]
            say.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try say.run()
            } catch {
                continuation.resume(throwing: SmokeFailure("the system voice could not be started: \(error.localizedDescription)"))
            }
        }
        guard status == 0 else { throw SmokeFailure("the system voice ended with status \(status)") }
        let wav = folder.appendingPathComponent("lines.wav")
        let seconds = try await WhisperAudio.convert(spoken, to: wav)
        let started = Date()
        let transcript = try await WhisperRunner(executable: executable, model: model).transcribe(wav, timeout: 40)
        let took = Date().timeIntervalSince(started)
        let result = LyricAligner.align(lines: lines, words: transcript.words, songDuration: seconds)
        let starts = result.lyrics.lines.map(\.start)
        guard result.quality == .good, result.anchoredLines == lines.count, starts == starts.sorted(), starts[0] < 1, starts[2] < seconds else {
            throw SmokeFailure("whisper heard \(transcript.words.map(\.text)); \(result.anchoredLines) of \(lines.count) lines timed at \(starts)")
        }
        // The way another app's song takes: the same sound as the analysis
        // would hand it over (48 kHz mono in small chunks, from a moment in
        // the middle of a song), collected in memory, written for whisper,
        // recognised, and timed as positions in that song.
        let wavData = try Data(contentsOf: wav)
        let spokenSamples: [Float] = stride(from: 44, to: wavData.count - 1, by: 2).map { offset in
            Float(Int16(littleEndian: wavData.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })) / 32_768
        }
        let position = 30.0
        let capture = LyricsSyncCapture(seconds: seconds - 0.2) { _ in }
        var chunk = [Float](repeating: 0, count: 480)
        var fed = 0
        while fed < spokenSamples.count, !capture.isFinished {
            // Each 16 kHz sample three times is the same sound at 48 kHz.
            for index in 0..<480 { chunk[index] = spokenSamples[min(spokenSamples.count - 1, fed + index / 3)] }
            capture.append(chunk, count: 480, rate: 48_000, hostTime: 1_000 + Double(fed) / 16_000)
            fed += 160
        }
        guard capture.isFinished, capture.sampleRate == 16_000, abs(capture.duration - (seconds - 0.2)) < 0.1 else {
            throw SmokeFailure("the capture holds \(capture.duration) s at \(capture.sampleRate) Hz")
        }
        let heardFile = folder.appendingPathComponent("heard.wav")
        try WhisperAudio.write(capture.samples, rate: capture.sampleRate, to: heardFile)
        let again = try await WhisperRunner(executable: executable, model: model).transcribe(heardFile, timeout: 40)
        let later = LyricAligner.align(lines: lines, words: again.words, audioStart: position, audioEnd: position + capture.duration, songDuration: 200)
        let shifted = zip(later.lyrics.lines.map(\.start), starts).map { abs($0 - $1 - position) }.max() ?? 99
        guard later.quality == .good, shifted < 0.4 else {
            func show(_ words: [RecognizedWord]) -> String { words.map { "\($0.text)@\(String(format: "%.2f", $0.start))" }.joined(separator: " ") }
            throw SmokeFailure("heard through a capture the lines are \(shifted) s off (\(later.anchoredLines) of \(lines.count) found): \(show(transcript.words)) / \(show(again.words))")
        }
        return "\(executable.lastPathComponent) with \(model.deletingPathExtension().lastPathComponent) recognised \(transcript.words.count) spoken words "
            + "of \(String(format: "%.1f", seconds)) s in \(String(format: "%.1f", took)) s and timed \(lines.count) lines at "
            + starts.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " s; the same sound collected as from another app's song at 0:30 "
            + "is timed \(String(format: "%.2f", shifted)) s from there at most"
    }
}
