import Foundation
import Testing
@testable import AhenkKit

// Invented songs and videos only.

@Suite("The song's clip in the player")
struct SongClipTests {
    private func playing(_ source: MusicSource, kind: ContentKind = .music, video: SongVideoKind? = nil, title: String = "Velvet Harbor Lights", artist: String = "Orchid Telemetry") -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: Track(id: source == .youtubeMusic ? "https://music.youtube.com/watch?v=ahenkMock01" : "id-1", source: source, title: title, artist: artist, duration: 214),
            elapsedTime: 0, playbackRate: 1, timestamp: .distantPast, contentKind: kind, songVideoKind: video
        )
    }

    @Test("A clip is looked for when a song plays as sound")
    func wanted() {
        for source in [MusicSource.spotify, .appleMusic, .spotifyWeb, .deezer, .soundCloud, .local] {
            #expect(SongClip.isWanted(for: playing(source)), "\(source)")
        }
        // A song on YouTube Music over its album cover is sound too.
        #expect(SongClip.isWanted(for: playing(.youtubeMusic, video: .artTrack)))
        #expect(SongClip.isWanted(for: playing(.youtubeMusic)))
        // The browser already shows the clip.
        #expect(!SongClip.isWanted(for: playing(.youtubeMusic, video: .officialVideo)))
        #expect(!SongClip.isWanted(for: playing(.youtube)))
        // Not music, nobody to ask by, or the demo.
        #expect(!SongClip.isWanted(for: playing(.spotify, kind: .podcast)))
        #expect(!SongClip.isWanted(for: playing(.spotify, artist: " ")))
        #expect(!SongClip.isWanted(for: playing(.spotify, title: "")))
        #expect(!SongClip.isWanted(for: playing(.demo)))
    }

    @Test("The song's clip is its official video; its length says whether it may play before its offset is heard")
    func clip() {
        func entry(_ kind: YouTubeMusicEntry.Kind, _ duration: TimeInterval?) -> YouTubeMusicEntry {
            YouTubeMusicEntry(id: "ahenkMock01", title: "Velvet Harbor Lights", artists: ["Orchid Telemetry"], duration: duration, kind: kind)
        }
        let same = SongClip.clip(from: entry(.officialVideo, 216), songDuration: 214)
        #expect(same?.video.id == "ahenkMock01" && same?.isAsLongAsTheSong == true)
        #expect(SongClip.clip(from: entry(.officialVideo, 226), songDuration: 214)?.isAsLongAsTheSong == true, "within six percent of the song")
        // An intro or another cut: a clip all the same, but not shown before it is heard.
        #expect(SongClip.clip(from: entry(.officialVideo, 262), songDuration: 214)?.isAsLongAsTheSong == false)
        #expect(SongClip.clip(from: entry(.officialVideo, 214), songDuration: 0)?.isAsLongAsTheSong == false, "a song of a length nobody knows")
        // The song's recording over its cover, or somebody's upload, is not a clip.
        #expect(SongClip.clip(from: entry(.artTrack, 214), songDuration: 214) == nil)
        #expect(SongClip.clip(from: entry(.userUpload, 214), songDuration: 214) == nil)
        #expect(SongClip.clip(from: entry(.officialVideo, nil), songDuration: 214) == nil)
        #expect(SongClip.clip(from: nil, songDuration: 214) == nil)
    }

    @Test("The clip is where the song's stretch of it is; a small heard shift is none")
    func map() throws {
        let intro = SongClipMap(offset: 40.4)
        #expect(intro.videoPosition(song: 30) == 70.4 && intro.offset == 40.4)
        #expect(intro.videoPosition(song: 0) == 40.4)
        // The clip starts inside the song: it waits at its start.
        let late = SongClipMap(offset: -5)
        #expect(late.videoPosition(song: 2) == 0 && late.videoPosition(song: 12) == 7 && late.offset == -5)
        // Two stretches with a scene between them.
        let scene = try #require(SongClipMap(segments: [
            .init(video: 175.5, song: 120.613, duration: 93), .init(video: 41, song: 0.613, duration: 120),
        ]))
        #expect(scene.segments.map(\.video) == [41, 175.5], "in the song's order")
        #expect(abs(scene.videoPosition(song: 60.613) - 101) < 0.0001)
        #expect(abs(scene.videoPosition(song: 130.613) - 185.5) < 0.0001, "past the scene")
        #expect(abs(scene.videoPosition(song: 0) - 40.387) < 0.0001, "before the first stretch: as far before it in the clip")
        #expect(scene.offset == nil)
        #expect(SongClipMap(segments: []) == nil)
        #expect(SongClipMap(segments: [.init(video: -1, song: 0, duration: 10), .init(video: 0, song: 0, duration: 0)]) == nil)

        func shift(_ seconds: Double) -> LyricShift { LyricShift(seconds: seconds, lines: 6, words: 20, score: 9, rivalScore: 2) }
        #expect(SongClip.offset(from: shift(44.5)) == 44.5)
        #expect(SongClip.offset(from: shift(-3)) == -3)
        #expect(SongClip.offset(from: shift(0.5)) == 0)
        #expect(SongClip.offset(from: shift(-0.5)) == 0)
    }

    @Test("YouTube Music's pairing is used for the recording that plays, not for another")
    func paired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/bridge/result-clip.json"))
        guard case .result(let result) = try BridgeInbound.decode(data) else {
            Issue.record("not a result")
            return
        }
        let clip = try #require(result.clip)
        #expect(clip.videoID == "ahenkMock0V" && clip.songID == "ahenkMock01" && clip.songSeconds == 214 && clip.segments.count == 2)
        let map = try #require(SongClipMap(clip, songDuration: 215))
        #expect(abs(map.videoPosition(song: 10.613) - 51) < 0.0001)
        #expect(SongClipMap(clip, songDuration: 262) == nil, "a live take or another edit of the song")
        #expect(SongClipMap(clip, songDuration: 0) != nil, "a song of a length nobody knows is taken on the site's word")
        // Segments that say nothing are dropped; a clip without any is no answer.
        let empty = #"{"type":"result","id":"r1","ok":true,"clip":{"videoId":"ahenkMock0V","segments":[{"video":1,"song":2,"duration":0},{"video":"x"}]}}"#
        guard case .result(let none) = try BridgeInbound.decode(Data(empty.utf8)) else { return }
        #expect(none.clip == nil)
        // The request names the video.
        let request = try #require(try JSONSerialization.jsonObject(with: BridgeOutbound.request(
            BridgeRequest(id: "r14", kind: .clip, site: "youtubeMusic", tabID: 41, videoID: "ahenkMock0V")
        ).encoded()) as? [String: Any])
        #expect(request["request"] as? String == "clip" && request["videoId"] as? String == "ahenkMock0V")
    }

    @Test("A jump is aimed with what the last one taught; a known clip is held closer to the song")
    func lead() {
        // Landed 0.5 s behind: aim further ahead next time.
        #expect(abs(VideoSync.adjustedLead(0.9, error: -0.5) - 1.25) < 0.0001)
        #expect(abs(VideoSync.adjustedLead(0.9, error: 0.4) - 0.62) < 0.0001)
        #expect(VideoSync.adjustedLead(0.2, error: 2) == 0, "never aimed behind")
        #expect(VideoSync.adjustedLead(2.9, error: -2.9) == 3)
        #expect(VideoSync.adjustedLead(0.9, error: 12) == 0.9, "the song was moved: not a landing")
        let wanted = SongClipMap(offset: 40.4).videoPosition(song: 30)
        #expect(VideoSync.correction(songPosition: wanted, videoPosition: wanted + 0.5, videoDuration: 231, tolerance: VideoSync.mappedTolerance) == nil)
        #expect(VideoSync.correction(songPosition: wanted, videoPosition: wanted - 0.8, videoDuration: 231, tolerance: VideoSync.mappedTolerance, lead: 1.2) == wanted + 1.2)
        #expect(VideoSync.correction(songPosition: wanted, videoPosition: wanted - 0.8, videoDuration: 231) == nil, "an unknown clip is left alone that close")
    }

    @Test("A map once known is kept; one that could not be told is tried again after a few days")
    func kept() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let maps = SongClipMaps(cache: CatalogCache(directory: nil), clock: { clock.now })
        let song = Track(id: "spotify:track:x", source: .spotify, title: "Velvet Harbor Lights (feat. Nadia Ferro)", artist: "Orchid Telemetry", duration: 214)
        #expect(maps.known(videoID: "ahenkMock01", track: song) == nil)
        maps.remember(.map(SongClipMap(offset: 44.5)), videoID: "ahenkMock01", track: song)
        #expect(maps.known(videoID: "ahenkMock01", track: song) == .map(SongClipMap(offset: 44.5)))
        // The same song from another source is the same song; another clip or another song is not.
        var elsewhere = song
        elsewhere.source = .appleMusic
        elsewhere.id = "music:1"
        elsewhere.title = "Velvet Harbor Lights"
        #expect(maps.known(videoID: "ahenkMock01", track: elsewhere) == .map(SongClipMap(offset: 44.5)))
        #expect(maps.known(videoID: "ahenkMock02", track: song) == nil)
        maps.remember(.unknown, videoID: "ahenkMock02", track: song)
        #expect(maps.known(videoID: "ahenkMock02", track: song) == .unknown)
        clock.now += 4 * 86_400
        #expect(maps.known(videoID: "ahenkMock02", track: song) == nil, "tried again")
        #expect(maps.known(videoID: "ahenkMock01", track: song) == .map(SongClipMap(offset: 44.5)))
    }

    @Test("From the lengths alone: where the clip starts at once, and which offsets are possible at all")
    func guess() {
        // About as long as the song: the same recording from the same start.
        #expect(SongClip.guess(songDuration: 186, videoDuration: 188)?.offset == 0)
        // What a longer clip has more is taken for an intro.
        #expect(SongClip.guess(songDuration: 186, videoDuration: 231)?.offset == 45)
        #expect(SongClip.guess(songDuration: 186, videoDuration: 231)?.videoPosition(song: 20) == 65)
        // A shorter clip starts with the song.
        #expect(SongClip.guess(songDuration: 186, videoDuration: 150)?.offset == 0)
        #expect(SongClip.guess(songDuration: 0, videoDuration: 231) == nil)
        #expect(SongClip.guess(songDuration: 186, videoDuration: nil) == nil)
        // The song lies inside its clip.
        #expect(SongClip.possibleOffsets(songDuration: 186, videoDuration: 231) == -4...49)
        #expect(SongClip.possibleOffsets(songDuration: 186, videoDuration: 186) == -4...4)
        #expect(SongClip.possibleOffsets(songDuration: 186, videoDuration: 150) == -4...4)
        #expect(SongClip.possibleOffsets(songDuration: 0, videoDuration: 150) == nil)
    }

    @Test("A refrain heard at another of its turns does not speak for an offset the lengths rule out")
    func range() throws {
        // A verse line, then the same refrain at 20 s and at 60 s.
        let lines = [
            LyricLine(start: 10, text: "salt on the window morning in the wires"),
            LyricLine(start: 20, text: "we row the harbor home tonight"),
            LyricLine(start: 60, text: "we row the harbor home tonight"),
        ]
        // The clip plays the song 40 s later: the refrain's first turn is heard at 60 s.
        let heard = ["we", "row", "the", "harbor", "home", "tonight"].enumerated().map { index, word in
            RecognizedWord(text: word, start: 60 + Double(index) * 0.45, end: 60.3 + Double(index) * 0.45)
        }
        // On its own the stretch has two answers about as good (+40 s and 0 s).
        let open = try #require(LyricShiftEstimator.estimate(lines: lines, words: heard))
        #expect(open.rivalScore > 0 && !open.isConfident)
        // A clip of the song's own length cannot run 40 s apart from it.
        let same = try #require(LyricShiftEstimator.estimate(lines: lines, words: heard, within: -4...4))
        #expect(abs(same.seconds) < 0.5 && same.rivalScore == 0)
        // A clip 45 s longer may: both answers stay open.
        let longer = try #require(LyricShiftEstimator.estimate(lines: lines, words: heard, within: -4...49))
        #expect(longer.rivalScore > 0)
        #expect(LyricShiftEstimator.estimate(lines: lines, words: heard, within: 100...120) == nil)
        // Likely is less than sure.
        #expect(LyricShift(seconds: 40.4, lines: 4, words: 20, score: 2.6, rivalScore: 2.1).isLikely)
        #expect(!LyricShift(seconds: 40.4, lines: 4, words: 20, score: 2.6, rivalScore: 2.1).isConfident)
        #expect(!LyricShift(seconds: 40.4, lines: 3, words: 20, score: 2.6, rivalScore: 0).isLikely)
        #expect(!LyricShift(seconds: 40.4, lines: 6, words: 20, score: 2, rivalScore: 2).isLikely)
    }

    @Test("The same song under news of itself is one song")
    func key() {
        let a = playing(.spotify)
        var b = a
        b.elapsedTime = 90
        b.playbackRate = 0
        #expect(SongClip.songKey(a) == SongClip.songKey(b))
        #expect(SongClip.songKey(a) != SongClip.songKey(playing(.spotify, title: "Quiet Engines")))
    }
}
