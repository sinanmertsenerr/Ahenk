import Foundation

/// Command-line switches, passed through `open -n Ahenk.app --args …`.
///
/// - `--demo`: invented songs, generated covers and a synthetic 120 BPM beat
///   feed the real pipeline; no music or permissions needed.
/// - `--smoke`: initialise every subsystem in demo mode, render a few frames,
///   write `~/Library/Logs/Ahenk/smoke.json` and quit with status 0.
/// - `--snapshots [dir]`: with `--smoke`, also save PNGs of every Settings
///   pane in every language (default `~/Library/Logs/Ahenk/snapshots`).
/// - `--demo-conflict`: like `--demo`, with a second demo player so the
///   "several sources are playing" question shows up.
/// - `--demo-pause-after <s>` / `--demo-resume-after <s>`: in demo mode,
///   pause (resume) the demo song that many seconds after launch.
/// - `--demo-scene <name>`: like `--demo`, with the desktop player opened in
///   one state (`albums`, `search`, `album`, `artist`, `queue`, `small`,
///   `small-search`, `status`, `loading`, `lyrics-versions`,
///   `lyrics-search`, or `off` for none), for screenshots, visual checks and
///   measurements.
/// - `--demo-backdrop`: in demo mode, a generated wallpaper behind the
///   desktop widgets (so they can be captured without the user's desktop).
/// - `--language <en|tr>`: the UI language for this run only.
/// - `--lyrics-style <name>`: the lyrics in this style for this run only
///   (`fisheye`, `spread`, `karaoke`, `typewriter`, `neon`, `echo`,
///   `glitch`, `cinema`), or `off` for none.
/// - `--demo-position <s>`: the demo song starts at this many seconds.
/// - `--smoke-only <a,b>`: with `--smoke`, run only these checks (the
///   others are left out of the report).
/// - `--draw-covered`: in demo mode, the lyrics keep moving while app
///   windows cover them (captures and CPU measurements).
/// - `--bridge-port <port>`: with `--smoke`, the first port of the browser
///   bridge the live end-to-end check (`bridgeLive`) listens on.
/// - `--bridge-wait <s>`: with `--smoke`, run the live end-to-end check:
///   wait this long for a real browser with the extension (a test browser
///   on a mock music page), then drive it; see Scripts/bridge-e2e.sh.
/// - `--settings [pane]` / `--settings=pane`: open Settings at launch.
/// - `--allow-multiple`: skip the single-instance hand-off (development).
///
/// Unknown arguments (including the ones macOS adds itself) are ignored.
public struct LaunchOptions: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case normal
        case demo
        case smoke
    }

    public var mode: Mode = .normal
    /// Set when Settings should open at launch; `""` means the default pane.
    public var settingsPane: String?
    public var snapshotDirectory: String?
    public var allowsMultipleInstances = false
    /// A second demo player plays alongside the first (`--demo-conflict`).
    public var demoConflict = false
    /// Seconds after launch to pause the demo song (`--demo-pause-after`).
    public var demoPauseAfter: Double?
    /// Seconds after launch to resume it (`--demo-resume-after`).
    public var demoResumeAfter: Double?
    /// The desktop player opens in this state (`--demo-scene`).
    public var demoScene: String?
    /// A generated wallpaper behind the widgets (`--demo-backdrop`).
    public var demoBackdrop = false
    /// The UI language for this run (`--language`), not saved.
    public var language: String?
    /// The lyrics style for this run (`--lyrics-style`), not saved.
    public var lyricsStyle: String?
    /// Where the demo song starts, in seconds (`--demo-position`).
    public var demoPosition: Double?
    /// The smoke checks to run (`--smoke-only`); `nil` runs them all.
    public var smokeChecks: Set<String>?
    /// Demo only: draw the lyrics even while windows cover them (`--draw-covered`).
    public var drawCovered = false
    /// The live bridge check's first port (`--bridge-port`).
    public var bridgePort: Int?
    /// Seconds the live bridge check waits for a browser (`--bridge-wait`).
    public var bridgeWait: Double?

    /// Demo content is used in both `--demo` and `--smoke`.
    public var usesDemoContent: Bool { mode != .normal }

    /// The run works on an in-memory copy of the settings, so what it
    /// changes (a smoke check, a scene, a language) is never saved.
    public var usesDetachedSettings: Bool {
        mode == .smoke || demoScene != nil || language != nil || lyricsStyle != nil
    }

    public init() {}

    /// Parses `CommandLine.arguments` (the first element, the executable path,
    /// is skipped).
    public init(arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            let (name, inlineValue) = Self.split(argument)
            switch name {
            case "--demo":
                if mode == .normal { mode = .demo }
            case "--demo-conflict":
                if mode == .normal { mode = .demo }
                demoConflict = true
            case "--smoke":
                mode = .smoke
            case "--settings":
                settingsPane = inlineValue ?? Self.popValue(&remaining) ?? ""
            case "--snapshots":
                snapshotDirectory = inlineValue ?? Self.popValue(&remaining) ?? ""
            case "--allow-multiple":
                allowsMultipleInstances = true
            case "--demo-pause-after":
                demoPauseAfter = Self.seconds(inlineValue ?? Self.popValue(&remaining))
            case "--demo-resume-after":
                demoResumeAfter = Self.seconds(inlineValue ?? Self.popValue(&remaining))
            case "--demo-scene":
                if mode == .normal { mode = .demo }
                demoScene = inlineValue ?? Self.popValue(&remaining) ?? "albums"
            case "--demo-backdrop":
                demoBackdrop = true
            case "--language":
                language = (inlineValue ?? Self.popValue(&remaining)).map { $0.lowercased() }
            case "--lyrics-style":
                lyricsStyle = inlineValue ?? Self.popValue(&remaining)
            case "--demo-position":
                demoPosition = Self.seconds(inlineValue ?? Self.popValue(&remaining))
            case "--draw-covered":
                drawCovered = true
            case "--bridge-port":
                bridgePort = (inlineValue ?? Self.popValue(&remaining)).flatMap(Int.init).flatMap { (1024...65_535).contains($0) ? $0 : nil }
            case "--bridge-wait":
                bridgeWait = Self.seconds(inlineValue ?? Self.popValue(&remaining))
            case "--smoke-only":
                let names = (inlineValue ?? Self.popValue(&remaining) ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                smokeChecks = names.isEmpty ? nil : Set(names)
            default:
                continue
            }
        }
    }

    /// `"--name=value"` → `("--name", "value")`.
    private static func split(_ argument: String) -> (String, String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    /// A non-negative, finite number of seconds, or `nil`.
    private static func seconds(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Consumes the next argument when it is a value rather than another flag.
    private static func popValue(_ remaining: inout ArraySlice<String>) -> String? {
        guard let next = remaining.first, !next.hasPrefix("-") else { return nil }
        return remaining.popFirst()
    }
}
