import Foundation

/// A single timed word inside a word-level (karaoke) lyric line.
public struct LyricWord: Sendable, Equatable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(text: String, start: TimeInterval, end: TimeInterval? = nil) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A single lyric line. `words` is empty for line-level lyrics and filled for
/// word-level (enhanced LRC / richsync) lyrics.
public struct LyricLine: Sendable, Equatable, Codable {
    public var start: TimeInterval
    /// End of the line, usually the next line's start; `nil` for the last line.
    public var end: TimeInterval?
    public var text: String
    public var words: [LyricWord]

    public init(start: TimeInterval, end: TimeInterval? = nil, text: String, words: [LyricWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// Time-synced lyrics. LRC, enhanced LRC and richsync all normalize into this
/// one model the lyrics views drive.
public struct SyncedLyrics: Sendable, Equatable, Codable {
    /// Lines sorted ascending by `start`.
    public var lines: [LyricLine]

    public init(lines: [LyricLine]) {
        self.lines = lines.sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// True when at least one line carries per-word timing.
    public var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }

    /// A short, stable identity of the timeline (every start and text,
    /// FNV-1a). A timing correction measured for one timeline is never
    /// applied to another one of the same song.
    public var timingFingerprint: String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        for line in lines {
            mix(String(Int((line.start * 1000).rounded())))
            mix("|")
            mix(line.text)
            mix("\n")
        }
        return String(hash, radix: 16)
    }

    /// The lines with every start moved by `seconds` (never below zero).
    public func shifted(by seconds: TimeInterval) -> SyncedLyrics {
        SyncedLyrics(lines: lines.map { line in
            LyricLine(
                start: max(0, line.start + seconds),
                end: line.end.map { max(0, $0 + seconds) },
                text: line.text,
                words: line.words.map { LyricWord(text: $0.text, start: max(0, $0.start + seconds), end: $0.end.map { max(0, $0 + seconds) }) }
            )
        })
    }

    /// Index of the line to highlight at `t`: the last line whose
    /// `start <= t`, or `nil` before the first line. O(log n), so it is safe
    /// to call every frame.
    public func activeIndex(at t: TimeInterval) -> Int? {
        guard let first = lines.first, t >= first.start else { return nil }
        var low = 0
        var high = lines.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= t {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    public func line(at t: TimeInterval) -> LyricLine? {
        activeIndex(at: t).map { lines[$0] }
    }

    /// Index of the active word within the active line at `t`.
    public func activeWordIndex(at t: TimeInterval) -> (line: Int, word: Int)? {
        guard let lineIndex = activeIndex(at: t) else { return nil }
        let words = lines[lineIndex].words
        guard !words.isEmpty else { return nil }
        var answer = 0
        for (index, word) in words.enumerated() where word.start <= t {
            answer = index
        }
        return (lineIndex, answer)
    }
}
