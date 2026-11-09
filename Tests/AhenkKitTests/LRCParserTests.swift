import Foundation
import Testing
@testable import AhenkKit

// Every line here is invented for the tests.

@Suite("LRC parsing")
struct LRCParserTests {
    @Test("Line timestamps, metadata and ends")
    func lines() throws {
        let parsed = LRCParser.parse("""
        [ar:The Tin Orchard]
        [ti:Paper Lanterns]
        [al:Rooftop Weather]
        [length:03:12]
        [00:01.00]Counting rooftops in the rain
        [00:03.50]Every gutter hums a tune
        [00:07.00]Paper lanterns over the lane
        """)
        #expect(parsed.lines.map(\.text) == ["Counting rooftops in the rain", "Every gutter hums a tune", "Paper lanterns over the lane"])
        #expect(parsed.lines.map(\.start) == [1, 3.5, 7])
        #expect(parsed.lines[0].end == 3.5 && parsed.lines[1].end == 7 && parsed.lines[2].end == nil)
        #expect(!parsed.hasWordTiming)
    }

    @Test("Tenths, hundredths, thousandths and the colon form")
    func fractions() throws {
        let parsed = LRCParser.parse("[00:01.5]a\n[00:02.25]b\n[01:02.250]c\n[00:03:50]d\n[00:04]e")
        let starts = parsed.lines.map(\.start)
        #expect(abs(starts[0] - 1.5) < 1e-9)
        #expect(abs(starts[1] - 2.25) < 1e-9)
        #expect(abs(starts[2] - 3.5) < 1e-9)
        #expect(abs(starts[3] - 4) < 1e-9)
        #expect(abs(starts[4] - 62.25) < 1e-9)
    }

    @Test("Several timestamps on one line repeat it")
    func repeats() {
        let parsed = LRCParser.parse("[00:05.00][00:01.00]Hum along the harbor")
        #expect(parsed.lines.map(\.start) == [1, 5])
        #expect(parsed.lines.allSatisfy { $0.text == "Hum along the harbor" })
    }

    @Test("Word timing, with the last word closed by the next line")
    func words() throws {
        let parsed = LRCParser.parse("[00:10.00]<00:10.00>Lanterns <00:10.60>over <00:11.10>water\n[00:13.00]Next")
        let line = try #require(parsed.lines.first)
        #expect(parsed.hasWordTiming)
        #expect(line.text == "Lanterns over water")
        #expect(line.words.map(\.start) == [10, 10.6, 11.1])
        #expect(line.words.map(\.end) == [10.6, 11.1, 13])
        #expect(parsed.activeWordIndex(at: 10.7)?.word == 1)
    }

    @Test("The offset tag moves every line")
    func offset() {
        let parsed = LRCParser.parse("[offset:+500]\n[00:02.00]Earlier by half a second")
        #expect(abs(parsed.lines[0].start - 1.5) < 1e-9)
        #expect(LRCParser.parse("[offset:-250]\n[00:02.00]Later").lines[0].start == 2.25)
    }

    @Test("Blank timed lines stay as pause markers; untimed text is dropped")
    func markers() {
        let parsed = LRCParser.parse("[00:01.00]Sung line\n[00:04.00]\n[00:09.00]  ♪  \nnot timed at all\n[00:12.00]Back again")
        #expect(parsed.lines.map(\.text) == ["Sung line", "", "♪", "Back again"])
        #expect(LyricsTimeline.isSung("Sung line"))
        #expect(!LyricsTimeline.isSung(""))
        #expect(!LyricsTimeline.isSung("♪ ♪"))
        #expect(!LyricsTimeline.isSung("..."))
    }

    @Test("A byte order mark, indentation and Windows line ends are read")
    func whitespace() {
        let parsed = LRCParser.parse("\u{FEFF}[00:01.00]First\r\n   [00:02.00]  Indented  \r\n[00:03.00]Last")
        #expect(parsed.lines.map(\.text) == ["First", "Indented", "Last"])
    }

    @Test("Lines out of order are sorted; equal times keep their order")
    func sorting() {
        let parsed = LRCParser.parse("[00:10.00]B\n[00:05.00]A\n[00:10.00]C\n[00:20.00]D")
        #expect(parsed.lines.map(\.text) == ["A", "B", "C", "D"])
        #expect(parsed.lines.allSatisfy { line in line.end.map { $0 >= line.start } ?? true })
    }

    @Test("Garbage, broken tags and absurd numbers never crash and never make lines")
    func garbage() {
        #expect(LRCParser.parse("").isEmpty)
        #expect(LRCParser.parse(" \n\t\n").isEmpty)
        #expect(LRCParser.parse("not lrc\n<<<>>>\n[abc]nope\n[12]x\n[[]]\n]x[\n[").isEmpty)
        #expect(LRCParser.parse("[00:01.00 broken\n[00:02.x]bad\n[00:02.00]ok").lines.map(\.text) == ["ok"])
        #expect(LRCParser.parse("[99999999999999999999:00.00]far\n[00:01.00]fine").lines.map(\.text) == ["fine"])
        #expect(LRCParser.parse("[-1:30.00]clamped").lines.first?.start == 0)
    }

    @Test("Line lookup finds the last line that started")
    func lookup() {
        let parsed = LRCParser.parse("[00:01.00]A\n[00:03.50]B\n[00:07.00]C")
        #expect(parsed.activeIndex(at: 0) == nil)
        #expect(parsed.activeIndex(at: 1) == 0)
        #expect(parsed.activeIndex(at: 3.49) == 0)
        #expect(parsed.activeIndex(at: 3.5) == 1)
        #expect(parsed.activeIndex(at: 500) == 2)
    }

    @Test("The timing fingerprint follows starts and text, and shifting moves every line")
    func fingerprint() {
        let a = LRCParser.parse("[00:01.00]One\n[00:02.00]Two")
        let b = LRCParser.parse("[00:01.00]One\n[00:02.00]Two")
        #expect(a.timingFingerprint == b.timingFingerprint)
        let shifted = a.shifted(by: 0.5)
        #expect(shifted.timingFingerprint != a.timingFingerprint)
        #expect(shifted.lines.map(\.start) == [1.5, 2.5])
        #expect(a.shifted(by: -5).lines.map(\.start) == [0, 0])
    }
}
