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

    /// Demo content is used in both `--demo` and `--smoke`.
    public var usesDemoContent: Bool { mode != .normal }

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

    /// Consumes the next argument when it is a value rather than another flag.
    private static func popValue(_ remaining: inout ArraySlice<String>) -> String? {
        guard let next = remaining.first, !next.hasPrefix("-") else { return nil }
        return remaining.popFirst()
    }
}
