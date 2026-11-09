import Foundation

/// Plain lyrics timed against the words a recogniser heard in the song.
public struct LyricAlignment: Sendable, Equatable {
    public enum Quality: String, Sendable, Equatable {
        /// Most lines were found in the song.
        case good
        /// Some were found, the rest are placed between them.
        case rough
        /// Too few: the words are not this song's (or nothing was heard).
        case failed
    }

    public var lyrics: SyncedLyrics
    /// Words of the lyrics found among the recognised ones.
    public var matchedWords: Int
    public var totalWords: Int
    /// Lines with at least one word found (their time is heard, not guessed).
    public var anchoredLines: Int
    public var totalLines: Int
    public var quality: Quality

    /// Share of the lyrics' words that were found.
    public var coverage: Double { totalWords > 0 ? Double(matchedWords) / Double(totalWords) : 0 }
}

/// Times plain lyrics against the song, on this Mac: the words a speech
/// recogniser heard (with their times) are lined up with the words of the
/// lyrics, and every line gets the time of its first word.
///
/// 1. Both sides are reduced to bare words (case, accents and punctuation
///    folded; the Turkish dotless i read as i).
/// 2. The two word sequences are aligned in order. Equal words pair up,
///    nearly equal ones too (a recogniser mishears endings); runs of
///    neighbours count for more than scattered words, so a refrain is
///    matched where it is sung, not where its words first appear.
/// 3. A line with words that were found takes their times; its other
///    words are spread between them. A line without any is placed between
///    its neighbours by its length (the fallback for what the recogniser
///    missed), and carries no word times.
///
/// Pure and deterministic; the audio and the recogniser are someone else's.
public enum LyricAligner {
    /// A lyric line counts as heard with this share of the lyrics…
    static let goodLineShare = 0.7
    /// …and the result is still usable with this one.
    static let roughLineShare = 0.3
    /// How alike two words must be to pair up when they are not equal.
    static let fuzzyThreshold = 0.72

    // MARK: Text

    /// The lines to align from pasted or found lyrics: trimmed, without
    /// empty lines and section headings ("[Chorus]", "(Verse 2)").
    public static func plainLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isHeading(line), !words(of: line).isEmpty else { return nil }
            return line
        }
    }

    static func isHeading(_ line: String) -> Bool {
        guard let first = line.first, let last = line.last, line.count > 2 else { return false }
        return (first == "[" && last == "]") || (first == "(" && last == ")" && line.count < 28
            && line.range(of: "^\\((verse|chorus|bridge|intro|outro|refrain|hook|pre-chorus|nakarat|giriş|köprü)\\b", options: [.regularExpression, .caseInsensitive]) != nil)
    }

    /// One word as it is compared: letters and digits only, folded.
    public static func matchWord(_ text: String) -> String {
        LyricsQuery.matchText(text).replacingOccurrences(of: " ", with: "")
    }

    /// The comparable words of a text; hyphenated words count one by one.
    static func words(of text: String) -> [String] {
        text.split { $0.isWhitespace || "-–—/".contains($0) }.map { matchWord(String($0)) }.filter { !$0.isEmpty }
    }

    /// 1 for equal words, towards 0 the more letters differ; short words
    /// must be equal.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let first = Array(a.unicodeScalars)
        let second = Array(b.unicodeScalars)
        guard min(first.count, second.count) >= 3, abs(first.count - second.count) <= 2 else { return 0 }
        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let change = first[i - 1] == second[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + change)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[second.count]) / Double(max(first.count, second.count))
    }

    // MARK: Aligning

    /// - Parameters:
    ///   - lines: the lyrics, one entry a line (see ``plainLines(_:)``).
    ///   - words: what the recogniser heard, times from the start of the audio.
    ///   - audioStart: the song's position at the start of the audio (0
    ///     for a whole file; later when only the rest of the song was heard).
    ///   - audioEnd: the song's position at the end of the audio.
    ///   - songDuration: the song's length, when known.
    public static func align(
        lines: [String], words recognized: [RecognizedWord], audioStart: Double = 0, audioEnd: Double? = nil, songDuration: Double? = nil
    ) -> LyricAlignment {
        // The lyrics as one sequence of comparable words.
        struct Entry {
            var key: String
            var line: Int
            /// Which word of the line as it is displayed.
            var display: Int
        }
        var entries: [Entry] = []
        var displayWords: [[String]] = []
        for (index, line) in lines.enumerated() {
            let shown = line.split(whereSeparator: \.isWhitespace).map(String.init)
            displayWords.append(shown)
            for (position, word) in shown.enumerated() {
                for key in words(of: word) { entries.append(Entry(key: key, line: index, display: position)) }
            }
        }
        // What was heard, the same way (a heard "paper-boat" is two words
        // sharing its time).
        var heard: [(key: String, start: Double, end: Double)] = []
        for word in recognized.sorted(by: { $0.start < $1.start }) {
            let keys = words(of: word.text)
            guard !keys.isEmpty, word.start.isFinite, word.end.isFinite else { continue }
            let step = (word.end - word.start) / Double(keys.count)
            for (index, key) in keys.enumerated() {
                heard.append((key, audioStart + word.start + step * Double(index), audioStart + word.start + step * Double(index + 1)))
            }
        }

        let pairs = pair(entries.map(\.key), heard.map(\.key))
        // Typical length of a sung word, for the words that were not heard.
        let lengths = pairs.map { heard[$0.heard].end - heard[$0.heard].start }.filter { $0 > 0.02 }.sorted()
        let wordLength = min(0.7, max(0.18, lengths.isEmpty ? 0.35 : lengths[lengths.count / 2]))

        // Times of the displayed words that were heard.
        var times: [[(start: Double, end: Double)?]] = displayWords.map { [(start: Double, end: Double)?](repeating: nil, count: $0.count) }
        for pair in pairs {
            let entry = entries[pair.lyric]
            let span = heard[pair.heard]
            if let known = times[entry.line][entry.display] {
                times[entry.line][entry.display] = (min(known.start, span.start), max(known.end, span.end))
            } else {
                times[entry.line][entry.display] = (span.start, span.end)
            }
        }

        // Lines with a heard word: every word gets a time.
        var starts = [Double?](repeating: nil, count: lines.count)
        var ends = [Double?](repeating: nil, count: lines.count)
        var lineWords: [[LyricWord]] = Array(repeating: [], count: lines.count)
        for index in lines.indices {
            let known = times[index]
            guard let firstKnown = known.firstIndex(where: { $0 != nil }), let lastKnown = known.lastIndex(where: { $0 != nil }) else { continue }
            var spans = [(start: Double, end: Double)](repeating: (0, 0), count: known.count)
            for position in known.indices {
                if let span = known[position] {
                    spans[position] = span
                } else if position < firstKnown {
                    let first = known[firstKnown]!.start
                    let start = first - Double(firstKnown - position) * wordLength
                    spans[position] = (start, start + wordLength)
                } else if position > lastKnown {
                    let last = known[lastKnown]!.end
                    let start = last + Double(position - lastKnown - 1) * wordLength
                    spans[position] = (start, start + wordLength)
                } else {
                    // Between two heard words: an even share of what lies between.
                    let before = known[..<position].lastIndex { $0 != nil }!
                    let after = known[(position + 1)...].firstIndex { $0 != nil }!
                    let from = known[before]!.end
                    let to = max(from, known[after]!.start)
                    let share = (to - from) / Double(after - before - 1)
                    let start = from + share * Double(position - before - 1)
                    spans[position] = (start, start + share)
                }
            }
            starts[index] = max(0, spans[0].start)
            ends[index] = max(spans[spans.count - 1].end, spans[0].start + 0.2)
            lineWords[index] = zip(displayWords[index], spans).map { LyricWord(text: $0, start: max(0, $1.start), end: max(0, $1.end)) }
        }
        let anchored = starts.compactMap { $0 }.count

        // Lines without one: placed between their neighbours by length.
        func needed(_ index: Int) -> Double { Double(max(1, displayWords[index].count)) * wordLength * 1.5 + 0.4 }
        let limit = songDuration.flatMap { $0 > 0 ? $0 : nil } ?? audioEnd
        var index = 0
        while index < lines.count {
            guard starts[index] == nil else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < lines.count, starts[last + 1] == nil { last += 1 }
            let group = Array(index...last)
            let total = group.reduce(0) { $0 + needed($1) }
            let before = index > 0 ? ends[index - 1] : nil
            let after = last + 1 < lines.count ? starts[last + 1] : nil
            var from: Double
            var scale = 1.0
            switch (before, after) {
            case let (before?, after?):
                let room = max(0.1, after - before)
                if total >= room {
                    from = before
                    scale = room / total
                } else if room <= total * 2.5 {
                    // About as much room as the lines need: share it out.
                    from = before
                    scale = room / total
                } else {
                    // A long stretch (an instrumental part): the lines lead
                    // into the next one that was heard.
                    from = after - total
                }
            case let (nil, after?):
                from = max(0, after - total)
                if after < total { scale = max(0.05, after) / total }
            case let (before?, nil):
                from = before + 0.3
                if let limit, limit > from, from + total > limit { scale = (limit - from) / total }
            case (nil, nil):
                // Nothing was heard at all: an even spread, good for nothing
                // but keeping the lines in order.
                from = audioStart
                if let limit, limit > from { scale = (limit - from) / total }
            }
            var cursor = from
            for line in group {
                let length = needed(line) * scale
                starts[line] = cursor
                ends[line] = cursor + length
                cursor += length
            }
            index = last + 1
        }

        // In order, never two lines at once.
        var timed: [LyricLine] = []
        var previousStart = -1.0
        for index in lines.indices {
            var start = max(0, starts[index] ?? 0)
            if start < previousStart + 0.05 { start = previousStart + 0.05 }
            previousStart = start
            let end = max(start + 0.1, ends[index] ?? start + 0.1)
            let words = lineWords[index].map { LyricWord(text: $0.text, start: max(start, $0.start), end: $0.end.map { max(start, $0) }) }
            timed.append(LyricLine(start: start, end: end, text: lines[index], words: words))
        }

        let share = lines.isEmpty ? 0 : Double(anchored) / Double(lines.count)
        let quality: LyricAlignment.Quality
        if lines.isEmpty || anchored < min(2, lines.count) || share < roughLineShare {
            quality = .failed
        } else if share >= goodLineShare {
            quality = .good
        } else {
            quality = .rough
        }
        return LyricAlignment(
            lyrics: SyncedLyrics(lines: timed), matchedWords: pairs.count, totalWords: entries.count,
            anchoredLines: anchored, totalLines: lines.count, quality: quality
        )
    }

    /// Pairs the lyrics' words with the heard ones, in order: the pairing
    /// with the highest score, where equal words score, nearly equal ones
    /// score less, neighbours in a row score extra and skipped words cost a
    /// little. Lone short words far from any other pair are dropped: "the"
    /// is heard everywhere.
    static func pair(_ lyric: [String], _ heard: [String]) -> [(lyric: Int, heard: Int)] {
        let n = lyric.count
        let m = heard.count
        guard n > 0, m > 0 else { return [] }
        let width = m + 1
        let unreachable: Float = -1e9
        // `best`: the best score up to here; `ending`: the best that ends
        // with these two words paired.
        var best = [Float](repeating: 0, count: (n + 1) * width)
        var ending = [Float](repeating: unreachable, count: (n + 1) * width)
        // 0: these two paired; 1: the lyric word skipped; 2: the heard one.
        var step = [UInt8](repeating: 1, count: (n + 1) * width)
        // The pair continues a run of pairs.
        var run = [Bool](repeating: false, count: (n + 1) * width)
        let skip: Float = 0.04
        let runBonus: Float = 1.2
        for j in 0...m { step[j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let cell = i * width + j
                let diagonal = cell - width - 1
                var score: Float = unreachable
                let alike = similarity(lyric[i - 1], heard[j - 1])
                if alike >= fuzzyThreshold {
                    let own = alike == 1 ? 2 + Float(min(6, lyric[i - 1].count)) * 0.1 : Float(alike) * 2 - 0.5
                    let continued = ending[diagonal] + runBonus
                    if ending[diagonal] > unreachable / 2, continued >= best[diagonal] {
                        score = own + continued
                        run[cell] = true
                    } else {
                        score = own + best[diagonal]
                    }
                }
                ending[cell] = score
                let up = best[cell - width] - skip
                let left = best[cell - 1] - skip
                if score >= up, score >= left {
                    best[cell] = score
                    step[cell] = 0
                } else if up >= left {
                    best[cell] = up
                    step[cell] = 1
                } else {
                    best[cell] = left
                    step[cell] = 2
                }
            }
        }
        var pairs: [(lyric: Int, heard: Int)] = []
        var i = n
        var j = m
        var forced = false
        while i > 0, j > 0 {
            let cell = i * width + j
            if forced || step[cell] == 0 {
                pairs.append((i - 1, j - 1))
                // A pair that continues a run is preceded by a pair.
                forced = run[cell]
                i -= 1
                j -= 1
            } else if step[cell] == 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        pairs.reverse()
        // Lone short words prove nothing.
        return pairs.enumerated().filter { index, pair in
            guard lyric[pair.lyric].count <= 3 else { return true }
            let previous = index > 0 ? pairs[index - 1] : nil
            let next = index + 1 < pairs.count ? pairs[index + 1] : nil
            let joinsPrevious = previous.map { pair.lyric - $0.lyric <= 2 && pair.heard - $0.heard <= 3 } ?? false
            let joinsNext = next.map { $0.lyric - pair.lyric <= 2 && $0.heard - pair.heard <= 3 } ?? false
            return joinsPrevious || joinsNext
        }.map(\.element)
    }
}
