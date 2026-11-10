import Foundation
import Testing
@testable import AhenkKit

// Every lyric line and word here is invented for the tests.

@Suite("Lyric shift from heard words")
struct LyricShiftTests {
    static let verse = [
        "Copper kites above the quarry",
        "Nobody waters the paper garden",
        "Borrowed lamps on sleeping trains",
        "Hold the door for a slower river",
    ]
    static let refrain = [
        "Carry my shadow over the orchard",
        "Seven bridges and none are mine",
        "Carry my whisper under the harbor",
        "Seven winters and all are kind",
    ]
    static let second = [
        "Velvet engines counting pigeons",
        "Somebody painted the kitchen thunder",
        "Marble pockets full of weather",
        "Fold the map into smaller mountains",
    ]

    /// Verse, refrain, verse, refrain, refrain: a line every three seconds
    /// from 0:10, as a catalog times the album's recording.
    static let lyrics: [LyricLine] = (verse + refrain + second + refrain + refrain).enumerated().map { index, text in
        LyricLine(start: 10 + Double(index) * 3, end: 13 + Double(index) * 3, text: text)
    }

    /// The lines as a recogniser hears them in a recording that runs
    /// `shift` seconds later, between `from` and `to` of that recording.
    static func heard(_ lines: [LyricLine] = lyrics, shift: Double, from: Double = 0, to: Double = .infinity, keep: (Int) -> Bool = { _ in true }) -> [RecognizedWord] {
        var count = 0
        return lines.flatMap { line in
            AlignmentFixtures.heard(line.text, from: line.start + shift)
        }.filter { word in
            defer { count += 1 }
            return word.start >= from && word.start < to && keep(count)
        }
    }

    @Test("A video's intro: the first half minute tells how much later the song runs")
    func intro() throws {
        let shift = try #require(LyricShiftEstimator.estimate(lines: Self.lyrics, words: Self.heard(shift: 6.5, to: 30)))
        #expect(abs(shift.seconds - 6.5) < 0.05)
        #expect(shift.isConfident && shift.lines >= 4)
        #expect(shift.score > shift.rivalScore * 4, "only small words are anywhere else")
    }

    @Test("Any stretch will do, earlier or later, with words missed and misheard")
    func anyStretch() throws {
        // The second verse and the refrain after it, every third word missed.
        let later = try #require(LyricShiftEstimator.estimate(
            lines: Self.lyrics, words: Self.heard(shift: 65.7, from: 100, to: 130) { !$0.isMultiple(of: 3) }
        ))
        #expect(abs(later.seconds - 65.7) < 0.5 && later.isConfident)
        // The recording starts inside the catalog's intro.
        let earlier = try #require(LyricShiftEstimator.estimate(lines: Self.lyrics, words: Self.heard(shift: -3, to: 30)))
        #expect(abs(earlier.seconds + 3) < 0.05 && earlier.isConfident)
        // Endings a recogniser gets wrong still pair up.
        let misheard = Self.heard(shift: 6.5, to: 30).map { word in
            RecognizedWord(text: word.text.count > 5 ? word.text.dropLast() + "s" : word.text, start: word.start, end: word.end)
        }
        let fuzzy = try #require(LyricShiftEstimator.estimate(lines: Self.lyrics, words: misheard))
        #expect(abs(fuzzy.seconds - 6.5) < 0.05 && fuzzy.isConfident)
    }

    @Test("The same recording as the catalog's: no shift")
    func none() throws {
        let shift = try #require(LyricShiftEstimator.estimate(lines: Self.lyrics, words: Self.heard(shift: 0, to: 40)))
        #expect(abs(shift.seconds) < 0.05 && shift.isConfident)
    }

    @Test("A refrain alone could be any of its turns: not believed")
    func refrainAlone() throws {
        // Its second turn (lines 12...15, timed from 0:46), in a recording 6.5 s later.
        let turn = Array(Self.lyrics[12...15])
        let shift = try #require(LyricShiftEstimator.estimate(lines: Self.lyrics, words: Self.heard(turn, shift: 6.5)))
        #expect(shift.lines >= 4 && shift.words >= 8, "plenty was heard")
        #expect(!shift.isConfident, "but two other turns fit as well (\(shift.score) against \(shift.rivalScore))")
        // With the verse before it, the turn is known.
        let more = try #require(LyricShiftEstimator.estimate(lines: Self.lyrics, words: Self.heard(Array(Self.lyrics[8...15]), shift: 6.5)))
        #expect(abs(more.seconds - 6.5) < 0.05 && more.isConfident)
    }

    @Test("Too little, another song's words, or nothing")
    func notEnough() {
        let line = LyricShiftEstimator.estimate(lines: Self.lyrics, words: Self.heard(Array(Self.lyrics[0...1]), shift: 6.5))
        #expect(line?.isConfident == false, "two lines are not enough")
        let other = AlignmentFixtures.sung(at: AlignmentFixtures.starts)
        #expect(LyricShiftEstimator.estimate(lines: Self.lyrics, words: other)?.isConfident != true)
        #expect(LyricShiftEstimator.estimate(lines: Self.lyrics, words: []) == nil)
        #expect(LyricShiftEstimator.estimate(lines: [], words: other) == nil)
    }
}
