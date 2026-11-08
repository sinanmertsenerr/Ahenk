import Foundation
import Testing

/// Repository-level checks of the app's UI text: every key used through
/// `.l10n` / `L10n.format` has a Turkish entry, every entry is used, format
/// specifiers line up, no suffix is glued onto a placeholder, and SwiftUI
/// controls never get an untranslated literal.
@Suite("Localization coverage")
struct LocalizationCoverageTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let appSources = root.appendingPathComponent("Sources/AhenkApp")
    static let turkishTable = root.appendingPathComponent("Sources/AhenkApp/Resources/tr.lproj/Localizable.strings")

    /// Literals that are deliberately not translated.
    static let untranslatedLiterals: Set<String> = ["", "Ahenk"]

    struct SourceFile {
        let name: String
        let text: String
    }

    static func sourceFiles() throws -> [SourceFile] {
        let enumerator = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
        var files: [SourceFile] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(SourceFile(name: url.lastPathComponent, text: try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    /// Swift string-literal escapes → characters.
    static func unescape(_ literal: String) -> String {
        var result = ""
        var iterator = literal.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "u":
                _ = iterator.next() // "{"
                var hex = ""
                while let digit = iterator.next(), digit != "}" { hex.append(digit) }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            default: result.append(next)
            }
        }
        return result
    }

    static let literal = #""((?:[^"\\]|\\.)*)""#

    /// Every localization key in the app, with the files that use it.
    static func usedKeys() throws -> [String: Set<String>] {
        var keys: [String: Set<String>] = [:]
        for file in try sourceFiles() {
            let found = matches(literal + #"\s*\.l10n\b"#, in: file.text)
                + matches(#"L10n\.(?:format|string)\(\s*"# + literal, in: file.text)
            for raw in found {
                keys[unescape(raw), default: []].insert(file.name)
            }
        }
        return keys
    }

    static func turkishEntries() throws -> [String: String] {
        let data = try Data(contentsOf: turkishTable)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String])
    }

    static func specifiers(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]"#
        return matches(pattern, in: text, group: 0)
            .map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .sorted()
    }

    @Test("Every key used in the app has a Turkish translation")
    func everyKeyIsTranslated() throws {
        let used = try Self.usedKeys()
        let turkish = try Self.turkishEntries()
        #expect(used.count > 100, "the scanner found the app's keys")
        for (key, files) in used.sorted(by: { $0.key < $1.key }) where turkish[key] == nil {
            Issue.record("Missing Turkish for \u{201C}\(key)\u{201D} (used in \(files.sorted().joined(separator: ", ")))")
        }
    }

    @Test("Every Turkish entry is still used")
    func everyEntryIsUsed() throws {
        let used = try Self.usedKeys()
        for key in try Self.turkishEntries().keys.sorted() where used[key] == nil {
            Issue.record("Unused Turkish entry \u{201C}\(key)\u{201D}; remove it")
        }
    }

    @Test("Keys are plain literals")
    func keysAreLiterals() throws {
        for key in try Self.usedKeys().keys {
            #expect(!key.contains("\\("), "Interpolation inside a localization key: \(key)")
            #expect(key == key.trimmingCharacters(in: .whitespacesAndNewlines), "Stray whitespace in \u{201C}\(key)\u{201D}")
        }
    }

    @Test("Translations keep the format specifiers")
    func formatSpecifiersMatch() throws {
        for (key, value) in try Self.turkishEntries() {
            #expect(Self.specifiers(key) == Self.specifiers(value), "Specifiers differ: \u{201C}\(key)\u{201D} vs \u{201C}\(value)\u{201D}")
            #expect(!value.isEmpty, "Empty translation for \u{201C}\(key)\u{201D}")
        }
    }

    @Test("No suffix is glued onto a placeholder")
    func noGluedSuffixes() throws {
        for (key, value) in try Self.turkishEntries() {
            let glued = Self.matches(#"%(?:\d+\$)?(?:@|l{0,2}[dui])['’]\p{L}"#, in: value, group: 0)
            #expect(glued.isEmpty, "\u{201C}\(value)\u{201D} (for \u{201C}\(key)\u{201D}) glues a suffix onto a placeholder; rephrase")
        }
    }

    @Test("The table has no duplicate keys")
    func noDuplicateKeys() throws {
        let text = try String(contentsOf: Self.turkishTable, encoding: .utf8)
        let keys = text.split(separator: "\n").flatMap { Self.matches(#"^\s*"# + Self.literal + #"\s*="#, in: String($0)) }
        let duplicates = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "Duplicate keys: \(duplicates.sorted())")
    }

    @Test("SwiftUI controls never get an untranslated literal")
    func noBareLiterals() throws {
        let pattern = #"\b(?:Text|Toggle|Button|Picker|Section|Label|LabeledContent|Menu|Link|ToggleRow|SliderRow|EmptyRow)\(\s*(?:title:\s*|text:\s*)?"# + Self.literal + #"(?!\s*\.l10n)"#
        for file in try Self.sourceFiles() {
            for raw in Self.matches(pattern, in: file.text) where !Self.untranslatedLiterals.contains(raw) {
                Issue.record("\(file.name): \u{201C}\(raw)\u{201D} is shown without .l10n")
            }
        }
    }

    @Test("Permission texts exist in English and Turkish")
    func infoPlistStrings() throws {
        func load(_ language: String) throws -> [String: String] {
            let url = Self.root.appendingPathComponent("Packaging/\(language).lproj/InfoPlist.strings")
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try #require(plist as? [String: String])
        }
        let english = try load("en")
        let turkish = try load("tr")
        #expect(Set(english.keys) == Set(turkish.keys))
        for key in ["NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"] {
            #expect(english[key]?.isEmpty == false, "\(key) missing in English")
            #expect(turkish[key]?.isEmpty == false, "\(key) missing in Turkish")
        }
    }
}
