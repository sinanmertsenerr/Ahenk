import Foundation
import Testing
@testable import AhenkKit

// Every lyric line, word and file name here is invented for the tests.

enum AlignmentFixtures {
    static let lines = [
        "The lantern keeps a quiet road",
        "We count the windows of the rain",
        "A paper boat is going home",
        "And every harbor learns my name",
        "Slow engines hum below the snow",
        "We count the windows of the rain",
    ]

    /// The words of `text` as a recogniser would report them: one after
    /// another from `start`, each `length` long.
    static func heard(_ text: String, from start: Double, length: Double = 0.4) -> [RecognizedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            RecognizedWord(text: String(word), start: start + Double(index) * length, end: start + Double(index + 1) * length - 0.05, confidence: 0.9)
        }
    }

    /// Every line sung at `starts`.
    static func sung(_ lines: [String] = lines, at starts: [Double]) -> [RecognizedWord] {
        zip(lines, starts).flatMap { heard($0, from: $1) }
    }

    static let starts: [Double] = [12, 16, 20, 24, 28, 40]
}

@Suite("Whisper transcript")
struct WhisperTranscriptTests {
    @Test("A word per segment: the segment's times, without markers and sounds")
    func wordSegments() throws {
        let json = """
        {"result": {"language": "en"}, "transcription": [
          {"offsets": {"from": 0, "to": 10}, "text": "", "tokens": [{"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "p": 0.99}]},
          {"offsets": {"from": 10, "to": 190}, "text": " The", "tokens": [{"text": " The", "offsets": {"from": 10, "to": 190}, "p": 0.94}]},
          {"offsets": {"from": 190, "to": 640}, "text": " lantern", "tokens": [{"text": " lantern", "offsets": {"from": 190, "to": 530}, "p": 0.98}]},
          {"offsets": {"from": 640, "to": 950}, "text": " road.", "tokens": [{"text": " road", "offsets": {"from": 640, "to": 900}, "p": 0.9}, {"text": ".", "offsets": {"from": 900, "to": 950}, "p": 0.7}]},
          {"offsets": {"from": 950, "to": 1900}, "text": " [Music]", "tokens": [{"text": " [", "offsets": {"from": 950, "to": 1000}, "p": 0.5}, {"text": "Music", "offsets": {"from": 1000, "to": 1800}, "p": 0.5}, {"text": "]", "offsets": {"from": 1800, "to": 1900}, "p": 0.5}]},
          {"offsets": {"from": 1900, "to": 2400}, "text": " ♪", "tokens": [{"text": " ♪", "offsets": {"from": 1900, "to": 2400}, "p": 0.4}]}
        ]}
        """
        let transcript = try WhisperTranscript(json: Data(json.utf8))
        #expect(transcript.language == "en")
        #expect(transcript.words.map(\.text) == ["The", "lantern", "road."])
        #expect(transcript.words[1].start == 0.19 && transcript.words[1].end == 0.64, "the segment's end, not the token's")
        #expect(abs(transcript.words[2].confidence - 0.8) < 1e-9, "the mean of the word's pieces")
    }

    @Test("Longer segments: words are put together from their pieces")
    func tokenSegments() throws {
        let json = """
        {"transcription": [
          {"offsets": {"from": 1000, "to": 3000}, "text": " A paperboat sails", "tokens": [
            {"text": " A", "offsets": {"from": 1000, "to": 1200}, "p": 0.9},
            {"text": " paper", "offsets": {"from": 1200, "to": 1700}, "p": 0.8},
            {"text": "boat", "offsets": {"from": 1700, "to": 2100}, "p": 0.6},
            {"text": " sails", "offsets": {"from": 2200, "to": 3000}, "p": 0.9},
            {"text": "[_TT_150]", "offsets": {"from": 3000, "to": 3000}, "p": 0.1}
          ]}
        ]}
        """
        let words = try WhisperTranscript(json: Data(json.utf8)).words
        #expect(words.map(\.text) == ["A", "paperboat", "sails"])
        #expect(words[1].start == 1.2 && words[1].end == 2.1)
        #expect(abs(words[1].confidence - 0.7) < 1e-9)
    }

    @Test("Segments without pieces share their time by the words' lengths; nonsense is refused")
    func plainSegments() throws {
        let json = #"{"transcription": [{"offsets": {"from": 2000, "to": 4000}, "text": " slow engines"}, {"text": "no times"}]}"#
        let words = try WhisperTranscript(json: Data(json.utf8)).words
        #expect(words.map(\.text) == ["slow", "engines"])
        #expect(words[0].start == 2 && abs(words[0].end - (2 + 2 * 4.0 / 11)) < 1e-9 && abs(words[1].end - 4) < 1e-9)
        #expect(throws: WhisperTranscript.ParseError.notJSON) { try WhisperTranscript(json: Data("progress = 10%".utf8)) }
        #expect(throws: WhisperTranscript.ParseError.noTranscription) { try WhisperTranscript(json: Data("{}".utf8)) }
        #expect(try WhisperTranscript(json: Data(#"{"transcription": []}"#.utf8)).words.isEmpty)
    }
}

@Suite("Lyric alignment")
struct LyricAlignmentTests {
    typealias F = AlignmentFixtures

    @Test("Pasted lyrics become lines: no blanks, no section headings")
    func plainLines() {
        let text = "[Verse 1]\n  The lantern keeps a quiet road  \n\n(Chorus)\nWe count the windows of the rain\n(oh, the rain)\n...\n[x2]\n"
        #expect(LyricAligner.plainLines(text) == ["The lantern keeps a quiet road", "We count the windows of the rain", "(oh, the rain)"])
        #expect(LyricAligner.plainLines("\n \n").isEmpty)
    }

    @Test("Words are compared without case, accents and punctuation; nearly equal ones pair up")
    func comparing() {
        #expect(LyricAligner.matchWord("Road.") == "road" && LyricAligner.matchWord("don't") == "dont")
        #expect(LyricAligner.matchWord("IŞIKLAR") == LyricAligner.matchWord("ışıklar") && LyricAligner.matchWord("ışıklar") == "isiklar")
        #expect(LyricAligner.matchWord("—") == "")
        #expect(LyricAligner.words(of: "paper-boat, home!") == ["paper", "boat", "home"])
        #expect(LyricAligner.similarity("lantern", "lantern") == 1)
        #expect(LyricAligner.similarity("going", "goin") >= LyricAligner.fuzzyThreshold)
        #expect(LyricAligner.similarity("lantern", "lanterns") >= LyricAligner.fuzzyThreshold)
        #expect(LyricAligner.similarity("rain", "road") < LyricAligner.fuzzyThreshold)
        #expect(LyricAligner.similarity("a", "an") == 0 && LyricAligner.similarity("the", "then") == 0.75)
    }

    @Test("Every line takes the time its first word was sung; every word gets its own")
    func heardInFull() {
        let result = LyricAligner.align(lines: F.lines, words: F.sung(at: F.starts), songDuration: 60)
        #expect(result.quality == .good && result.anchoredLines == 6 && result.totalLines == 6)
        #expect(result.matchedWords == result.totalWords && result.coverage == 1)
        #expect(result.lyrics.lines.map(\.start) == F.starts)
        #expect(result.lyrics.lines.map(\.text) == F.lines)
        let first = result.lyrics.lines[0]
        #expect(first.words.map(\.text) == ["The", "lantern", "keeps", "a", "quiet", "road"])
        #expect(first.words[2].start == 12.8 && abs((first.words[2].end ?? 0) - 13.15) < 1e-9)
        #expect(result.lyrics.hasWordTiming)
    }

    @Test("Misheard, swallowed and added words do not move the lines")
    func misheard() {
        var words = F.heard("the lanterns keep our quiet road", from: 12)       // endings, "a" → "our"
        words += F.heard("oh oh we count the windows of rain", from: 15.2)      // two added, one swallowed
        words += F.heard("paper boat is goin home yeah", from: 20.4)            // the first word swallowed
        words += F.heard("and every harbour learns my name", from: 24)
        words += F.heard("slow engine hums below the snow", from: 28)
        words += F.heard("we count the windows of the rain", from: 40)
        let result = LyricAligner.align(lines: F.lines, words: words)
        #expect(result.quality == .good && result.anchoredLines == 6)
        let starts = result.lyrics.lines.map(\.start)
        #expect(abs(starts[0] - 12) < 0.01)
        #expect(abs(starts[1] - 16) < 0.01, "the added words before the line are not its start")
        // "A" was not heard: it is put one word's length before "paper".
        #expect(starts[2] < 20.4 && starts[2] > 19.8)
        #expect(abs(starts[3] - 24) < 0.01 && abs(starts[4] - 28) < 0.01 && abs(starts[5] - 40) < 0.01)
        #expect(result.matchedWords < result.totalWords && result.coverage > 0.8)
    }

    @Test("A refrain is timed where it is sung, each time")
    func refrain() {
        let result = LyricAligner.align(lines: F.lines, words: F.sung(at: F.starts))
        #expect(result.lyrics.lines[1].start == 16 && result.lyrics.lines[5].start == 40)
        // Only the second time was heard: the first is not given its time.
        let late = F.sung([F.lines[0], F.lines[2], F.lines[3], F.lines[4], F.lines[5]], at: [12, 20, 24, 28, 40])
        let partial = LyricAligner.align(lines: F.lines, words: late)
        #expect(partial.lyrics.lines[5].start == 40)
        #expect(partial.lyrics.lines[1].start > 14 && partial.lyrics.lines[1].start < 20, "between its neighbours")
        #expect(partial.lyrics.lines[1].words.isEmpty, "a line that was not heard has no word times")
        #expect(partial.anchoredLines == 5 && partial.quality == .good)
    }

    @Test("A line the recogniser missed sits between its neighbours, by its length")
    func missedLines() {
        let heard = F.sung([F.lines[0], F.lines[3], F.lines[4]], at: [12, 24, 28])
        let result = LyricAligner.align(lines: Array(F.lines.prefix(5)), words: heard)
        let lines = result.lyrics.lines
        #expect(result.anchoredLines == 3 && result.quality == .rough)
        #expect(lines[0].start == 12 && lines[3].start == 24 && lines[4].start == 28)
        // Two missed lines share the stretch between the first and the fourth.
        #expect(lines[1].start >= (lines[0].end ?? 0) - 0.001 && lines[1].start < lines[2].start && lines[2].start < 24)
        #expect(abs(lines[1].start - 14.35) < 0.01, "from where the first line ends")
        #expect(lines[1].words.isEmpty && lines[2].words.isEmpty && !lines[3].words.isEmpty)
    }

    @Test("After a long instrumental stretch, missed lines lead into the next heard one")
    func longBreak() {
        let heard = F.sung([F.lines[0], F.lines[2]], at: [10, 90])
        let result = LyricAligner.align(lines: Array(F.lines.prefix(3)), words: heard)
        let missed = result.lyrics.lines[1]
        #expect(missed.start > 80 && missed.start < 90, "just before the line at 90 s, not at 12 s")
        #expect(abs((missed.end ?? 0) - 90) < 0.01)
    }

    @Test("Lines before the first and after the last heard one stay in order and inside the song")
    func edges() {
        let heard = F.sung([F.lines[2], F.lines[3]], at: [20, 24])
        let result = LyricAligner.align(lines: F.lines, words: heard, songDuration: 30)
        let starts = result.lyrics.lines.map(\.start)
        #expect(starts == starts.sorted() && Set(starts).count == starts.count)
        #expect(starts[0] >= 0 && starts[1] < 20 && starts[2] == 20 && starts[3] == 24)
        #expect(starts[4] > 24 && starts[5] < 30, "squeezed in before the song ends")
        #expect(result.quality == .rough && result.anchoredLines == 2)
        // With no room before the first heard line, the earlier ones share what there is.
        let tight = LyricAligner.align(lines: Array(F.lines.prefix(3)), words: F.sung([F.lines[2]], at: [1.5]), songDuration: 30)
        #expect(tight.lyrics.lines.map(\.start).allSatisfy { $0 >= 0 } && tight.lyrics.lines[2].start >= 1.5)
    }

    @Test("Audio that starts in the middle of the song gives song positions")
    func laterAudio() {
        // The recogniser's times count from the start of what was heard.
        let heard = F.sung(Array(F.lines.suffix(3)), at: [4, 8, 20])
        let result = LyricAligner.align(lines: F.lines, words: heard, audioStart: 60, audioEnd: 90, songDuration: 90)
        #expect(result.lyrics.lines[3].start == 64 && result.lyrics.lines[4].start == 68 && result.lyrics.lines[5].start == 80)
        #expect(result.lyrics.lines[3].words[1].start == 64.4)
        // The first half was not heard: its lines are placed before, in order.
        #expect(result.lyrics.lines[2].start < 64 && result.lyrics.lines[0].start < result.lyrics.lines[1].start)
        #expect(result.quality == .rough && result.anchoredLines == 3)
    }

    @Test("Another song's words, or nothing heard, is a failure and keeps the lines in order")
    func failures() {
        let other = F.heard("green umbrellas wander past the station clock again tonight", from: 5)
            + F.heard("nobody asked the ferry where the morning went", from: 12)
        let wrong = LyricAligner.align(lines: F.lines, words: other, songDuration: 60)
        #expect(wrong.quality == .failed && wrong.anchoredLines == 0 && wrong.matchedWords == 0)
        let silent = LyricAligner.align(lines: F.lines, words: [], songDuration: 60)
        #expect(silent.quality == .failed && silent.lyrics.lines.count == 6)
        #expect(silent.lyrics.lines.map(\.start) == silent.lyrics.lines.map(\.start).sorted())
        #expect((silent.lyrics.lines.last?.end ?? 99) <= 60.001, "spread over the song")
        #expect(LyricAligner.align(lines: [], words: other).quality == .failed)
        // One common word heard somewhere proves nothing.
        let stray = LyricAligner.align(lines: F.lines, words: F.heard("the", from: 3) + other)
        #expect(stray.matchedWords == 0 && stray.quality == .failed)
    }

    @Test("Turkish lines match what a recogniser writes without the dots and tails")
    func turkish() {
        let lines = ["Işıklar söner, şehir uyur", "Çatılarda rüzgâr dolaşır", "Gözümde eski bir vapur"]
        let heard = F.heard("isiklar soner sehir uyur", from: 8) + F.heard("ÇATILARDA RÜZGAR DOLAŞIR", from: 12) + F.heard("gözümde eski bir vapur", from: 16)
        let result = LyricAligner.align(lines: lines, words: heard)
        #expect(result.quality == .good && result.matchedWords == result.totalWords)
        #expect(result.lyrics.lines.map(\.start) == [8, 12, 16])
        #expect(result.lyrics.lines[0].words.map(\.text) == ["Işıklar", "söner,", "şehir", "uyur"], "shown as written")
    }

    @Test("Whatever was heard, the lines stay in order and never share a start")
    func alwaysInOrder() {
        var generator = SystemRandomNumberGenerator()
        let vocabulary = F.lines.flatMap { $0.split(separator: " ").map(String.init) } + ["oh", "yeah", "la", "night", "rain"]
        for _ in 0..<40 {
            var time = 0.0
            let heard: [RecognizedWord] = (0..<Int.random(in: 0...60, using: &generator)).map { _ in
                time += Double.random(in: 0.05...3, using: &generator)
                return RecognizedWord(text: vocabulary.randomElement(using: &generator)!, start: time, end: time + 0.3)
            }
            let result = LyricAligner.align(lines: F.lines, words: heard, songDuration: 200)
            let starts = result.lyrics.lines.map(\.start)
            #expect(result.lyrics.lines.count == F.lines.count)
            #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 }, "\(starts)")
            #expect(starts.allSatisfy { $0 >= 0 && $0.isFinite })
            for line in result.lyrics.lines {
                #expect((line.end ?? .infinity) > line.start)
                #expect(line.words.allSatisfy { $0.start >= line.start })
            }
        }
    }

    @Test("Aligned lyrics are kept like a picked version and come back with the song")
    func adopted() async {
        let scratch = ScratchDirectory()
        let provider = ScriptedLyricsProvider("A") { _ in LyricsResponse(result: .plain(F.lines.joined(separator: "\n")), source: "A") }
        let finder = LyricsFinder(chain: LyricsChain(providers: [provider]), cache: LyricsCache(directory: scratch.url), songs: LyricsSongStore(fileURL: nil))
        let query = LyricsQuery(title: "Paper Boat", artist: "The Tin Orchard", duration: 60)
        guard case .plain = await finder.find(query).response.result else { Issue.record("expected plain words"); return }

        let aligned = LyricAligner.align(lines: F.lines, words: F.sung(at: F.starts), songDuration: 60).lyrics
        let adopted = await finder.adopt(aligned, for: query)
        #expect(adopted.version.provider == LyricsFinder.alignedSource && adopted.version.kind == .synced)
        let found = await finder.find(query)
        #expect(found.origin == .choice && found.choice == adopted.version)
        #expect(found.response.result == .synced(aligned) && found.response.source == "aligned")
        #expect(!found.response.timingAuthority.allowsAutomaticCorrection, "timed on this recording")
        // A fresh finder over the same cache (the next launch) with the pick remembered.
        let songs = LyricsSongStore(fileURL: nil)
        songs.setChoice(adopted.version, for: query.cacheKey)
        let later = LyricsFinder(chain: LyricsChain(providers: [provider]), cache: LyricsCache(directory: scratch.url), songs: songs)
        #expect(await later.find(query).response.result == .synced(aligned))
        // "Use the lyrics Ahenk found" drops them.
        await finder.clearChoice(for: query)
        guard case .plain = await finder.find(query).response.result else { Issue.record("the plain words should be back"); return }
    }
}

@Suite("Whisper tools")
struct WhisperToolsTests {
    /// A locator over invented folders.
    private func locator(_ files: [String], executables: [String] = []) -> WhisperLocator {
        let all = Set(files + executables)
        let runnable = Set(executables)
        return WhisperLocator(
            home: "/Users/tester",
            isExecutable: { runnable.contains($0) },
            isFile: { all.contains($0) },
            contents: { folder in all.filter { ($0 as NSString).deletingLastPathComponent == folder }.map { ($0 as NSString).lastPathComponent } }
        )
    }

    @Test("The tool and the best model are found where they usually are")
    func found() {
        let tools = locator(
            [
                "/Users/tester/Developer/whisper-models/ggml-base.en.bin", "/Users/tester/Developer/whisper-models/ggml-large-v3-turbo-q5_0.bin",
                "/Users/tester/Developer/whisper-models/notes.txt", "/opt/homebrew/share/whisper-cpp/models/ggml-tiny.bin",
            ],
            executables: ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cpp"]
        ).locate()
        #expect(tools.isReady && tools.missing.isEmpty)
        #expect(tools.executable?.path == "/opt/homebrew/bin/whisper-cli")
        #expect(tools.model?.path == "/Users/tester/Developer/whisper-models/ggml-large-v3-turbo-q5_0.bin")
    }

    @Test("What is missing is said, part by part")
    func missing() {
        #expect(locator([]).locate().missing == [.executable, .model])
        let noModel = locator(["/Users/tester/Developer/whisper-models/readme.md"], executables: ["/usr/local/bin/whisper-cpp"]).locate()
        #expect(noModel.executable?.path == "/usr/local/bin/whisper-cpp" && noModel.missing == [.model] && !noModel.isReady)
        let noTool = locator(["/Users/tester/Library/Application Support/Ahenk/Models/ggml-small.bin", "/opt/homebrew/bin/whisper-cli"]).locate()
        #expect(noTool.missing == [.executable], "a file that cannot be run is no tool")
        #expect(noTool.model?.lastPathComponent == "ggml-small.bin")
    }

    @Test("The user's own choices come first; a choice that is gone falls back to the search")
    func overrides() {
        let finder = locator(
            ["/Users/tester/models/ggml-medium.bin", "/Users/tester/Developer/whisper-models/ggml-large-v3.bin"],
            executables: ["/opt/homebrew/bin/whisper-cli", "/Users/tester/tools/whisper-cli"]
        )
        let chosen = finder.locate(executableOverride: "~/tools/whisper-cli", modelOverride: " /Users/tester/models/ggml-medium.bin ")
        #expect(chosen.executable?.path == "/Users/tester/tools/whisper-cli" && chosen.model?.path == "/Users/tester/models/ggml-medium.bin")
        let gone = finder.locate(executableOverride: "/nowhere/whisper-cli", modelOverride: "~/gone.bin")
        #expect(gone.executable?.path == "/opt/homebrew/bin/whisper-cli" && gone.model?.lastPathComponent == "ggml-large-v3.bin")
        #expect(finder.locate(executableOverride: "", modelOverride: nil).isReady)
    }

    @Test("Models are ranked: larger first, every language before English only, full before compressed")
    func ranks() {
        let ordered = [
            "ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3.bin", "ggml-large-v3-q5_0.bin", "ggml-large-v2.bin",
            "ggml-medium.bin", "ggml-medium.en.bin", "ggml-small.bin", "ggml-small.en-q5_1.bin", "ggml-base.bin", "ggml-tiny.bin", "ggml-tiny.en.bin",
        ]
        let ranks = ordered.compactMap(WhisperLocator.rank(ofModel:))
        #expect(ranks.count == ordered.count && ranks == ranks.sorted() && Set(ranks).count == ranks.count)
        for name in ["notes.txt", "ggml-silero-v5.1.2.bin", "ggml-vad.bin", "model.bin", "ggml-large-v3-turbo-encoder.mlmodelc", "for-tests-ggml-base.bin"] {
            #expect(WhisperLocator.rank(ofModel: name) == nil, "\(name)")
        }
        #expect(WhisperLocator.rank(ofModel: WhisperLocator.suggestedModel) != nil)
        #expect(WhisperLocator.suggestedModelURL.lastPathComponent == WhisperLocator.suggestedModel)
    }

    @Test("The command line asks for a word per segment as JSON; progress lines are read")
    func commandLine() {
        let arguments = WhisperRunner.arguments(
            model: URL(fileURLWithPath: "/m/ggml-base.bin"), audio: URL(fileURLWithPath: "/t/song.wav"), outputBase: URL(fileURLWithPath: "/t/song.heard")
        )
        #expect(arguments == ["-m", "/m/ggml-base.bin", "-f", "/t/song.wav", "-l", "auto", "--output-json-full", "--output-file", "/t/song.heard",
                              "--max-len", "1", "--split-on-word", "--print-progress"])
        #expect(WhisperRunner.progress(inLine: "whisper_print_progress_callback: progress =  40%") == 0.4)
        #expect(WhisperRunner.progress(inLine: "progress = 100%") == 1)
        #expect(WhisperRunner.progress(inLine: "whisper_init_from_file_with_params_no_state: loading model") == nil)
    }
}

@Suite("Whisper audio")
struct WhisperAudioTests {
    @Test("Captured audio is brought to 16 kHz with its pitch intact")
    func resampling() {
        let rate = 14_700.0
        let tone = SyntheticSignal.sine(frequency: 220, seconds: 1, sampleRate: rate, amplitude: 0.5)
        let resampled = WhisperAudio.resample(tone, from: rate)
        #expect(resampled.count == 16_000)
        // 220 Hz crosses zero upwards 220 times a second, at any rate.
        let crossings = zip(resampled, resampled.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 220) <= 1)
        #expect(WhisperAudio.resample(tone, from: 16_000) == tone, "already at 16 kHz")
        #expect(WhisperAudio.resample([], from: rate).isEmpty && WhisperAudio.resample(tone, from: 0).isEmpty)
        #expect(WhisperAudio.resample(tone, from: 48_000).count == 4_900)
    }

    @Test("The WAV file is 16 kHz mono 16-bit, and quiet audio is brought up")
    func wav() throws {
        let quiet = SyntheticSignal.sine(frequency: 220, seconds: 0.5, sampleRate: 16_000, amplitude: 0.05)
        let data = WhisperAudio.wavData(quiet)
        #expect(data.count == 44 + 8_000 * 2)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        func field<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            data.subdata(in: offset..<(offset + MemoryLayout<T>.size)).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        #expect(field(22, UInt16.self) == 1 && field(24, UInt32.self) == 16_000 && field(34, UInt16.self) == 16)
        #expect(field(40, UInt32.self) == 16_000)
        let peak = (0..<8_000).map { abs(Int(field(44 + $0 * 2, Int16.self))) }.max() ?? 0
        #expect(peak > 20_000 && peak < 25_000, "0.05 was brought up to about 0.7")
        let scratch = ScratchDirectory()
        let url = scratch.url.appendingPathComponent("heard.wav")
        try WhisperAudio.write(SyntheticSignal.sine(frequency: 220, seconds: 1, sampleRate: 48_000, amplitude: 0.6), rate: 48_000, to: url)
        #expect(try Data(contentsOf: url).count == 44 + 16_000 * 2)
        #expect(throws: WhisperAudio.Failure.self) { try WhisperAudio.write([], rate: 48_000, to: url) }
    }

    @Test("A song file is read into the same form")
    func songFile() async throws {
        let scratch = ScratchDirectory()
        let song = scratch.url.appendingPathComponent("tone.m4a")
        try await GeneratedSongFiles.writeM4A(
            GeneratedSongFiles.tone(seconds: 2, sampleRate: 44_100), sampleRate: 44_100, to: song, title: "Generated", artist: "Ahenk Tones", album: nil
        )
        let wav = scratch.url.appendingPathComponent("tone.wav")
        let seconds = try await WhisperAudio.convert(song, to: wav)
        #expect(abs(seconds - 2) < 0.15)
        let data = try Data(contentsOf: wav)
        #expect(abs(data.count - (44 + 2 * 16_000 * 2)) < 5_000)
        await #expect(throws: WhisperAudio.Failure.self) {
            try await WhisperAudio.convert(scratch.url.appendingPathComponent("missing.m4a"), to: wav)
        }
    }

    /// The whole way with the real tool, when this Mac has it: invented
    /// lines spoken by the system voice into a file (never played),
    /// recognised by whisper and timed.
    @Test("Spoken invented lines are recognised and timed by the real tool", .enabled(if: WhisperLocator.system.locate().isReady))
    func realTool() async throws {
        let tools = WhisperLocator.system.locate()
        let scratch = ScratchDirectory()
        let lines = ["The lantern keeps a quiet road", "We count the windows of the rain", "A paper boat is going home"]
        let spoken = scratch.url.appendingPathComponent("lines.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", spoken.path, lines.joined(separator: ". [[slnc 900]] ") + "."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)
        let wav = scratch.url.appendingPathComponent("lines.wav")
        let seconds = try await WhisperAudio.convert(spoken, to: wav)
        let transcript = try await WhisperRunner(executable: tools.executable!, model: tools.model!).transcribe(wav)
        let result = LyricAligner.align(lines: lines, words: transcript.words, songDuration: seconds)
        #expect(result.quality == .good && result.anchoredLines == 3, "heard: \(transcript.words.map(\.text))")
        let starts = result.lyrics.lines.map(\.start)
        #expect(starts[0] < 1 && starts[1] > starts[0] + 1.5 && starts[2] > starts[1] + 1.5 && starts[2] < seconds)
    }
}
