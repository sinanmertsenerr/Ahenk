import Foundation
import Testing
@testable import AhenkKit

@Suite("Models")
struct ModelTests {
    private let track = Track(id: "t1", source: .appleMusic, title: "Invented", artist: "Nobody", album: "None", duration: 200)

    @Test("Snapshot position interpolates while playing")
    func interpolation() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let playing = NowPlayingSnapshot(track: track, elapsedTime: 10, playbackRate: 1, timestamp: start)
        #expect(playing.elapsed(at: start.addingTimeInterval(5)) == 15)
        #expect(playing.elapsed(at: start.addingTimeInterval(500)) == 200, "clamped to the duration")
        #expect(abs(playing.progress(at: start.addingTimeInterval(90)) - 0.5) < 1e-9)

        let paused = NowPlayingSnapshot(track: track, elapsedTime: 10, playbackRate: 0, timestamp: start)
        #expect(!paused.isPlaying)
        #expect(paused.elapsed(at: start.addingTimeInterval(60)) == 10)

        let fast = NowPlayingSnapshot(track: track, elapsedTime: 0, playbackRate: 2, timestamp: start)
        #expect(fast.elapsed(at: start.addingTimeInterval(3)) == 6)

        var unknown = track
        unknown.duration = 0
        let open = NowPlayingSnapshot(track: unknown, elapsedTime: 400, playbackRate: 1, timestamp: start)
        #expect(open.elapsed(at: start.addingTimeInterval(1)) == 401)
        #expect(open.progress(at: start) == 0)
    }

    @Test("Same track means same source and id")
    func sameTrack() {
        let now = Date()
        let a = NowPlayingSnapshot(track: track, elapsedTime: 1, playbackRate: 1, timestamp: now)
        var other = track
        other.title = "Retitled"
        let b = NowPlayingSnapshot(track: other, elapsedTime: 50, playbackRate: 0, timestamp: now)
        #expect(a.isSameTrack(as: b))
        other.source = .spotify
        #expect(!a.isSameTrack(as: NowPlayingSnapshot(track: other, elapsedTime: 1, playbackRate: 1, timestamp: now)))
    }

    @Test("Active lyric line by time")
    func lyricIndex() {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(start: 8, text: "third"),
            LyricLine(start: 0.5, text: "first"),
            LyricLine(start: 4, text: "second", words: [
                LyricWord(text: "sec", start: 4), LyricWord(text: "ond", start: 4.6),
            ]),
        ])
        #expect(lyrics.lines.map(\.text) == ["first", "second", "third"], "sorted on init")
        #expect(lyrics.activeIndex(at: 0) == nil)
        #expect(lyrics.activeIndex(at: 0.5) == 0)
        #expect(lyrics.activeIndex(at: 7.99) == 1)
        #expect(lyrics.activeIndex(at: 100) == 2)
        #expect(lyrics.line(at: 5)?.text == "second")
        #expect(lyrics.hasWordTiming)
        #expect(lyrics.activeWordIndex(at: 4.7).map { [$0.line, $0.word] } == [1, 1])
        #expect(lyrics.activeWordIndex(at: 9) == nil)
    }

    @Test("Lyrics query from a track")
    func lyricsQuery() {
        let query = LyricsQuery(track: track)
        #expect(query.album == "None" && query.duration == 200)
        let bare = LyricsQuery(track: Track(id: "x", source: .local, title: "A", artist: "B"))
        #expect(bare.album == nil && bare.duration == nil)
    }

    @Test("Sources: brands, browsers and the pinnable list")
    func sources() {
        #expect(MusicSource.appleMusic.brandName == "Apple Music")
        #expect(MusicSource.local.brandName == nil)
        #expect(MusicSource.youtubeMusic.isBrowserBased && !MusicSource.spotify.isBrowserBased)
        #expect(!MusicSource.pinnable.contains(.demo) && !MusicSource.pinnable.contains(.otherApp))
        #expect(MusicSource.pinnable.contains(.local))
    }

    @Test("Silence is silent")
    func silence() {
        #expect(AudioFeatures.silence.isSilent && AudioFeatures.silence.level == 0)
    }
}

@Suite("SmokeReport")
struct SmokeReportTests {
    @MainActor
    @Test("Checks record ok, skipped and error")
    func checks() async throws {
        var report = SmokeReport(version: "0.1.0", build: "1", commit: "abc", bundlePath: "/tmp/Ahenk.app")
        await report.check("good") { "fine" }
        await report.check("absent") { throw SmokeReport.Skip("not bundled") }
        #expect(report.ok)
        await report.check("bad") { throw SmokeFailure("broke") }
        report.finish()
        #expect(!report.ok)
        #expect(report.subsystems.map(\.status) == [.ok, .skipped, .error])
        #expect(report.subsystems.map(\.detail) == ["fine", "not bundled", "broke"])
        #expect(report.finishedAt != nil)

        let dir = ScratchDirectory()
        let url = dir.url.appendingPathComponent("nested/smoke.json")
        try report.write(to: url)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["ok"] as? Bool == false)
        #expect((json["subsystems"] as? [[String: Any]])?.count == 3)
        #expect(json["startedAt"] is String, "dates are ISO 8601")
    }
}

@Suite("ChangeObserver")
struct ChangeObserverTests {
    @MainActor
    @Test("Calls back once per change of the observed value")
    func observes() async {
        let settings = AppSettings()
        var received: [AppLanguage] = []
        let observer = ChangeObserver({ settings.general.language }) { received.append($0) }

        settings.light.enabled = false
        settings.general.language = .turkish
        #expect(await eventually { received == [.turkish] })

        settings.general.verboseLogging = true // same group, same language
        settings.general.language = .english
        #expect(await eventually { received == [.turkish, .english] })

        observer.cancel()
        settings.general.language = .turkish
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received == [.turkish, .english], "nothing after cancel")
    }
}
