import AhenkKit
import AppKit

/// The song's clip, live and away from whatever plays on this Mac
/// (`--smoke --smoke-only clipLive --wallpaper-song "Title|Artist|seconds"`):
/// asks YouTube for the song's official video and the lyric catalogs for
/// its timed lyrics, plays the clip silent in a window nobody sees, reads
/// its sound and says where the song falls in it. Needs the network and
/// whisper on this Mac; nothing is kept.
@MainActor
enum SongClipCheck {
    static func runLive(song: (title: String, artist: String, duration: Double), settings: AppSettings) async throws -> String {
        let log = AhenkLogger(category: "smoke")
        let fetcher = URLSessionFetcher(timeout: 12)
        let cache = CatalogCache(directory: nil)
        let matcher = YouTubeMusicMatcher(fetcher: fetcher, region: { "US" }, cache: cache)
        let filed = await matcher.match(title: song.title, artist: song.artist, duration: song.duration > 0 ? song.duration : nil)
        guard let found = SongClip.clip(from: filed, songDuration: song.duration) else {
            throw SmokeFailure("YouTube files no official video for the song (\(filed.map { "\($0.kind.rawValue) \u{201C}\($0.title)\u{201D}" } ?? "nothing found"))")
        }
        let video = found.video
        let about = "clip \u{201C}\(video.title)\u{201D} (\(video.id), \(Int(video.duration ?? 0)) s against the song's \(Int(song.duration)) s)"

        let query = LyricsQuery(title: song.title, artist: song.artist, duration: song.duration > 0 ? song.duration : nil)
        let lookup = await LyricsChain.standard(http: fetcher).fetch(query)
        guard case .synced(let lyrics) = lookup.response.result, lyrics.lines.count >= LyricShiftEstimator.minimumLines else {
            throw SmokeFailure("\(about); no timed lyrics for the song")
        }
        let tools = WhisperLocator.system.locate(executableOverride: settings.lyrics.whisperExecutablePath, modelOverride: settings.lyrics.whisperModelPath)
        guard let executable = tools.executable, let model = tools.model else { throw SmokeFailure("\(about); whisper or its model is not on this Mac") }

        let size = CGSize(width: 302, height: 170)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        // As the wallpaper does it: the clip starts at the song's likely
        // place in it (here for a song that is 20 s in).
        let guess = SongClip.guess(songDuration: song.duration, videoDuration: video.duration)
        let start = guess?.videoPosition(song: 20) ?? 20
        let media = YouTubeMediaView(
            candidate: .youtube(video, kind: .songVideo), videoID: video.id, start: start, loops: false, plan: SongClip.hearingPlan,
            frame: NSRect(origin: .zero, size: size), playsWhenCovered: true, hearsSound: true
        )
        var failure: String?
        media.onFailure = { (reason: WallpaperMediaFailure) in failure = reason.detail }
        window.contentView = media
        window.orderFrontRegardless()
        defer {
            media.tearDown()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        media.setPlaying(true)
        let started = Date()
        while !media.isReady, failure == nil, Date().timeIntervalSince(started) < 25 {
            try await Task.sleep(for: .milliseconds(200))
        }
        if let failure { throw SmokeFailure("\(about); the embedded player did not play it (\(failure))") }
        guard media.isReady else { throw SmokeFailure("\(about); the embedded player did not start within 25 s") }

        let range = SongClip.possibleOffsets(songDuration: song.duration, videoDuration: video.duration)
        var likely: (seconds: Double, after: Double)?
        let outcome = await SongClipOffsetFinder.hear(media, lines: lyrics.lines, runner: WhisperRunner(executable: executable, model: model), log: log, within: range) { shift in
            if likely == nil { likely = (shift.seconds, Date().timeIntervalSince(started)) }
        }
        switch outcome {
        case .heard(let shift):
            let offset = SongClip.offset(from: shift)
            return "\(about); \(lyrics.lines.count) timed lines from \(lookup.response.source); the song falls \(String(format: "%+.1f", offset)) s into the clip "
                + "(\(shift.lines) lines and \(shift.words) words agree, \(String(format: "%.1f", shift.score)) against \(String(format: "%.1f", shift.rivalScore))), "
                + "heard in \(String(format: "%.1f", Date().timeIntervalSince(started))) s from the clip's start at \(Int(start)) s (guessed \(String(format: "%+.1f", guess?.offset ?? 0)) s)"
                + (likely.map { "; likely \(String(format: "%+.1f", $0.seconds)) s after \(String(format: "%.1f", $0.after)) s" } ?? "")
        case .cannotTell(let reason):
            throw SmokeFailure("\(about); \(reason)")
        }
    }
}
