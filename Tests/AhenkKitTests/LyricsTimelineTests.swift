import Foundation
import Testing
@testable import AhenkKit

// Every line here is invented for the tests.

@Suite("Lyrics timeline")
struct LyricsTimelineTests {
    /// Lines every 4 s, a pause after 16 s, more lines from 30 s.
    static let lyrics = LRCParser.parse("""
    [00:04.00]Counting rooftops in the rain
    [00:08.00]Every gutter hums a tune
    [00:12.00]Paper lanterns over the lane
    [00:16.00]Holding on to afternoon
    [00:30.00]Back beneath the copper sky
    [00:34.00]Every window waves goodbye
    """)

    @Test("The line on screen at a time")
    func lookup() {
        let timeline = LyricsTimeline(Self.lyrics, duration: 60)
        #expect(timeline.lines.count == 6)
        #expect(timeline.lineIndex(at: 3.9) == nil)
        #expect(timeline.lineIndex(at: 4) == 0)
        #expect(timeline.lineIndex(at: 11.99) == 1)
        #expect(timeline.lineIndex(at: 31) == 4)
        #expect(timeline.lineIndex(at: 1_000) == 5)
    }

    @Test("Lines close together are sung almost to the next; a line before a pause lasts as long as its words")
    func sungEnds() {
        let timeline = LyricsTimeline(Self.lyrics, duration: 60)
        let first = timeline.lines[0]
        #expect(abs(first.sungEnd - (4 + 4 * 0.92)) < 1e-9)
        #expect(first.holdEnd == 8)
        let beforePause = timeline.lines[3]
        #expect(beforePause.sungEnd > 16 + 1.4 && beforePause.sungEnd < 16 + 6.5)
        #expect(first.progress(at: 3) == 0)
        #expect(abs(first.progress(at: 4 + 1.84) - 0.5) < 1e-6)
        #expect(first.progress(at: 7.9) == 1)
    }

    @Test("A long pause between lines is an instrumental part with a countdown")
    func interlude() throws {
        let timeline = LyricsTimeline(Self.lyrics, duration: 60)
        let gap = try #require(timeline.gaps.first { $0.kind == .interlude })
        #expect(gap.previousLine == 3 && gap.nextLine == 4)
        #expect(gap.end == 30)
        #expect(gap.start > timeline.lines[3].sungEnd && gap.start < 25)
        #expect(timeline.lines[3].holdEnd == gap.start)

        let scene = timeline.scene(at: 25)
        #expect(scene.current == nil)
        let state = try #require(scene.gap)
        #expect(state.kind == .interlude && state.remaining == 5 && state.countdown == 5)
        #expect(state.fraction > 0 && state.fraction < 1)
        #expect(state.nextLine == 4)
        #expect(timeline.scene(at: 29.1).gap?.countdown == 1)
        #expect(timeline.gap(at: 25) == gap)
    }

    @Test("Short pauses are not instrumental parts")
    func shortPause() {
        let lyrics = LRCParser.parse("[00:01.00]One line here\n[00:06.00]Another line\n[00:09.00]Last one")
        let timeline = LyricsTimeline(lyrics, duration: 30)
        #expect(!timeline.gaps.contains { $0.kind == .interlude })
    }

    @Test("A blank timed line marks where the singing stops")
    func marker() throws {
        let lyrics = LRCParser.parse("[00:02.00]Short words\n[00:04.00]\n[00:20.00]Words again")
        let timeline = LyricsTimeline(lyrics, duration: 40)
        #expect(timeline.lines.map(\.text) == ["Short words", "Words again"])
        #expect(timeline.lines[0].sungEnd <= 4)
        let gap = try #require(timeline.gaps.first { $0.kind == .interlude })
        #expect(gap.start <= 4.5 && gap.end == 20)
    }

    @Test("An explicit line end before the next line opens a pause")
    func explicitEnd() throws {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(start: 4, end: 8, text: "A line that ends"),
            LyricLine(start: 24, end: 28, text: "A line much later"),
        ])
        let gap = try #require(LyricsTimeline(lyrics, duration: 40).gaps.first { $0.kind == .interlude })
        #expect(gap.start == 8 && gap.end == 24)
    }

    @Test("The intro shows before the first line; the outro after the last")
    func introAndOutro() throws {
        let timeline = LyricsTimeline(Self.lyrics, duration: 60)
        let intro = try #require(timeline.gaps.first)
        #expect(intro.kind == .intro && intro.start == 0 && intro.end == 4)
        let start = timeline.scene(at: 1)
        #expect(start.gap?.kind == .intro && start.gap?.countdown == 3 && start.upcoming == 0)
        let outro = try #require(timeline.gaps.last)
        #expect(outro.kind == .outro && outro.end == nil)
        let end = timeline.scene(at: 55)
        #expect(end.gap?.kind == .outro && end.gap?.remaining == nil && end.current == nil)
        // A short intro shows nothing until the first line.
        let quick = LyricsTimeline(LRCParser.parse("[00:01.00]Right away"), duration: 10)
        #expect(!quick.gaps.contains { $0.kind == .intro })
        #expect(quick.scene(at: 0.2).gap == nil)
    }

    @Test("Lines glide in a little early; the last one glides out at the same time")
    func glides() throws {
        let timeline = LyricsTimeline(Self.lyrics, duration: 60)
        let lead = LyricsScene.lead
        let entering = timeline.scene(at: 8 - lead + 0.25)
        let current = try #require(entering.current)
        #expect(current.index == 1 && abs(current.enter - 0.5) < 1e-9)
        let previous = try #require(entering.previous)
        #expect(previous.index == 0 && abs(previous.exit - current.enter) < 1e-9)
        #expect(entering.isGliding)
        let settled = timeline.scene(at: 10)
        #expect(settled.current?.enter == 1 && settled.previous == nil && !settled.isGliding)
        #expect(settled.upcoming == 2)
        // The line before a pause gives way to the countdown.
        let gapStart = try #require(timeline.gaps.first { $0.kind == .interlude }).start
        let leaving = timeline.scene(at: gapStart + 0.1)
        #expect(leaving.previous?.index == 3 && leaving.gap?.enter ?? 0 > 0 && leaving.current == nil)
        // After the pause, the countdown leaves while the next line comes.
        let back = timeline.scene(at: 30 - lead + 0.1)
        #expect(back.current?.index == 4 && back.gap?.exit ?? 0 > 0 && back.previous == nil)
    }

    @Test("Word timing drives the sung progress")
    func wordProgress() throws {
        let lyrics = LRCParser.parse("[00:10.00]<00:10.00>Wide <00:11.00>open <00:13.00>road\n[00:15.00]Next line")
        let line = try #require(LyricsTimeline(lyrics, duration: 30).lines.first)
        // "Wide" (4) "open" (4) "road" (4): half of "open" is 6 of 12.
        #expect(abs(line.progress(at: 12) - 0.5) < 1e-9)
        #expect(line.progress(at: 10) == 0)
        #expect(line.sungEnd == 15)
    }

    @Test("The demo songs read as intended: two-bar lines and their instrumental breaks")
    func demoSongs() throws {
        let song = DemoCatalog.songs[0]
        let timeline = LyricsTimeline(song.lyrics, duration: song.track.duration)
        let gap = try #require(timeline.gaps.first { $0.kind == .interlude })
        #expect(gap.start == 36 && gap.end == 52)
        #expect(timeline.scene(at: 40.4).gap?.countdown == 12)
        let preview = LyricsTimeline(DemoCatalog.previewLyrics(turkish: true), minimumGap: DemoCatalog.previewMinimumGap)
        #expect(preview.gaps.filter { $0.kind == .interlude }.count >= 3)
        // The loop has no seam: a moment and the same moment a cycle later look alike.
        let a = preview.scene(at: DemoCatalog.previewTime(elapsed: 2))
        let b = preview.scene(at: DemoCatalog.previewTime(elapsed: 2 + DemoCatalog.previewCycle))
        #expect(a.current?.sung == b.current?.sung && a.gap?.countdown == b.gap?.countdown)
    }
}
