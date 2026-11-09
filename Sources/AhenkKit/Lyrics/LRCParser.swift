import Foundation

/// Reads LRC and enhanced ("A2", word-level) LRC into `SyncedLyrics`.
///
/// Handles:
/// - several timestamps on one line: `[00:01.00][00:05.00]text`
/// - tenths, hundredths and thousandths: `[00:01.5]`, `[00:01.50]`, `[00:01.500]`,
///   and the rarer `[00:01:50]`
/// - metadata tags (`[ar:]`, `[ti:]`, `[al:]`, `[length:]`, `[offset:]`)
/// - word tags: `[00:01.00]<00:01.00>Hello <00:01.50>world`
/// - a byte-order mark, indentation and Windows line ends
///
/// A timed line without text is kept (empty `text`): providers write one
/// where the singing stops, and `LyricsTimeline` reads it as the start of
/// an instrumental part. Text is trimmed.
public enum LRCParser {
    public static func parse(_ text: String) -> SyncedLyrics {
        var offset: TimeInterval = 0
        var lines: [LyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            var cursor = line.startIndex
            var times: [TimeInterval] = []

            // Leading `[...]` groups: timestamps or metadata.
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                let inside = line[line.index(after: cursor)..<close]
                if let time = parseTime(inside) {
                    times.append(time)
                } else if let colon = inside.firstIndex(of: ":") {
                    let key = inside[..<colon].lowercased()
                    let value = inside[inside.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if key == "offset", let milliseconds = Double(value), milliseconds.isFinite {
                        offset = milliseconds / 1000
                    }
                }
                cursor = line.index(after: close)
            }

            guard !times.isEmpty else { continue }
            let content = String(line[cursor...])

            if times.count == 1 {
                let start = max(0, times[0] - offset)
                let (lineText, words) = parseWords(content, lineStart: start)
                lines.append(LyricLine(start: start, end: nil, text: lineText, words: words))
            } else {
                // Word timing on a line with several timestamps is too rare
                // to model; each timestamp gets the plain line.
                let stripped = stripWordTags(content).trimmingCharacters(in: .whitespaces)
                for time in times {
                    lines.append(LyricLine(start: max(0, time - offset), end: nil, text: stripped, words: []))
                }
            }
        }

        // Stable: lines with the same timestamp keep their order.
        lines = lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        for index in lines.indices.dropLast() {
            lines[index].end = lines[index + 1].start
            // The last word of a word-timed line ends with the line.
            if var last = lines[index].words.last, last.end == nil {
                last.end = lines[index].end
                lines[index].words[lines[index].words.count - 1] = last
            }
        }
        return SyncedLyrics(lines: lines)
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, and `mm:ss:xx`.
    static func parseTime<S: StringProtocol>(_ text: S) -> TimeInterval? {
        let colonParts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard colonParts.count == 2 || colonParts.count == 3 else { return nil }
        guard let minutes = Int(colonParts[0]) else { return nil }
        let dotParts = colonParts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard dotParts.count <= 2, let seconds = Int(dotParts[0]), seconds >= 0 else { return nil }
        var fraction: Double = 0
        if dotParts.count > 1 {
            let digits = dotParts[1]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let raw = Double(digits) else { return nil }
            fraction = raw / pow(10, Double(digits.count))
        } else if colonParts.count == 3 {
            let digits = colonParts[2]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let raw = Double(digits) else { return nil }
            fraction = raw / pow(10, Double(digits.count))
        }
        let value = Double(minutes) * 60 + Double(seconds) + fraction
        return value.isFinite ? value : nil
    }

    /// Splits enhanced-LRC content (`<t>word <t2>word2`) into the plain line
    /// and the timed words. Text before the first tag starts with the line.
    static func parseWords(_ content: String, lineStart: TimeInterval) -> (text: String, words: [LyricWord]) {
        guard content.contains("<") else {
            return (content.trimmingCharacters(in: .whitespaces), [])
        }
        var words: [LyricWord] = []
        var buffer = ""
        var currentTime = lineStart
        var index = content.startIndex

        func flush() {
            if !buffer.isEmpty {
                words.append(LyricWord(text: buffer, start: currentTime, end: nil))
                buffer = ""
            }
        }

        while index < content.endIndex {
            if content[index] == "<", let close = content[index...].firstIndex(of: ">") {
                let inside = content[content.index(after: index)..<close]
                if let time = parseTime(inside) {
                    flush()
                    currentTime = time
                    index = content.index(after: close)
                    continue
                }
            }
            buffer.append(content[index])
            index = content.index(after: index)
        }
        flush()
        // Whitespace-only "words" (a tag before a space) carry no text.
        words.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        for wordIndex in words.indices.dropLast() {
            words[wordIndex].end = words[wordIndex + 1].start
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return (text.isEmpty ? stripWordTags(content).trimmingCharacters(in: .whitespaces) : text, words)
    }

    /// Removes `<mm:ss.xx>` word tags, leaving the plain text.
    static func stripWordTags(_ content: String) -> String {
        guard content.contains("<") else { return content }
        var output = ""
        var index = content.startIndex
        while index < content.endIndex {
            if content[index] == "<", let close = content[index...].firstIndex(of: ">"),
               parseTime(content[content.index(after: index)..<close]) != nil {
                index = content.index(after: close)
                continue
            }
            output.append(content[index])
            index = content.index(after: index)
        }
        return output
    }
}
