import Foundation

/// An append-only text log that rolls over by size:
/// `Ahenk.log` → `Ahenk.1.log` → … → `Ahenk.<keep>.log` (oldest, then deleted).
///
/// Writes are queued on a private serial queue so callers never wait for the
/// disk; `flush()` waits for everything queued so far. The file is opened
/// with O_APPEND, so a second process writing to the same log (a smoke run
/// next to a running app) appends whole lines instead of overwriting them.
public final class LogFile: @unchecked Sendable {
    // Safety: all mutable state below is only touched on `queue`.
    public let directory: URL
    public let baseName: String
    public let maxBytes: Int
    public let keepFiles: Int

    private let queue = DispatchQueue(label: "com.sinanmertsener.Ahenk.log-file", qos: .utility)
    private var handle: FileHandle?
    private var size = 0
    private let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    /// The live file, e.g. `~/Library/Logs/Ahenk/Ahenk.log`.
    public var url: URL { directory.appendingPathComponent("\(baseName).log") }

    /// URL of the `index`-th archive (1 is the newest).
    public func archiveURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(baseName).\(index).log")
    }

    public init(directory: URL, baseName: String = "Ahenk", maxBytes: Int = 1_000_000, keepFiles: Int = 3) throws {
        precondition(maxBytes > 0 && keepFiles >= 0)
        self.directory = directory
        self.baseName = baseName
        self.maxBytes = maxBytes
        self.keepFiles = keepFiles
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try queue.sync { try openLiveFile() }
    }

    deinit {
        try? handle?.close()
    }

    /// Formats and appends one entry. Multi-line messages are indented so
    /// each entry still starts with a timestamp.
    public func write(level: LogLevel, category: String, message: String, date: Date = Date()) {
        let stamp = date.formatted(timestampStyle)
        let body = message.replacingOccurrences(of: "\n", with: "\n    ")
        append(line: "\(stamp) \(level.label) [\(category)] \(body)")
    }

    /// Appends `line` plus a newline.
    public func append(line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            do {
                if handle == nil { try openLiveFile() }
                refreshSize()
                if size > 0, size + data.count > maxBytes { try roll() }
                try handle?.write(contentsOf: data)
                size += data.count
            } catch {
                // Logging must never take the app down; drop the line.
                handle = nil
            }
        }
    }

    /// Waits until every queued line has been written.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    // MARK: Queue-confined

    private func openLiveFile() throws {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        refreshSize()
    }

    /// Other processes may have appended since the last write.
    private func refreshSize() {
        guard let handle else { return }
        var info = stat()
        if fstat(handle.fileDescriptor, &info) == 0 {
            size = Int(info.st_size)
        }
    }

    private func roll() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        if keepFiles == 0 {
            try? fm.removeItem(at: url)
        } else {
            try? fm.removeItem(at: archiveURL(keepFiles))
            if keepFiles > 1 {
                for index in stride(from: keepFiles - 1, through: 1, by: -1) {
                    let source = archiveURL(index)
                    if fm.fileExists(atPath: source.path) {
                        try fm.moveItem(at: source, to: archiveURL(index + 1))
                    }
                }
            }
            try fm.moveItem(at: url, to: archiveURL(1))
        }
        try openLiveFile()
    }
}
