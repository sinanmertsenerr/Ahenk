import AhenkKit
import AppKit

/// Keeps the lines on time by listening (Settings › Lyrics › Sync
/// automatically): while a song with synced lyrics plays and nothing has
/// been measured or set for it, the analysed audio of the followed player
/// is lent for a window of 12–32 seconds; the vocal onsets in it are lined
/// up against the lyric lines' starts (`LyricOffsetEstimator`). Only when
/// two separate windows agree is the song's offset stored (with the lyrics'
/// fingerprint); a single window never changes anything, and at most four
/// windows are tried per song and run.
///
/// A music video on YouTube or YouTube Music is another recording than the
/// one the catalogs time: after an intro every line is seconds early, far
/// more than the onsets can tell (they look two seconds either way). So a
/// video is first heard for its words: ten seconds at a time go to whisper
/// (when the tool and a model are on this Mac), one window straight after
/// the other, and where the words fall says how far the video runs from the
/// lyrics (`LyricShiftEstimator`). Each window adds to what was heard, and
/// the first that makes the answer sure ends the listening: more than a
/// second and a half, and the lyrics moved by that much become the song's,
/// kept like lyrics aligned on this Mac; less, and the onsets take over. Up
/// to twelve such windows per song and run (two minutes of the video).
///
/// A window the song jumped in is not used: after a seek it is dropped at
/// once and the next one starts there; a stall shows at the window's end.
///
/// Never runs on a tap that hears every app (the fallback), never for
/// lyrics a provider proved for the exact recording, never over the user's
/// own nudge. The audio stays in memory until measured (a video's window is
/// a file for whisper while it is read, then removed).
@MainActor
final class LyricsAutoSync {
    private let lyrics: LyricsController
    private let nowPlaying: NowPlayingModel
    private let audio: AudioTapEngine
    private let settings: AppSettings
    private var sessions: [String: LyricsSyncSession] = [:]
    private var capture: LyricsSyncCapture?
    private var context: Context?
    private var watchdog: DispatchWorkItem?
    private var observers: [AnyObject] = []
    private var isStarted = false
    /// True while something else has the audio (lyric alignment).
    var isSuspended: () -> Bool = { false }
    /// False while the Mac should run lighter (Low Power Mode, heat): a
    /// video's words are not recognised then.
    var mayRecognize: () -> Bool = { true }
    /// What was heard of a video's words, per song and timeline.
    private var hearings: [String: Hearing] = [:]
    /// whisper is reading a window…
    private var isRecognizing = false
    /// …and these wait for it, oldest first.
    private var readings: [Reading] = []
    private let work = DispatchQueue(label: "com.sinanmertsener.Ahenk.lyrics-sync", qos: .utility)
    private let log = AhenkLogger(category: "lyrics-sync")

    /// What a capture belongs to.
    private struct Context {
        let session: String
        let trackID: String
        let starts: [Double]
        let fingerprint: String
        let key: String
        /// The song as the capture began (to notice a seek or a pause).
        let snapshot: NowPlayingSnapshot
        /// A window for a video's words: the lyrics they are looked up in.
        var words: (lyrics: SyncedLyrics, query: LyricsQuery, runner: WhisperRunner)?
    }

    /// A window of a video's sound on its way to whisper.
    private struct Reading {
        let samples: [Float]
        let rate: Double
        /// The song's position at the first sample.
        let position: Double
        let context: Context
    }

    /// A video's words so far.
    private struct Hearing {
        /// Windows begun (a seek or a pause spoils one)…
        var attempts = 0
        /// …windows collected that whisper has not read yet…
        var waiting = 0
        /// …and windows whisper read.
        var windows = 0
        /// At the song's own positions.
        var words: [RecognizedWord] = []
        /// No further window is begun.
        var isSettled = false
        /// The words said how the video runs; nothing more is read.
        var isAnswered = false
    }

    /// A window for a video's words, and how many of them at most. Short
    /// windows: the answer comes with the first few sung lines, and a jump
    /// in the song costs ten seconds.
    static let hearingSeconds = 10.0
    static let shortestHearing = 6.0
    static let maximumHearings = 12
    static let maximumHearingAttempts = 30
    /// A song's position this far from where a window expected it has
    /// jumped: the window's sound no longer says when it played.
    static let largestSlip = 0.3
    /// Words are looked up three quarters of a second either way, so their
    /// window bears twice the slip, timed from the middle of it: no further
    /// off than an onset window may be.
    static let largestHearingSlip = 0.6
    /// A slip this large is a seek (or the page correcting where a new
    /// song stands): the window is dropped without waiting for its end.
    static let seekSlip = 1.0
    /// A video this close to the lyrics' timing is left to the onsets.
    static let smallestShift = 1.5

    init(lyrics: LyricsController, nowPlaying: NowPlayingModel, audio: AudioTapEngine, settings: AppSettings) {
        self.lyrics = lyrics
        self.nowPlaying = nowPlaying
        self.audio = audio
        self.settings = settings
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let lyrics = self.lyrics
        let nowPlaying = self.nowPlaying
        let settings = self.settings
        let audio = self.audio
        observers.append(ChangeObserver({
            Trigger(
                enabled: settings.lyrics.autoSync, phase: lyrics.phase, fingerprint: lyrics.lyrics?.timingFingerprint,
                manual: lyrics.manualOffset, measured: lyrics.autoOffset, playing: nowPlaying.snapshot?.isPlaying ?? false,
                anchor: nowPlaying.snapshot?.timestamp, listening: audio.hearsFollowedPlayer
            )
        }) { [weak self] _ in
            self?.evaluate()
        })
        evaluate()
    }

    func stop() {
        isStarted = false
        observers = []
        cancel()
    }

    private struct Trigger: Equatable {
        var enabled: Bool
        var phase: LyricsController.Phase
        var fingerprint: String?
        var manual: Double?
        var measured: Double?
        var playing: Bool
        var anchor: Date?
        var listening: Bool
    }

    /// Starts a window when everything allows one; stops one that no
    /// longer can finish.
    private func evaluate() {
        guard settings.lyrics.autoSync, lyrics.phase == .synced, let synced = lyrics.lyrics, let query = lyrics.query,
              lyrics.timingAuthority.allowsAutomaticCorrection, lyrics.manualOffset == nil, lyrics.autoOffset == nil,
              let snapshot = nowPlaying.snapshot, snapshot.isPlaying, abs(snapshot.playbackRate - 1) < 0.01,
              audio.hearsFollowedPlayer, !isSuspended()
        else {
            cancel()
            return
        }
        let key = query.cacheKey
        let fingerprint = synced.timingFingerprint
        let sessionKey = key + "\u{1}" + fingerprint
        if let context, context.session != sessionKey || context.snapshot.track.id != snapshot.track.id { cancel() }
        // A seek is seen as it happens: the rest of the window is not waited for.
        if let context, capture != nil {
            let now = Date()
            let slip = snapshot.elapsed(at: now) - context.snapshot.elapsed(at: now)
            if abs(slip) >= Self.seekSlip {
                log.info("The song moved \(String(format: "%+.1f", slip)) s during a sync window; the window is dropped")
                cancel()
            }
        }
        var session = sessions[sessionKey] ?? LyricsSyncSession(key: key, fingerprint: fingerprint)
        if sessions[sessionKey] == nil {
            if sessions.count > 64 { sessions = [:] }
            sessions[sessionKey] = session
        }
        guard capture == nil else { return }
        let starts = synced.lines.filter { LyricsTimeline.isSung($0.text) }.map(\.start)
        let position = snapshot.elapsed(at: Date())
        if Self.isVideo(snapshot), hearings[sessionKey]?.isSettled != true {
            if let (seconds, runner) = hearingWindow(sessionKey, from: position, snapshot: snapshot) {
                var context = Context(session: sessionKey, trackID: snapshot.track.id, starts: starts, fingerprint: fingerprint, key: key, snapshot: snapshot)
                context.words = (synced, query, runner)
                begin(seconds: seconds, context: context)
                let window = (hearings[sessionKey]?.windows ?? 0) + (hearings[sessionKey]?.waiting ?? 0) + 1
                log.info("Listening for \(Int(seconds.rounded())) s to hear where the video's words fall (window \(window) of \(Self.maximumHearings))")
                return
            }
        }
        // The onsets wait while whisper reads.
        guard !isRecognizing, !session.isFinished else { return }
        guard let seconds = LyricsSyncPlan.window(starts: starts, from: position, songEnd: snapshot.track.duration > 0 ? snapshot.track.duration : nil) else {
            return
        }
        begin(seconds: seconds, context: Context(session: sessionKey, trackID: snapshot.track.id, starts: starts, fingerprint: fingerprint, key: key, snapshot: snapshot))
        session.beginWindow()
        sessions[sessionKey] = session
        log.info("Listening for \(Int(seconds.rounded())) s to check the lyrics' timing (window \(session.attempts) of \(LyricsSyncSession.maximumWindows))")
    }

    /// Lends the analysed audio for `seconds`.
    private func begin(seconds: Double, context: Context) {
        let capture = LyricsSyncCapture(seconds: seconds) { [weak self] finished in
            DispatchQueue.main.async { self?.finished(finished) }
        }
        self.capture = capture
        self.context = context
        audio.listen(forLyrics: capture)
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.capture === capture else { return }
            self.log.info("A sync window did not fill; giving it up")
            self.discard()
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 6, execute: watchdog)
    }

    private func cancel() {
        guard capture != nil else { return }
        audio.listen(forLyrics: nil)
        watchdog?.cancel()
        capture = nil
        context = nil
    }

    private func discard() {
        cancel()
        evaluate()
    }

    private func finished(_ capture: LyricsSyncCapture) {
        guard capture === self.capture, let context, let start = capture.startHostTime else { return }
        watchdog?.cancel()
        self.capture = nil
        self.context = nil
        // The song must have played straight through the window.
        guard let snapshot = nowPlaying.snapshot, snapshot.track.id == context.trackID, snapshot.isPlaying else {
            evaluate()
            return
        }
        let startDate = Date().addingTimeInterval(start - AudioClock.now())
        let position = context.snapshot.elapsed(at: startDate)
        let now = snapshot.elapsed(at: startDate)
        let slip = now - position
        guard abs(slip) < (context.words == nil ? Self.largestSlip : Self.largestHearingSlip) else {
            log.info("The song moved \(String(format: "%+.1f", slip)) s during a sync window; it is not measured")
            evaluate()
            return
        }
        let samples = capture.samples
        let rate = capture.sampleRate
        if context.words != nil {
            hearings[context.session, default: Hearing()].waiting += 1
            recognize(Reading(samples: samples, rate: rate, position: position + slip / 2, context: context))
            // The next window follows at once, while whisper reads this one.
            evaluate()
            return
        }
        let starts = context.starts
        let features = audio.store.currentFeatures()
        let beat = LyricsSyncSession.beatPeriod(bpm: features.bpm, confidence: features.tempoConfidence)
        work.async { [weak self] in
            let diagnostics = LyricsSyncSession.measure(samples, sampleRate: rate, starts: starts, position: position, beatPeriod: beat)
            DispatchQueue.main.async {
                self?.measured(diagnostics, context: context)
            }
        }
    }

    private func measured(_ window: LyricOffsetEstimator.Diagnostics, context: Context) {
        guard var session = sessions[context.session] else { return }
        let offset = session.add(window)
        sessions[context.session] = session
        log.info("Sync window: \(window.stage.rawValue), lead \(String(format: "%+.3f", window.leadSeconds)) s, z \(String(format: "%.1f", window.zScore))")
        if let offset {
            log.notice("Two windows agree: the lyrics run \(String(format: "%+.2f", -offset)) s off; corrected for this song")
            lyrics.applyMeasuredOffset(offset, fingerprint: context.fingerprint, for: context.key)
        } else if session.isFinished {
            log.info("No agreement after \(session.attempts) windows; the lyrics keep their own timing")
        }
        evaluate()
    }

    // MARK: A video's words

    /// A music video on YouTube or YouTube Music: moving pictures, as the
    /// page says; on YouTube itself, anything that is not the cover as a
    /// still. (An art track is the album's recording: the catalogs time it.)
    static func isVideo(_ snapshot: NowPlayingSnapshot) -> Bool {
        let source = snapshot.track.source
        guard source == .youtube || source == .youtubeMusic else { return false }
        return snapshot.songVideoKind?.isMovingPicture ?? (source == .youtube)
    }

    /// The next window for the video's words, counted; `nil` when there is
    /// none: the Mac runs lighter, or (settled, for this song and run)
    /// whisper is not on this Mac, the windows are used up, or too little
    /// of the song is left.
    private func hearingWindow(_ session: String, from position: Double, snapshot: NowPlayingSnapshot) -> (seconds: Double, runner: WhisperRunner)? {
        guard mayRecognize() else { return nil }
        var hearing = hearings[session] ?? Hearing()
        if hearings.count > 64 { hearings = [:] }
        defer { hearings[session] = hearing }
        let duration = snapshot.track.duration
        let seconds = duration > 0 ? min(Self.hearingSeconds, duration - position - 1) : Self.hearingSeconds
        guard hearing.windows + hearing.waiting < Self.maximumHearings, hearing.attempts < Self.maximumHearingAttempts,
              seconds >= Self.shortestHearing
        else {
            // (What whisper still reads is counted when it is heard.)
            hearing.isSettled = true
            return nil
        }
        let tools = WhisperLocator.system.locate(
            executableOverride: settings.lyrics.whisperExecutablePath, modelOverride: settings.lyrics.whisperModelPath
        )
        guard let executable = tools.executable, let model = tools.model else {
            hearing.isSettled = true
            log.info("A video's words cannot be heard (whisper or its model is not on this Mac); the onsets check the timing")
            return nil
        }
        hearing.attempts += 1
        return (seconds, WhisperRunner(executable: executable, model: model))
    }

    /// whisper reads the window, after the ones before it; what it heard
    /// goes to `heard`.
    private func recognize(_ reading: Reading) {
        guard !isRecognizing else {
            readings.append(reading)
            return
        }
        let context = reading.context
        guard let runner = context.words?.runner else { return }
        isRecognizing = true
        let (samples, rate, position) = (reading.samples, reading.rate, reading.position)
        let seconds = Double(samples.count) / max(1, rate)
        Task { [weak self] in
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-sync-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let started = Date()
            var transcript: WhisperTranscript?
            do {
                try await Task.detached(priority: .utility) { try WhisperAudio.write(samples, rate: rate, to: wav) }.value
                transcript = try await runner.transcribe(wav, timeout: 180)
            } catch {
                self?.log.error("whisper did not read a video's window: \(error)")
            }
            self?.heard(transcript, seconds: seconds, took: Date().timeIntervalSince(started), position: position, context: context)
        }
    }

    /// Adds a window's words to the song's and decides: the video runs
    /// apart from the lyrics (they are moved), with them, or it cannot be
    /// told yet.
    private func heard(_ transcript: WhisperTranscript?, seconds: Double, took: Double, position: Double, context: Context) {
        isRecognizing = false
        defer { readNext() }
        guard let words = context.words else { return }
        var hearing = hearings[context.session] ?? Hearing()
        hearing.waiting = max(0, hearing.waiting - 1)
        guard !hearing.isAnswered else {
            hearings[context.session] = hearing
            return
        }
        hearing.windows += 1
        // Counts only: words are never written to the log.
        let found = transcript?.words ?? []
        hearing.words += found.map { RecognizedWord(text: $0.text, start: $0.start + position, end: $0.end + position, confidence: $0.confidence) }
        let shift = LyricShiftEstimator.estimate(lines: words.lyrics.lines, words: hearing.words)
        let about = "Heard \(found.count) words in \(Int(seconds.rounded())) s of the video (\(transcript?.language ?? "?"), \(String(format: "%.1f", took)) s)"
        let evidence = shift.map { "\($0.lines) lines and \($0.words) words say \(String(format: "%+.1f", $0.seconds)) s, \(String(format: "%.1f", $0.score)) against \(String(format: "%.1f", $0.rivalScore))" } ?? "none of them in the lyrics"
        var moved: Double?
        if let shift, shift.isConfident {
            hearing.isSettled = true
            hearing.isAnswered = true
            if abs(shift.seconds) > Self.smallestShift {
                moved = shift.seconds
                log.notice("\(about): the video runs \(String(format: "%+.1f", shift.seconds)) s from the lyrics' timing (\(evidence)); the lyrics are moved for this song")
            } else {
                log.info("\(about): the lyrics' timing fits the video (\(evidence))")
            }
        } else if hearing.windows >= Self.maximumHearings || (hearing.isSettled && hearing.waiting == 0) {
            hearing.isSettled = true
            log.info("\(about): \(evidence); not enough to tell after \(hearing.windows) windows, the lyrics keep their own timing")
        } else {
            log.info("\(about): \(evidence); not enough to tell yet")
        }
        hearings[context.session] = hearing
        // Nothing more is heard for a song that is settled.
        if hearing.isSettled, self.context?.words != nil, self.context?.session == context.session { cancel() }
        // The lyrics the words were looked up in must still be the ones shown.
        guard let moved, lyrics.query == words.query, lyrics.lyrics?.timingFingerprint == context.fingerprint else {
            evaluate()
            return
        }
        let lyrics = self.lyrics
        Task { await lyrics.adoptAligned(words.lyrics.shifted(by: moved), for: words.query) }
    }

    /// Hands whisper the oldest window still worth reading: one of the
    /// playing song, whose words have not answered yet.
    private func readNext() {
        while !isRecognizing, !readings.isEmpty {
            let next = readings.removeFirst()
            let session = next.context.session
            if hearings[session]?.isAnswered == true || nowPlaying.snapshot?.track.id != next.context.trackID {
                if let waiting = hearings[session]?.waiting { hearings[session]?.waiting = max(0, waiting - 1) }
                continue
            }
            recognize(next)
        }
    }
}
