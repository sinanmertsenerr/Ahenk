import AhenkKit
import Foundation

/// Finds where a song falls in its clip (`SongClipMap`; see `SongClip` for
/// the order of the ways), for the live wallpaper: what is kept, then
/// YouTube Music's own pairing through the browser extension, then the
/// clip's words heard from the sound its player holds.
@MainActor
final class SongClipTiming {
    private let settings: AppSettings
    private let lyrics: LyricsController
    private let bridge: BridgePlaybackRouter?
    private let maps: SongClipMaps
    private let log = AhenkLogger(category: "wallpaper")

    /// How long the song's timed lyrics are waited for before its clip is heard.
    static let lyricsPatience: TimeInterval = 25

    init(settings: AppSettings, lyrics: LyricsController, bridge: BridgePlaybackRouter?, cache: CatalogCache) {
        self.settings = settings
        self.lyrics = lyrics
        self.bridge = bridge
        maps = SongClipMaps(cache: cache)
    }

    /// What is kept about the song and the clip.
    func known(track: Track, videoID: String) -> SongClipMaps.Known? {
        maps.known(videoID: videoID, track: track)
    }

    private var whisper: WhisperRunner? {
        let tools = WhisperLocator.system.locate(
            executableOverride: settings.lyrics.whisperExecutablePath, modelOverride: settings.lyrics.whisperModelPath
        )
        guard let executable = tools.executable, let model = tools.model else { return nil }
        return WhisperRunner(executable: executable, model: model)
    }

    /// The clip's words can be heard on this Mac (whisper and a model are here).
    var canHear: Bool { whisper != nil }

    /// YouTube Music's own pairing of the clip with its song, asked of a
    /// signed-in tab: about a second. `nil`: no such tab, no pairing, or a
    /// pairing with another recording than the one that plays.
    func ask(track: Track, videoID: String) async -> SongClipMap? {
        guard let bridge else { return nil }
        let started = Date()
        guard let clip = await bridge.clip(ofVideo: videoID) else { return nil }
        guard let map = SongClipMap(clip, songDuration: track.duration) else {
            log.info("YouTube Music pairs the clip with a song of another length (\(Int(clip.songSeconds ?? 0)) s against \(Int(track.duration)) s): not used")
            return nil
        }
        maps.remember(.map(map), videoID: videoID, track: track)
        let where_ = map.offset.map { "the song falls \(String(format: "%+.2f", $0)) s into it" } ?? "\(map.segments.count) stretches of the song in it"
        log.notice("YouTube Music's own pairing of the clip and the song, in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(where_); kept for next time")
        return map
    }

    /// The clip's words, read from the sound `media` holds and looked up
    /// in the song's timed lyrics: half a minute or so, once per song and
    /// clip. `nil` when it cannot be told.
    /// `onLikely` gets an answer that is likely before it is sure, for the
    /// clip to be moved by at once.
    func hear(track: Track, videoID: String, media: YouTubeMediaView, onLikely: @escaping @MainActor (SongClipMap) -> Void) async -> SongClipMap? {
        guard let runner = whisper else { return nil }
        // The song's timed lyrics, once they are found.
        let waitUntil = Date().addingTimeInterval(Self.lyricsPatience)
        var lines: [LyricLine] = []
        while lines.isEmpty, Date() < waitUntil, !Task.isCancelled {
            if let synced = lyrics.lyrics, let query = lyrics.query, TrackMatching.coreTitle(query.title) == TrackMatching.coreTitle(track.title),
               synced.lines.count >= LyricShiftEstimator.minimumLines {
                lines = synced.lines
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        guard !Task.isCancelled else { return nil }
        guard !lines.isEmpty else {
            log.info("The song has no timed lyrics to hear its clip by")
            return nil
        }
        log.info("Hearing where the song falls in its clip (\(Int(SongClipOffsetFinder.windowSeconds)) s of its sound at a time)")
        let range = SongClip.possibleOffsets(songDuration: track.duration, videoDuration: media.candidate.duration)
        let started = Date()
        var told = false
        let outcome = await SongClipOffsetFinder.hear(media, lines: lines, runner: runner, log: log, within: range) { [log] shift in
            if !told {
                told = true
                log.info("Likely \(String(format: "%+.1f", shift.seconds)) s into the clip after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: the clip is moved there while more is heard")
            }
            onLikely(SongClipMap(offset: SongClip.offset(from: shift)))
        }
        switch outcome {
        case .heard(let shift):
            let map = SongClipMap(offset: SongClip.offset(from: shift))
            maps.remember(.map(map), videoID: videoID, track: track)
            log.notice("The song falls \(String(format: "%+.1f", map.offset ?? 0)) s into its clip (\(shift.lines) lines and \(shift.words) words agree); kept for next time")
            return map
        case .cannotTell(let reason):
            // Read and not told: not tried again for a few days.
            if reason.contains("did not say") { maps.remember(.unknown, videoID: videoID, track: track) }
            if !Task.isCancelled { log.info("Where the song falls in its clip could not be heard (\(reason))") }
            return nil
        }
    }
}
