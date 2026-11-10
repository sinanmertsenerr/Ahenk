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
/// - `--wallpaper-song "<title>|<artist>[|<seconds>]"`: in demo mode, the
///   live wallpaper looks up this (real) song online instead of the invented
///   one, while the demo plays: checks and measurements of the real sources
///   without playing music. With a length, the song's own video follows the
///   demo's position.
/// - `--wallpaper-source <kind>`: the live wallpaper shows this kind of
///   candidate first for this run (`motionArtwork`, `songVideo`,
///   `artistVideo`, `artwork`), or `off` for none (measurements).
/// - `--optimized`: Optimized Mode for this run only (measurements of the
///   lighter mode).
/// - `--full-rate`: this run does not run lighter on battery (measurements
///   of the full frame rates on an unplugged MacBook).
/// - `--dock-art <on|still|off>`: Dock Art for this run only: the cover with
///   the beating ring, the cover with a still ring, or Ahenk's own icon.
/// - `--demo-local`: in demo mode, Ahenk's own player plays a folder of
///   generated tones, silently: the Local source on the desktop for visual
///   checks and measurements (the folder is temporary and deleted on quit).
/// - `--demo-desk-cleared`: in demo mode, Clear Desk is switched on at
///   launch, on the demo's invented apps (nothing on the Mac is hidden).
/// - `--welcome`: open the first-run guide at launch (also in demo mode,
///   where it asks for nothing).
/// - `--power <battery|low-power|hot>`: in demo mode, act as if the Mac ran
///   on battery, in Low Power Mode or hot (measurements of the lighter mode
///   without touching the Mac's own power settings).
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
    /// The song the demo's wallpaper looks up online (`--wallpaper-song`).
    public var wallpaperSong: (title: String, artist: String, duration: Double)? {
        guard let raw = wallpaperSongArgument else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let duration = parts.count == 3 ? Self.seconds(parts[2]) ?? 0 : 0
        return (parts[0], parts[1], duration)
    }
    public var wallpaperSongArgument: String?
    /// The candidate kind the wallpaper shows first (`--wallpaper-source`).
    public var wallpaperSource: String?
    /// Optimized Mode for this run (`--optimized`), not saved.
    public var optimized = false
    /// "Run lighter on battery" is off for this run (`--full-rate`), not saved.
    public var fullRate = false
    /// Dock Art for this run (`--dock-art`: `on`, `still`, `off`), not saved.
    public var dockArt: String?
    /// Demo only: the local player plays generated tones, muted (`--demo-local`).
    public var demoLocal = false
    /// Demo only: the invented desk starts cleared (`--demo-desk-cleared`).
    public var demoDeskCleared = false
    /// Open the first-run guide at launch (`--welcome`).
    public var showsWelcome = false
    /// Demo only: the power state to act as if (`--power`).
    public var simulatedPower: SimulatedPower?

    /// `--power`: what the demo acts as if the Mac were doing.
    public enum SimulatedPower: String, Equatable, Sendable {
        case battery
        case lowPower = "low-power"
        case hot
    }

    /// Demo content is used in both `--demo` and `--smoke`.
    public var usesDemoContent: Bool { mode != .normal }

    /// The run works on an in-memory copy of the settings, so what it
    /// changes (a smoke check, a scene, a language) is never saved.
    public var usesDetachedSettings: Bool {
        mode == .smoke || demoScene != nil || language != nil || lyricsStyle != nil || wallpaperSource != nil || optimized
            || fullRate || dockArt != nil
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
            case "--optimized":
                optimized = true
            case "--full-rate":
                fullRate = true
            case "--dock-art":
                dockArt = (inlineValue ?? Self.popValue(&remaining)).map { $0.lowercased() }
            case "--demo-local":
                demoLocal = true
            case "--demo-desk-cleared":
                demoDeskCleared = true
            case "--welcome":
                showsWelcome = true
            case "--power":
                simulatedPower = (inlineValue ?? Self.popValue(&remaining)).flatMap { SimulatedPower(rawValue: $0.lowercased()) }
            case "--wallpaper-song":
                wallpaperSongArgument = inlineValue ?? Self.popValue(&remaining)
            case "--wallpaper-source":
                wallpaperSource = inlineValue ?? Self.popValue(&remaining)
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
