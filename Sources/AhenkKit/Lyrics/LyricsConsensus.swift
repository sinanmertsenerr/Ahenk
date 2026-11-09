import Foundation

/// A vote between several independently written synced timelines of one
/// recording.
///
/// Community uploads for a song mostly agree, but a copy synced against
/// another edit (a longer intro, a radio cut) is shifted by an almost
/// constant amount that metadata cannot see. The timelines can: a
/// reference from each line's median start across the candidates, each
/// candidate's median deviation from it, and the best-scored candidate that
/// agrees with the majority.
public enum LyricsConsensus {
    public struct Candidate: Sendable {
        public let lyrics: SyncedLyrics
        /// The caller's metadata score; the vote overrides it only when the
        /// timelines really disagree.
        public let score: Int

        public init(lyrics: SyncedLyrics, score: Int) {
            self.lyrics = lyrics
            self.score = score
        }
    }

    /// Fewer than three timelines have no majority.
    static let minimumCandidates = 3
    /// Lines a candidate must share with the reference for its shift to mean anything.
    static let minimumSharedLines = 5
    /// Hand-typed timestamps jitter by about ±0.1–0.2 s without being wrong.
    static let agreementBand: TimeInterval = 0.2

    /// The index of the elected candidate, or nil when the vote does not
    /// apply (too few candidates or shared lines) or is not needed (all
    /// agree): the caller keeps its own order then.
    public static func pick(_ candidates: [Candidate]) -> Int? {
        guard candidates.count >= minimumCandidates else { return nil }
        let timelines = candidates.map { timeline($0.lyrics) }

        // Reference: per-line medians over the lines a majority shares (a
        // line only one candidate has would measure it against itself).
        var occurrences: [String: [TimeInterval]] = [:]
        for timeline in timelines {
            for (text, start) in timeline { occurrences[text, default: []].append(start) }
        }
        let majority = candidates.count / 2 + 1
        let reference = occurrences.compactMapValues { starts in starts.count >= majority ? median(starts) : nil }

        // Each candidate's constant shift: the median of its deviations
        // shrugs off a few misplaced repeats.
        let shifts: [(index: Int, shift: TimeInterval)] = timelines.enumerated().compactMap { index, timeline in
            let deviations = timeline.compactMap { text, start in reference[text].map { start - $0 } }
            guard deviations.count >= minimumSharedLines else { return nil }
            return (index, median(deviations))
        }
        guard shifts.count >= minimumCandidates else { return nil }
        guard shifts.contains(where: { abs($0.shift) > agreementBand }) else { return nil }

        // The best-scored candidate inside the band; if the band is empty
        // (an even split), the least shifted one, score breaking ties.
        let agreeing = shifts.filter { abs($0.shift) <= agreementBand }
        if let best = agreeing.max(by: { candidates[$0.index].score < candidates[$1.index].score }) {
            return best.index
        }
        return shifts.min {
            (abs($0.shift), -Double(candidates[$0.index].score)) < (abs($1.shift), -Double(candidates[$1.index].score))
        }?.index
    }

    /// The first start of each normalized line text (repeats are ignored so
    /// a chorus never pairs line 3 of one copy with line 40 of another).
    private static func timeline(_ lyrics: SyncedLyrics) -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for line in lyrics.lines {
            let text = LyricsQuery.matchText(line.text)
            guard text.count >= 3, result[text] == nil else { continue }
            result[text] = line.start
        }
        return result
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
