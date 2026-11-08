import Foundation
import Testing
@testable import AhenkKit

@Suite("Logging")
struct LogFileTests {
    @Test("Writes formatted lines")
    func writesLines() throws {
        let dir = ScratchDirectory()
        let file = try LogFile(directory: dir.url)
        file.write(level: .info, category: "settings", message: "Loaded")
        file.write(level: .error, category: "demo", message: "first\nsecond")
        file.flush()
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("INFO  [settings] Loaded"))
        #expect(lines[1].hasSuffix("ERROR [demo] first"))
        #expect(lines[2] == "    second", "continuation lines are indented")
        #expect(lines[0].first?.isNumber == true, "every entry starts with a timestamp")
    }

    @Test("Appends to an existing file")
    func appends() throws {
        let dir = ScratchDirectory()
        let first = try LogFile(directory: dir.url)
        first.append(line: "one")
        first.flush()
        let second = try LogFile(directory: dir.url)
        second.append(line: "two")
        second.flush()
        #expect(try String(contentsOf: second.url, encoding: .utf8) == "one\ntwo\n")
    }

    @Test("Two writers on one file append whole lines instead of overwriting each other")
    func twoWriters() throws {
        let dir = ScratchDirectory()
        let first = try LogFile(directory: dir.url)
        let second = try LogFile(directory: dir.url)
        for index in 0..<50 {
            first.append(line: "first \(index)")
            second.append(line: "second \(index)")
            if index.isMultiple(of: 7) {
                first.flush()
                second.flush()
            }
        }
        first.flush()
        second.flush()
        let lines = try String(contentsOf: first.url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 100)
        #expect(lines.allSatisfy { $0.hasPrefix("first ") || $0.hasPrefix("second ") })
        #expect(Set(lines).count == 100)
    }

    @Test("Rolls over by size and keeps a bounded number of archives")
    func rollsOver() throws {
        let dir = ScratchDirectory()
        let file = try LogFile(directory: dir.url, maxBytes: 100, keepFiles: 2)
        let line = String(repeating: "x", count: 59) // 60 bytes with the newline
        for index in 0..<5 {
            file.append(line: "\(index)" + line.dropFirst())
        }
        file.flush()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: file.url.path))
        #expect(fm.fileExists(atPath: file.archiveURL(1).path))
        #expect(fm.fileExists(atPath: file.archiveURL(2).path))
        #expect(!fm.fileExists(atPath: file.archiveURL(3).path), "only two archives are kept")
        let live = try String(contentsOf: file.url, encoding: .utf8)
        let newest = try String(contentsOf: file.archiveURL(1), encoding: .utf8)
        #expect(live.hasPrefix("4"))
        #expect(newest.hasPrefix("3"))
        for url in [file.url, file.archiveURL(1), file.archiveURL(2)] {
            let size = try #require(try fm.attributesOfItem(atPath: url.path)[.size] as? Int)
            #expect(size <= 100)
        }
    }

    @Test("Debug lines reach the file only when verbose", .serialized, arguments: [false, true])
    func verbosity(verbose: Bool) throws {
        let dir = ScratchDirectory()
        let file = try LogFile(directory: dir.url)
        let previous = (Log.file, Log.isVerbose)
        Log.configure(file: file, verbose: verbose)
        defer { Log.configure(file: previous.0, verbose: previous.1) }

        let log = AhenkLogger(category: "test")
        log.debug("detail")
        log.info("summary")
        Log.flush()
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("[test] summary"))
        #expect(text.contains("[test] detail") == verbose)
    }

    @Test("Levels are ordered")
    func levelOrder() {
        #expect(LogLevel.debug < .info && LogLevel.info < .notice && LogLevel.notice < .error && LogLevel.error < .fault)
        #expect(Set(LogLevel.allCases.map(\.label.count)) == [5], "labels are fixed width")
    }
}
