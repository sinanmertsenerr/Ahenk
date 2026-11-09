import Foundation

/// One word a speech recogniser heard, with when it was said.
public struct RecognizedWord: Sendable, Equatable {
    public var text: String
    /// Seconds from the start of the audio.
    public var start: Double
    public var end: Double
    /// How sure the recogniser was (0...1).
    public var confidence: Double

    public init(text: String, start: Double, end: Double, confidence: Double = 1) {
        self.text = text
        self.start = start
        self.end = max(start, end)
        self.confidence = confidence
    }
}

/// What whisper-cli wrote about a piece of audio (`--output-json` or
/// `--output-json-full`), read into words with their times.
public struct WhisperTranscript: Sendable, Equatable {
    public var words: [RecognizedWord]
    /// The language whisper settled on ("en", "tr"), when it says.
    public var language: String?

    public enum ParseError: Error, Equatable {
        case notJSON
        case noTranscription
    }

    public init(words: [RecognizedWord], language: String? = nil) {
        self.words = words
        self.language = language
    }

    /// Reads whisper-cli's JSON. Works for a word per segment
    /// (`--max-len 1 --split-on-word`, what Ahenk asks for), for longer
    /// segments with tokens (words are put together from their pieces) and
    /// for segments without tokens (the words share the segment's time by
    /// their length). Sounds that are not words ("[Music]", "♪") and
    /// whisper's own markers are left out.
    public init(json data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        guard let segments = root["transcription"] as? [[String: Any]] else { throw ParseError.noTranscription }
        language = (root["result"] as? [String: Any])?["language"] as? String
        var words: [RecognizedWord] = []
        for segment in segments {
            guard let span = Self.span(segment["offsets"]) else { continue }
            let text = (segment["text"] as? String) ?? ""
            let tokens = (segment["tokens"] as? [[String: Any]]) ?? []
            var pieces = Self.words(fromTokens: tokens)
            if pieces.isEmpty {
                pieces = Self.words(fromText: text, start: span.start, end: span.end)
            } else if pieces.count == 1 {
                // A word per segment: the segment's own times are the
                // better ones (the token's end stops before the word does).
                pieces[0].start = span.start
                pieces[0].end = max(span.start, span.end)
            }
            words.append(contentsOf: pieces)
        }
        self.words = words.filter { Self.isWord($0.text) }.sorted { $0.start < $1.start }
    }

    /// Milliseconds `{"from": 190, "to": 640}` as seconds.
    private static func span(_ value: Any?) -> (start: Double, end: Double)? {
        guard let offsets = value as? [String: Any],
              let from = (offsets["from"] as? NSNumber)?.doubleValue, let to = (offsets["to"] as? NSNumber)?.doubleValue,
              from.isFinite, to.isFinite, from >= 0
        else { return nil }
        return (from / 1000, max(from, to) / 1000)
    }

    /// Tokens are pieces of words: one that starts with a space starts a
    /// word, the others continue it.
    private static func words(fromTokens tokens: [[String: Any]]) -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        var probabilities: [Double] = []
        func close() {
            guard !words.isEmpty, !probabilities.isEmpty else { return }
            words[words.count - 1].confidence = probabilities.reduce(0, +) / Double(probabilities.count)
            probabilities = []
        }
        for token in tokens {
            guard let text = token["text"] as? String, !text.hasPrefix("[_"), let span = span(token["offsets"]) else { continue }
            let probability = (token["p"] as? NSNumber)?.doubleValue ?? 1
            let startsWord = text.first?.isWhitespace == true || words.isEmpty
            let piece = text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if startsWord {
                close()
                words.append(RecognizedWord(text: piece, start: span.start, end: span.end, confidence: probability))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = max(words[words.count - 1].end, span.end)
            }
            probabilities.append(probability)
        }
        close()
        return words
    }

    /// A segment without tokens: its words share its time by their length.
    private static func words(fromText text: String, start: Double, end: Double) -> [RecognizedWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = parts.reduce(0) { $0 + max(1, $1.count) }
        guard total > 0 else { return [] }
        var words: [RecognizedWord] = []
        var cursor = start
        for part in parts {
            let length = (end - start) * Double(max(1, part.count)) / Double(total)
            words.append(RecognizedWord(text: part, start: cursor, end: cursor + length))
            cursor += length
        }
        return words
    }

    /// Something sung or said, not a marker or a description of a sound.
    static func isWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("♪"), !trimmed.contains("♫") else { return false }
        if let first = trimmed.first, let last = trimmed.last, "[(*".contains(first), "])*".contains(last), trimmed.count > 1 { return false }
        return !LyricAligner.matchWord(trimmed).isEmpty
    }
}
