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
/// Never runs on a tap that hears every app (the fallback), never for
/// lyrics a provider proved for the exact recording, never over the user's
/// own nudge. The audio stays in memory until measured.
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
    }

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
        var session = sessions[sessionKey] ?? LyricsSyncSession(key: key, fingerprint: fingerprint)
        if sessions[sessionKey] == nil {
            if sessions.count > 64 { sessions = [:] }
            sessions[sessionKey] = session
        }
        guard !session.isFinished, capture == nil else { return }
        let starts = synced.lines.filter { LyricsTimeline.isSung($0.text) }.map(\.start)
        let position = snapshot.elapsed(at: Date())
        guard let seconds = LyricsSyncPlan.window(starts: starts, from: position, songEnd: snapshot.track.duration > 0 ? snapshot.track.duration : nil) else {
            return
        }
        let capture = LyricsSyncCapture(seconds: seconds) { [weak self] finished in
            DispatchQueue.main.async { self?.finished(finished) }
        }
        self.capture = capture
        context = Context(session: sessionKey, trackID: snapshot.track.id, starts: starts, fingerprint: fingerprint, key: key, snapshot: snapshot)
        audio.listen(forLyrics: capture)
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.capture === capture else { return }
            self.log.info("A sync window did not fill; giving it up")
            self.discard()
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 6, execute: watchdog)
        session.beginWindow()
        sessions[sessionKey] = session
        log.info("Listening for \(Int(seconds.rounded())) s to check the lyrics' timing (window \(session.attempts) of \(LyricsSyncSession.maximumWindows))")
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
        guard abs(position - now) < 0.3 else {
            log.info("The song moved during a sync window; it is not measured")
            evaluate()
            return
        }
        let samples = capture.samples
        let rate = capture.sampleRate
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
}
