import Foundation

/// How far a recording runs from the timing of its lyrics, heard from its
/// words.
public struct LyricShift: Sendable, Equatable {
    /// A line timed at `t` is sung at `t + seconds` in this recording
    /// (positive: the recording starts later, as a video with an intro).
    public var seconds: Double
    /// Lyric lines with a heard word that says so.
    public var lines: Int
    /// Heard words that say so.
    public var words: Int
    /// How much says so, and how much says the best other answer.
    public var score: Double
    public var rivalScore: Double

    /// Enough lines and words agree and no other answer has more: likely
    /// right, though a refrain may still speak for another (not yet
    /// `isConfident`). Good enough to act on while more is heard.
    public var isLikely: Bool {
        lines >= LyricShiftEstimator.minimumLines && words >= LyricShiftEstimator.minimumWords && score > rivalScore
    }

    /// Enough lines and words agree, clearly ahead of any other answer.
    public var isConfident: Bool {
        lines >= LyricShiftEstimator.minimumLines && words >= LyricShiftEstimator.minimumWords
            && score >= rivalScore * LyricShiftEstimator.minimumLead
    }
}

/// Finds the one shift between timed lyrics and a recording of the song
/// that carries them at other times: a music video with an intro plays the
/// album's recording later than the catalogs time it. Any stretch of the
/// song will do, since nothing is assumed about where it starts.
///
/// Every heard word votes for each place the lyrics have that word: "sung
/// at 31.2 s, timed at 25.0 s" is a vote for +6.2 s. A word the lyrics
/// repeat splits its vote among its places. The true shift collects the
/// votes of everything heard; a wrong one only those of a refrain heard at
/// another of its turns. So a stretch with nothing but a refrain has two
/// answers about as good, and is not believed (`LyricShift.isConfident`).
///
/// Pure and deterministic; the audio and the recogniser are someone else's.
public enum LyricShiftEstimator {
    public static let minimumLines = 4
    public static let minimumWords = 8
    /// The answer must collect this many times what the best other one does.
    public static let minimumLead = 1.5
    /// Votes are counted in steps this wide…
    static let step = 0.5
    /// …and a vote this close to the answer agrees with it.
    static let tolerance = 0.75
    /// Another answer is one at least this far away.
    static let rivalDistance = 2.0

    /// - Parameters:
    ///   - lines: the lyrics with their own timing.
    ///   - words: what the recogniser heard, at the song's own positions.
    ///   - range: the shifts that are possible at all, when that is known
    ///     (a song inside a clip of a known length): votes for any other
    ///     are a refrain heard at another of its turns, and are left out.
    /// - Returns: the shift most of what was heard agrees on; `nil` when no
    ///   heard word is in the lyrics.
    public static func estimate(lines: [LyricLine], words heard: [RecognizedWord], within range: ClosedRange<Double>? = nil) -> LyricShift? {
        struct Place {
            var key: String
            var time: Double
            var line: Int
            /// Which word of its line: the first one's time is the line's own.
            var position: Int
        }
        let sung = lines.filter { LyricsTimeline.isSung($0.text) }.sorted { $0.start < $1.start }
        var places: [Place] = []
        for (index, line) in sung.enumerated() {
            let keys = LyricAligner.words(of: line.text)
            guard !keys.isEmpty else { continue }
            // The words share the line's time, at a sung word's pace at most.
            let next = index + 1 < sung.count ? sung[index + 1].start : line.start + 4
            let room = max(0.2, min(line.end ?? next, next) - line.start)
            let span = min(room, 0.45 * Double(keys.count) + 0.3)
            for (position, key) in keys.enumerated() {
                places.append(Place(key: key, time: line.start + span * Double(position) / Double(keys.count), line: index, position: position))
            }
        }
        guard !places.isEmpty else { return nil }

        struct Vote {
            var shift: Double
            var weight: Double
            var place: Int
            var word: Int
        }
        var votes: [Vote] = []
        var count = 0
        for word in heard where word.start.isFinite {
            for key in LyricAligner.words(of: word.text) {
                let matches = places.indices.filter { LyricAligner.similarity(places[$0].key, key) >= LyricAligner.fuzzyThreshold }
                for match in matches {
                    let shift = word.start - places[match].time
                    if let range, !range.contains(shift) { continue }
                    votes.append(Vote(shift: shift, weight: 1 / Double(matches.count), place: match, word: count))
                }
                count += 1
            }
        }
        guard !votes.isEmpty else { return nil }

        var tally: [Int: Double] = [:]
        for vote in votes { tally[Int((vote.shift / step).rounded()), default: 0] += vote.weight }
        // A shift between two steps has its votes in both.
        func around(_ slot: Int) -> Double { (tally[slot - 1] ?? 0) + (tally[slot] ?? 0) + (tally[slot + 1] ?? 0) }
        guard let best = tally.keys.max(by: { (around($0), -$0) < (around($1), -$1) }) else { return nil }
        let center = Double(best) * step
        let rival = tally.keys.filter { abs(Double($0) * step - center) >= rivalDistance }.map(around).max() ?? 0

        let agreeing = votes.filter { abs($0.shift - center) <= tolerance }
        // A line's shift is that of its earliest heard word: the nearer the
        // line's start, the less the guess about its pace matters.
        var byLine: [Int: Vote] = [:]
        for vote in agreeing {
            let line = places[vote.place].line
            if let known = byLine[line], places[known.place].position <= places[vote.place].position { continue }
            byLine[line] = vote
        }
        let shifts = byLine.values.map(\.shift).sorted()
        guard !shifts.isEmpty else { return nil }
        return LyricShift(
            seconds: shifts[shifts.count / 2], lines: byLine.count, words: Set(agreeing.map(\.word)).count,
            score: around(best), rivalScore: rival
        )
    }
}
