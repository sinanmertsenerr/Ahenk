import Foundation

/// How a song's synced lyrics unfold for the display: which line is on,
/// how far it has been sung, and where the instrumental parts are.
///
/// Built once per lyrics; `scene(at:)` is a pure function of the lyric time
/// (the song's position plus the offsets), so any moment can be drawn
/// directly (a seek, an offscreen check, a preview).
///
/// - A line's **sung end** comes from its word timing, or is estimated:
///   lines that follow each other closely are sung almost to the next one;
///   a line before a long pause lasts about as long as its words take.
/// - An **instrumental part** is a pause of at least `minimumGap` seconds
///   between the end of a line's singing and the next line, or after a
///   timed blank line (providers write one where the singing stops). The
///   **intro** before the first line and the **outro** after the last one
///   are instrumental parts too.
public struct LyricsTimeline: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let start: TimeInterval
        /// When the singing of the line ends.
        public let sungEnd: TimeInterval
        /// When the next line or instrumental part takes over.
        public let holdEnd: TimeInterval
        public let text: String
        /// Timed words; empty for line timing only.
        public let words: [LyricWord]

        /// How much of the line has been sung at `time`, 0…1, measured in
        /// characters (word timing when there is some, else even pace).
        public func progress(at time: TimeInterval) -> Double {
            guard time > start else { return 0 }
            guard time < sungEnd else { return 1 }
            guard !words.isEmpty else {
                return min(1, max(0, (time - start) / max(0.05, sungEnd - start)))
            }
            let lengths = words.map { max(1, $0.text.trimmingCharacters(in: .whitespaces).count) }
            let total = Double(lengths.reduce(0, +))
            var before = 0.0
            for (index, word) in words.enumerated() {
                let end = word.end ?? (index + 1 < words.count ? words[index + 1].start : sungEnd)
                if time < word.start { return before / total }
                if time < end {
                    let fraction = (time - word.start) / max(0.02, end - word.start)
                    return (before + fraction * Double(lengths[index])) / total
                }
                before += Double(lengths[index])
            }
            return 1
        }
    }

    public struct Gap: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case intro
            case interlude
            case outro
        }

        public let kind: Kind
        public let start: TimeInterval
        /// The next line's start; `nil` for the outro.
        public let end: TimeInterval?
        public let previousLine: Int?
        public let nextLine: Int?

        public var duration: TimeInterval? { end.map { $0 - start } }
    }

    /// Pauses at least this long between lines are instrumental parts.
    public static let defaultMinimumGap: TimeInterval = 6
    /// An intro at least this long shows the song's title.
    public static let minimumIntro: TimeInterval = 3
    /// The last line stays this long after its singing, then the outro.
    public static let outroDelay: TimeInterval = 3
    /// A line lingers this long after its singing before a pause begins.
    public static let gapTail: TimeInterval = 1

    public let lines: [Line]
    public let gaps: [Gap]

    public init(_ lyrics: SyncedLyrics, duration: TimeInterval? = nil, minimumGap: TimeInterval = LyricsTimeline.defaultMinimumGap) {
        let all = lyrics.lines
        let sung = all.enumerated().filter { Self.isSung($0.element.text) }
        var lines: [Line] = []
        var gaps: [Gap] = []

        if let first = sung.first?.element, first.start >= Self.minimumIntro {
            gaps.append(Gap(kind: .intro, start: 0, end: first.start, previousLine: nil, nextLine: 0))
        }
        for (position, entry) in sung.enumerated() {
            let line = entry.element
            let nextSung = position + 1 < sung.count ? sung[position + 1] : nil
            // A blank (or symbols-only) line between this one and the next
            // marks where the singing stops.
            let marker = all[(entry.offset + 1)...].prefix { nextSung == nil || $0.start < nextSung!.element.start }
                .first { !Self.isSung($0.text) && $0.start > line.start }
            var limit = nextSung?.element.start ?? (line.start + 10)
            if let marker { limit = min(limit, marker.start) }
            if let end = line.end, end > line.start, end < limit - 0.25 { limit = end }
            let available = max(0.3, limit - line.start)

            var sungEnd: TimeInterval
            if let lastWord = line.words.last {
                sungEnd = min(lastWord.end ?? (lastWord.start + 0.6), limit)
                sungEnd = max(sungEnd, line.start + 0.3)
            } else if available <= 6.5 {
                sungEnd = line.start + available * 0.92
            } else {
                let words = line.text.split(whereSeparator: \.isWhitespace).count
                sungEnd = line.start + min(available, min(6.5, max(1.4, 0.42 * Double(words) + 0.7)))
            }

            var holdEnd = nextSung?.element.start ?? (sungEnd + Self.outroDelay)
            if let next = nextSung {
                let explicitStop = marker != nil || (line.end.map { $0 < next.element.start - 0.25 } ?? false)
                let gapStart = explicitStop ? max(sungEnd, min(limit, sungEnd + Self.gapTail)) : sungEnd + Self.gapTail
                if next.element.start - gapStart >= minimumGap {
                    gaps.append(Gap(kind: .interlude, start: gapStart, end: next.element.start, previousLine: position, nextLine: position + 1))
                    holdEnd = gapStart
                }
            } else {
                let outroStart = sungEnd + Self.outroDelay
                if duration.map({ $0 - outroStart > 1 }) ?? true {
                    gaps.append(Gap(kind: .outro, start: outroStart, end: nil, previousLine: position, nextLine: nil))
                }
                holdEnd = outroStart
            }
            lines.append(Line(start: line.start, sungEnd: sungEnd, holdEnd: holdEnd, text: line.text, words: line.words))
        }
        self.lines = lines
        self.gaps = gaps
    }

    /// Text with a letter or a digit is sung; blanks, "♪" and "..." mark
    /// pauses.
    public static func isSung(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The line on at `time` (the last one that started), or nil.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard let first = lines.first, time >= first.start else { return nil }
        var low = 0
        var high = lines.count - 1
        var answer = 0
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].start <= time {
                answer = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return answer
    }

    /// The instrumental part `time` falls in, if any.
    public func gap(at time: TimeInterval) -> Gap? {
        gaps.first { time >= $0.start && time < ($0.end ?? .infinity) }
    }

    /// What is on screen at the lyric time `time`.
    public func scene(at time: TimeInterval, glide: TimeInterval = LyricsScene.glide, lead: TimeInterval = LyricsScene.lead) -> LyricsScene {
        var scene = LyricsScene(time: time)
        guard !lines.isEmpty else { return scene }
        func ramp(_ since: TimeInterval) -> Double { min(1, max(0, since / max(0.01, glide))) }
        func gapState(_ gap: Gap, enter: Double, exit: Double) -> LyricsScene.GapState {
            let remaining = gap.end.map { max(0, $0 - time) }
            let fraction = gap.duration.map { min(1, max(0, (time - gap.start) / max(0.01, $0))) } ?? 0
            return LyricsScene.GapState(kind: gap.kind, enter: enter, exit: exit, remaining: remaining, fraction: fraction, nextLine: gap.nextLine)
        }

        // The line whose (slightly early) entrance has begun.
        guard let index = lineIndex(at: time + lead) else {
            // Before the first line: the intro, if there is one.
            if let intro = gaps.first(where: { $0.kind == .intro }) {
                scene.gap = gapState(intro, enter: ramp(time - intro.start), exit: 0)
            }
            scene.upcoming = 0
            return scene
        }
        let line = lines[index]
        let enter = ramp(time + lead - line.start)

        // After the line: an instrumental part or the outro.
        if let gap = gaps.first(where: { $0.previousLine == index }), time >= gap.start {
            let progress = ramp(time - gap.start)
            scene.gap = gapState(gap, enter: progress, exit: 0)
            if progress < 1 {
                scene.previous = LyricsScene.LineState(index: index, enter: 1, exit: progress, sung: 1, sinceStart: time - line.start)
            }
            scene.upcoming = gap.nextLine
            return scene
        }

        scene.current = LyricsScene.LineState(index: index, enter: enter, exit: 0, sung: line.progress(at: time), sinceStart: time - line.start)
        if enter < 1 {
            if let gap = gaps.first(where: { $0.nextLine == index }) {
                scene.gap = gapState(gap, enter: 1, exit: enter)
            } else if index > 0 {
                let previous = lines[index - 1]
                scene.previous = LyricsScene.LineState(index: index - 1, enter: 1, exit: enter, sung: 1, sinceStart: time - previous.start)
            }
        }
        let next = index + 1
        if next < lines.count, !gaps.contains(where: { $0.previousLine == index && $0.kind != .outro }) {
            scene.upcoming = next
        }
        return scene
    }
}

/// What the lyrics view shows at one moment.
public struct LyricsScene: Sendable, Equatable {
    /// Seconds a line takes to glide in (and the previous one out).
    public static let glide: TimeInterval = 0.5
    /// Lines start gliding in this much before they are sung, so they are
    /// in place when the singing starts.
    public static let lead: TimeInterval = 0.18

    public struct LineState: Sendable, Equatable {
        /// Index into `LyricsTimeline.lines`.
        public var index: Int
        /// 0…1: gliding in.
        public var enter: Double
        /// 0…1: gliding out (0 while it is the current line).
        public var exit: Double
        /// 0…1: how much of it has been sung.
        public var sung: Double
        /// Seconds since the line's start (negative while it glides in early).
        public var sinceStart: TimeInterval
    }

    public struct GapState: Sendable, Equatable {
        public var kind: LyricsTimeline.Gap.Kind
        public var enter: Double
        public var exit: Double
        /// Seconds to the next line; `nil` in the outro.
        public var remaining: TimeInterval?
        /// 0…1 of the part that has passed (0 in the outro).
        public var fraction: Double
        public var nextLine: Int?

        /// The countdown's number: whole seconds left, rounded up.
        public var countdown: Int? {
            remaining.map { Int($0.rounded(.up)) }
        }
    }

    public var time: TimeInterval
    /// The line being sung (or about to be).
    public var current: LineState?
    /// The line that is leaving.
    public var previous: LineState?
    /// The line after the current one (some styles show it waiting).
    public var upcoming: Int?
    /// An instrumental part coming, on, or leaving.
    public var gap: GapState?

    public init(time: TimeInterval, current: LineState? = nil, previous: LineState? = nil, upcoming: Int? = nil, gap: GapState? = nil) {
        self.time = time
        self.current = current
        self.previous = previous
        self.upcoming = upcoming
        self.gap = gap
    }

    /// True while something glides (the view draws at its full rate then).
    public var isGliding: Bool {
        if let current, current.enter < 1 { return true }
        if previous != nil { return true }
        if let gap, gap.enter < 1 || gap.exit > 0 { return true }
        return false
    }
}
