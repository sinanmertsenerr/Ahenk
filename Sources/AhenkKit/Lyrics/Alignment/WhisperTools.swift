import Foundation

/// The two things local lyric alignment needs on this Mac: the whisper.cpp
/// command line tool and a speech model for it. Ahenk ships neither and
/// never fetches anything by itself; it looks where they usually are and
/// says what is missing.
public struct WhisperTools: Sendable, Equatable {
    public enum Part: String, Sendable, Equatable {
        /// `whisper-cli` (whisper.cpp).
        case executable
        /// A `ggml-*.bin` model file.
        case model
    }

    public var executable: URL?
    public var model: URL?

    public init(executable: URL?, model: URL?) {
        self.executable = executable
        self.model = model
    }

    public var isReady: Bool { executable != nil && model != nil }

    public var missing: [Part] {
        (executable == nil ? [.executable] : []) + (model == nil ? [.model] : [])
    }
}

/// Finds the whisper tool and a model. The file system comes in as
/// closures, so the search is tested on invented folders.
public struct WhisperLocator: Sendable {
    public var home: String
    public var isExecutable: @Sendable (String) -> Bool
    public var isFile: @Sendable (String) -> Bool
    /// File names in a folder (empty when there is none).
    public var contents: @Sendable (String) -> [String]

    public init(
        home: String, isExecutable: @escaping @Sendable (String) -> Bool, isFile: @escaping @Sendable (String) -> Bool,
        contents: @escaping @Sendable (String) -> [String]
    ) {
        self.home = home
        self.isExecutable = isExecutable
        self.isFile = isFile
        self.contents = contents
    }

    /// This Mac's file system.
    public static var system: WhisperLocator {
        WhisperLocator(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isFile: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            },
            contents: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        )
    }

    /// The names whisper.cpp's tool goes by (Homebrew's `whisper-cpp`
    /// formula installs `whisper-cli`; older ones `whisper-cpp`).
    public static let executableNames = ["whisper-cli", "whisper-cpp"]

    /// The model Ahenk suggests: the best one that runs quickly on a Mac.
    public static let suggestedModel = "ggml-large-v3-turbo-q5_0.bin"
    /// Its size, for the download button.
    public static let suggestedModelBytes: Int64 = 574_041_195
    /// Where whisper.cpp publishes its models.
    public static let suggestedModelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    public var executableFolders: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin"]
    }

    /// Ahenk's own folder first (where its download button puts a model).
    public var modelFolders: [String] {
        [
            Self.modelsFolder(home: home), home + "/Developer/whisper-models", home + "/whisper-models",
            home + "/.cache/whisper.cpp", home + "/Library/Caches/whisper.cpp",
            "/opt/homebrew/share/whisper-cpp/models", "/opt/homebrew/share/whisper-cpp", "/usr/local/share/whisper-cpp/models",
        ]
    }

    public static func modelsFolder(home: String) -> String {
        home + "/Library/Application Support/Ahenk/Models"
    }

    /// The tool and the model: the user's own choices when they exist,
    /// otherwise the first tool found and the best model found.
    public func locate(executableOverride: String? = nil, modelOverride: String? = nil) -> WhisperTools {
        var executable: String?
        if let chosen = Self.expand(executableOverride, home: home), isExecutable(chosen) {
            executable = chosen
        } else {
            search: for folder in executableFolders {
                for name in Self.executableNames where isExecutable(folder + "/" + name) {
                    executable = folder + "/" + name
                    break search
                }
            }
        }
        var model: String?
        if let chosen = Self.expand(modelOverride, home: home), isFile(chosen) {
            model = chosen
        } else {
            var bestRank = Int.max
            for folder in modelFolders {
                for name in contents(folder).sorted() {
                    guard let rank = Self.rank(ofModel: name), rank < bestRank, isFile(folder + "/" + name) else { continue }
                    bestRank = rank
                    model = folder + "/" + name
                }
            }
        }
        return WhisperTools(executable: executable.map { URL(fileURLWithPath: $0) }, model: model.map { URL(fileURLWithPath: $0) })
    }

    static func expand(_ path: String?, home: String) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
    }

    /// How good a model file is for lyrics, lower is better; `nil` for a
    /// file that is no whisper.cpp model. Larger models hear singing
    /// better; among equals a model for every language beats an
    /// English-only one, and a full one beats a compressed one.
    public static func rank(ofModel fileName: String) -> Int? {
        let name = fileName.lowercased()
        guard name.hasPrefix("ggml-"), name.hasSuffix(".bin"), !name.contains("vad"), !name.contains("encoder") else { return nil }
        let core = String(name.dropFirst(5).dropLast(4))
        let sizes = ["large-v3-turbo", "large-v3", "large-v2", "large", "medium", "small", "base", "tiny"]
        guard let size = sizes.firstIndex(where: { core == $0 || core.hasPrefix($0 + "-") || core.hasPrefix($0 + ".") }) else { return nil }
        var rank = size * 10
        if core.contains(".en") { rank += 5 }
        if core.contains("-q") { rank += 1 }
        return rank
    }
}

/// Runs whisper-cli over a 16 kHz WAV file and reads what it heard. One
/// run at a time per value; cancelling the task stops the tool.
public struct WhisperRunner: Sendable {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public let executable: URL
    public let model: URL

    public init(executable: URL, model: URL) {
        self.executable = executable
        self.model = model
    }

    /// The command line: the language is found by whisper itself, the
    /// result is a JSON file with a word per segment and its times. With a
    /// `dtw` preset every piece also gets the time the model's attention
    /// puts it at (far steadier across pauses; it needs whisper's flash
    /// attention off, which makes the run about twice as long).
    public static func arguments(model: URL, audio: URL, outputBase: URL, dtw: String? = nil) -> [String] {
        var arguments = [
            "-m", model.path, "-f", audio.path, "-l", "auto",
            "--output-json-full", "--output-file", outputBase.path,
            "--max-len", "1", "--split-on-word", "--print-progress",
        ]
        if let dtw { arguments += ["--dtw", dtw, "--no-flash-attn"] }
        return arguments
    }

    /// whisper.cpp's name for a model's attention heads (`--dtw`), from
    /// the model file's name: "ggml-large-v3-turbo-q5_0.bin" →
    /// "large.v3.turbo". `nil` for a name that says no known model; the run
    /// then does without.
    public static func dtwPreset(forModel fileName: String) -> String? {
        var name = fileName.lowercased()
        guard name.hasPrefix("ggml-"), name.hasSuffix(".bin") else { return nil }
        name = String(name.dropFirst(5).dropLast(4))
        if let quantized = name.range(of: "-q[0-9]", options: .regularExpression) { name = String(name[..<quantized.lowerBound]) }
        let known = [
            "tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
            "large-v1", "large-v2", "large-v3", "large-v3-turbo",
        ]
        guard known.contains(name) else { return nil }
        return name.replacingOccurrences(of: "-", with: ".")
    }

    /// The progress in a line whisper prints ("… progress =  40%"), 0...1.
    public static func progress(inLine line: String) -> Double? {
        guard let range = line.range(of: "progress\\s*=\\s*(\\d{1,3})\\s*%", options: .regularExpression) else { return nil }
        let digits = line[range].filter(\.isNumber)
        return Int(digits).map { min(1, Double($0) / 100) }
    }

    /// Recognises the words in `audio` (16 kHz mono WAV): with the
    /// attention's times when the model's name is one whisper.cpp knows,
    /// and once more without them if that run fails.
    public func transcribe(_ audio: URL, timeout: TimeInterval = 900, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> WhisperTranscript {
        if let preset = Self.dtwPreset(forModel: model.lastPathComponent) {
            do {
                return try await run(audio, dtw: preset, timeout: timeout, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An older whisper.cpp, or a model whose heads it does not
                // know: its own times will do.
            }
        }
        return try await run(audio, dtw: nil, timeout: timeout, onProgress: onProgress)
    }

    private func run(_ audio: URL, dtw: String?, timeout: TimeInterval, onProgress: (@Sendable (Double) -> Void)?) async throws -> WhisperTranscript {
        let base = audio.deletingPathExtension().appendingPathExtension("heard")
        let output = base.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(model: model, audio: audio, outputBase: base, dtw: dtw)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                if let progress = Self.progress(inLine: String(line)) { onProgress?(progress) }
            }
        }
        defer { errors.fileHandleForReading.readabilityHandler = nil }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: Failure(description: "whisper could not be started: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw Failure(description: "whisper ended with status \(status)") }
        guard let data = try? Data(contentsOf: output) else { throw Failure(description: "whisper wrote no result") }
        do {
            return try WhisperTranscript(json: data)
        } catch {
            throw Failure(description: "whisper's result could not be read")
        }
    }
}
