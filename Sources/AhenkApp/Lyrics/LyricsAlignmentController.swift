import AhenkKit
import AppKit
import Observation

/// "Align lyrics to the song" (Beta): plain lyrics (found by the providers,
/// picked from a search, or pasted) are timed against the song on this
/// Mac. whisper.cpp recognises the sung words with their times and
/// `LyricAligner` gives every line the time of its first word; the result
/// becomes the song's synced lyrics and is kept like a picked version.
///
/// - **Song files** (Ahenk's own player): the file itself is read.
/// - **Another app**: there is no file, so Ahenk listens to the rest of the
///   song through the tap it already has (the analysis' audio, in memory),
///   and aligns what it heard. A pause or a seek meanwhile ends the try.
/// - **The demo**: no audio at all; the demo song's own timing plays the
///   part of the recogniser, so the panel can be seen at work.
///
/// Nothing leaves this Mac. The tool and a model must be on it already
/// (`WhisperLocator`); the only download is the model, and only when the
/// user presses its button.
@MainActor
@Observable
final class LyricsAlignmentController {
    enum Stage: Equatable {
        case idle
        /// Listening to another app's song: seconds so far, and wanted.
        case listening(collected: Double, wanted: Double)
        /// Reading a song file.
        case reading
        /// whisper is at work (0...1).
        case recognizing(Double)
        case done(lines: Int, of: Int, isRough: Bool)
        /// A message for the listener.
        case failed(String)
    }

    enum Download: Equatable {
        case none
        case running(Double)
        case failed
    }

    private(set) var stage: Stage = .idle
    private(set) var tools = WhisperTools(executable: nil, model: nil)
    private(set) var download: Download = .none
    /// The words to time, one line under the other (the panel's editor).
    var text = ""

    @ObservationIgnored private let lyrics: LyricsController
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private let audio: AudioTapEngine
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var capture: LyricsSyncCapture?
    @ObservationIgnored private var listening: (snapshot: NowPlayingSnapshot, query: LyricsQuery, lines: [String], startedAt: Date, wanted: Double)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var preparedFor: String?
    @ObservationIgnored private var downloader: ModelDownloader?
    private let log = AhenkLogger(category: "lyrics-align")

    /// Less than this of a song is not worth recognising.
    static let minimumSeconds = 20.0
    /// With no length known, listen this long at most.
    static let longestListen = 360.0

    init(lyrics: LyricsController, nowPlaying: NowPlayingModel, audio: AudioTapEngine, settings: AppSettings, isDemo: Bool) {
        self.lyrics = lyrics
        self.nowPlaying = nowPlaying
        self.audio = audio
        self.settings = settings
        self.isDemo = isDemo
    }

    // MARK: The panel

    /// The panel opened: look for the tools, and put the song's words in
    /// the editor (once per song; what the user typed stays).
    func prepare() {
        refreshTools()
        let song = lyrics.query?.cacheKey
        if preparedFor != song {
            preparedFor = song
            text = lyrics.wordsToAlign.joined(separator: "\n")
            if !isBusy { stage = .idle }
        }
    }

    func refreshTools() {
        tools = WhisperLocator.system.locate(
            executableOverride: settings.lyrics.whisperExecutablePath, modelOverride: settings.lyrics.whisperModelPath
        )
    }

    var isBusy: Bool {
        switch stage {
        case .listening, .reading, .recognizing: true
        case .idle, .done, .failed: false
        }
    }

    /// The song comes from another app, so it has to be listened to.
    var listensToTheSong: Bool {
        guard let snapshot = nowPlaying.snapshot else { return false }
        return snapshot.track.source != .local && !isDemo
    }

    var lineCount: Int { LyricAligner.plainLines(text).count }

    var canStart: Bool { !isBusy && lineCount >= 2 && (isDemo || tools.isReady) }

    /// Enough was heard to align with what there is.
    var canFinishListening: Bool {
        if case .listening(let collected, _) = stage { return collected >= Self.minimumSeconds }
        return false
    }

    // MARK: Starting and stopping

    func start() {
        guard !isBusy else { return }
        let lines = LyricAligner.plainLines(text)
        guard lines.count >= 2 else {
            stage = .failed("Type or paste at least two lines of the song.".l10n)
            return
        }
        guard let snapshot = nowPlaying.snapshot, let query = lyrics.query else {
            stage = .failed("No song is playing.".l10n)
            return
        }
        if isDemo {
            runDemo(lines: lines, snapshot: snapshot, query: query)
            return
        }
        refreshTools()
        guard let executable = tools.executable, let model = tools.model else { return }
        let runner = WhisperRunner(executable: executable, model: model)
        if snapshot.track.source == .local {
            alignFile(URL(fileURLWithPath: snapshot.track.id), lines: lines, snapshot: snapshot, query: query, runner: runner)
        } else {
            listen(to: snapshot, lines: lines, query: query)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopListening()
        if isBusy { stage = .idle }
    }

    /// Stops everything (on quit).
    func stop() {
        cancel()
        downloader?.cancel()
        downloader = nil
    }

    private func fail(_ message: String) {
        stopListening()
        stage = .failed(message)
        log.notice("Lyric alignment gave up: \(message)")
    }

    // MARK: A song file

    private func alignFile(_ file: URL, lines: [String], snapshot: NowPlayingSnapshot, query: LyricsQuery, runner: WhisperRunner) {
        stage = .reading
        let duration = snapshot.track.duration
        task = Task { [weak self] in
            let wav = Self.temporaryFile()
            defer { try? FileManager.default.removeItem(at: wav) }
            let seconds: Double
            do {
                seconds = try await WhisperAudio.convert(file, to: wav)
            } catch {
                if !Task.isCancelled { self?.fail("The song file could not be read.".l10n) }
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recognize(wav, runner: runner, lines: lines, query: query, audioStart: 0, audioEnd: seconds, duration: duration > 0 ? duration : seconds)
        }
    }

    // MARK: Another app's song

    private func listen(to snapshot: NowPlayingSnapshot, lines: [String], query: LyricsQuery) {
        guard audio.hearsFollowedPlayer else {
            fail("Ahenk has to hear this app to time the words. Allow listening in Settings › Sound.".l10n)
            return
        }
        guard snapshot.isPlaying, abs(snapshot.playbackRate - 1) < 0.01 else {
            fail("Play the song at its normal speed, then try again.".l10n)
            return
        }
        let position = snapshot.elapsed(at: Date())
        let duration = snapshot.track.duration
        let wanted = duration > 0 ? min(Self.longestListen, duration - position - 1.5) : Self.longestListen
        guard wanted >= Self.minimumSeconds else {
            fail("Too little of the song is left. Start it over and try again.".l10n)
            return
        }
        let capture = LyricsSyncCapture(seconds: wanted) { [weak self] finished in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(finished) } }
        }
        self.capture = capture
        listening = (snapshot, query, lines, Date(), wanted)
        audio.listen(forLyrics: capture)
        stage = .listening(collected: 0, wanted: wanted)
        log.info("Listening to \(Int(wanted)) s of the song to time \(lines.count) lines")
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listeningTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func listeningTick() {
        guard let listening, capture != nil else { return }
        let elapsed = Date().timeIntervalSince(listening.startedAt)
        guard let now = nowPlaying.snapshot, now.track.isSameSong(as: listening.snapshot.track) else {
            // The song ended (or another one started): align what was heard.
            finishListening()
            return
        }
        if elapsed > listening.wanted + 8 {
            finishListening()
            return
        }
        stage = .listening(collected: min(elapsed, listening.wanted), wanted: listening.wanted)
    }

    /// "Align Now": stop listening and align what was heard so far.
    func finishListening() {
        guard let capture, timer != nil else { return }
        timer?.invalidate()
        timer = nil
        audio.stopListening { [weak self] in self?.heard(capture) }
    }

    private func stopListening() {
        timer?.invalidate()
        timer = nil
        if capture != nil { audio.listen(forLyrics: nil) }
        capture = nil
        listening = nil
    }

    /// The capture is complete (or was ended): check that the song played
    /// straight through it, then recognise.
    private func heard(_ finished: LyricsSyncCapture) {
        guard finished === capture, let listening else { return }
        timer?.invalidate()
        timer = nil
        capture = nil
        self.listening = nil
        guard let start = finished.startHostTime, finished.duration >= Self.minimumSeconds else {
            fail("Too little of the song was heard. Let it play longer.".l10n)
            return
        }
        let seconds = finished.duration
        let startDate = Date().addingTimeInterval(start - AudioClock.now())
        let position = listening.snapshot.elapsed(at: startDate)
        let track = listening.snapshot.track
        let reachedEnd = track.duration > 0 && position + seconds >= track.duration - 4
        if let now = nowPlaying.snapshot, now.track.isSameSong(as: track) {
            // Where the song was when the last sample played, as it says now.
            let actual = now.elapsed(at: startDate.addingTimeInterval(seconds))
            guard abs(actual - (position + seconds)) < 2 || reachedEnd else {
                fail("The song was paused or moved while Ahenk was listening. Let it play through and try again.".l10n)
                return
            }
        } else if !reachedEnd {
            fail("The song changed while Ahenk was listening.".l10n)
            return
        }
        guard let executable = tools.executable, let model = tools.model else { return }
        let runner = WhisperRunner(executable: executable, model: model)
        let samples = finished.samples
        let rate = finished.sampleRate
        stage = .recognizing(0)
        task = Task { [weak self] in
            let wav = Self.temporaryFile()
            defer { try? FileManager.default.removeItem(at: wav) }
            do {
                try await Task.detached(priority: .userInitiated) { try WhisperAudio.write(samples, rate: rate, to: wav) }.value
            } catch {
                self?.fail("Too little of the song was heard. Let it play longer.".l10n)
                return
            }
            await self?.recognize(
                wav, runner: runner, lines: listening.lines, query: listening.query, audioStart: max(0, position),
                audioEnd: position + seconds, duration: track.duration > 0 ? track.duration : nil
            )
        }
    }

    // MARK: Recognising and timing

    private func recognize(
        _ wav: URL, runner: WhisperRunner, lines: [String], query: LyricsQuery, audioStart: Double, audioEnd: Double, duration: Double?
    ) async {
        stage = .recognizing(0)
        let started = Date()
        let transcript: WhisperTranscript
        do {
            transcript = try await runner.transcribe(wav) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .recognizing = self.stage else { return }
                    self.stage = .recognizing(progress)
                }
            }
        } catch {
            if !Task.isCancelled {
                log.error("whisper failed: \(error)")
                fail("The words could not be recognised (whisper did not finish).".l10n)
            }
            return
        }
        guard !Task.isCancelled else { return }
        let heard = transcript.words
        let result = await Task.detached(priority: .userInitiated) {
            LyricAligner.align(lines: lines, words: heard, audioStart: audioStart, audioEnd: audioEnd, songDuration: duration)
        }.value
        log.notice("Recognised \(heard.count) words of \(Int(audioEnd - audioStart)) s in \(String(format: "%.1f", Date().timeIntervalSince(started))) s "
            + "(\(transcript.language ?? "?")): \(result.anchoredLines) of \(result.totalLines) lines found, \(result.quality.rawValue)")
        await finish(result, query: query)
    }

    private func finish(_ result: LyricAlignment, query: LyricsQuery) async {
        guard result.quality != .failed else {
            fail(L10n.format("These words were not found in the song (%1$d of %2$d lines). Check that they are this song's lyrics.", result.anchoredLines, result.totalLines))
            return
        }
        await lyrics.adoptAligned(result.lyrics, for: query)
        stage = .done(lines: result.anchoredLines, of: result.totalLines, isRough: result.quality == .rough)
        task = nil
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-align-\(UUID().uuidString).wav")
    }

    // MARK: The demo

    /// The demo has nothing to listen to: the demo song's own lines, with
    /// their times, stand in for what a recogniser would have heard, and
    /// the real aligner times the words in the editor against them.
    private func runDemo(lines: [String], snapshot: NowPlayingSnapshot, query: LyricsQuery) {
        let source = lyrics.lyrics ?? SyncedLyrics(lines: [])
        let heard = Self.asHeard(source)
        let duration = snapshot.track.duration
        stage = .listening(collected: 0, wanted: 12)
        task = Task { [weak self] in
            for step in 1...6 {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.stage = .listening(collected: Double(step) * 2, wanted: 12)
            }
            for step in 0...8 {
                self?.stage = .recognizing(Double(step) / 8)
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }
            let result = LyricAligner.align(lines: lines, words: heard, songDuration: duration > 0 ? duration : nil)
            await self?.finish(result, query: query)
        }
    }

    /// Synced lyrics as a recogniser would report them: each line's words
    /// one after another from the line's start.
    static func asHeard(_ lyrics: SyncedLyrics) -> [RecognizedWord] {
        var heard: [RecognizedWord] = []
        for (index, line) in lyrics.lines.enumerated() {
            let words = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let next = index + 1 < lyrics.lines.count ? lyrics.lines[index + 1].start : line.start + 4
            let length = min(0.45, max(0.12, (min(line.end ?? next, next) - line.start) / Double(words.count)))
            for (position, word) in words.enumerated() {
                let start = line.start + Double(position) * length
                heard.append(RecognizedWord(text: word, start: start, end: start + length * 0.9))
            }
        }
        return heard
    }

    /// Shows a stage as it is (demo scenes and snapshots).
    func show(_ stage: Stage) {
        self.stage = stage
    }

    // MARK: The tool and the model

    func chooseExecutable() {
        guard let url = Self.pickFile(message: "Choose whisper-cli (whisper.cpp's command line tool).".l10n) else { return }
        settings.lyrics.whisperExecutablePath = url.path
        refreshTools()
    }

    func chooseModel() {
        guard let url = Self.pickFile(message: "Choose a whisper.cpp model file (ggml-….bin).".l10n) else { return }
        settings.lyrics.whisperModelPath = url.path
        refreshTools()
    }

    private static func pickFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    static let installCommand = "brew install whisper-cpp"

    /// Where Ahenk keeps a model it downloaded.
    nonisolated static var modelsFolder: URL {
        URL(fileURLWithPath: WhisperLocator.modelsFolder(home: FileManager.default.homeDirectoryForCurrentUser.path), isDirectory: true)
    }

    /// The download button: fetches the suggested model into Ahenk's own
    /// folder. Only ever called from that button.
    func downloadModel(from source: URL = WhisperLocator.suggestedModelURL, into folder: URL = LyricsAlignmentController.modelsFolder) {
        guard downloader == nil else { return }
        download = .running(0)
        log.notice("Downloading the speech model (the user pressed the button): \(source.lastPathComponent)")
        let downloader = ModelDownloader(source: source, destination: folder.appendingPathComponent(source.lastPathComponent))
        self.downloader = downloader
        downloader.start { [weak self] progress in
            Task { @MainActor in
                guard let self, case .running = self.download else { return }
                self.download = .running(progress)
            }
        } completion: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.downloader = nil
                if let error {
                    self.log.error("The model could not be downloaded: \(error)")
                    self.download = .failed
                } else {
                    self.download = .none
                    self.refreshTools()
                }
            }
        }
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        download = .none
    }
}

/// Fetches one file to a place on disk, reporting how far it is. Used for
/// the speech model, and only after the user pressed its button.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let source: URL
    let destination: URL
    private var session: URLSession?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var completion: (@Sendable (Error?) -> Void)?
    private var moved: Error?

    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    func start(onProgress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Error?) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: source).resume()
    }

    func cancel() {
        completion = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone when this returns: move it now.
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moved = Failure(description: "the server answered \(response.statusCode)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moved = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = self.completion
        self.completion = nil
        session.finishTasksAndInvalidate()
        completion?(error ?? moved)
    }
}
