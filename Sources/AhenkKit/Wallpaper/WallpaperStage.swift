import Foundation

/// What the music is doing, as far as the live wallpaper cares.
public enum WallpaperMusic: Equatable, Sendable {
    case playing
    case paused(since: Date)
    /// Nothing the wallpaper follows plays (no song, a plain video, a
    /// podcast, an advert).
    case stopped(since: Date)
}

/// One display's live wallpaper as a state machine: when its layer melts in
/// over the user's own wallpaper and back out, which candidate is in front,
/// when two crossfade, and whether media plays, pauses or is let go.
///
/// - The layer appears only once the wanted candidate has frames (never a
///   black screen while a video loads) and fades in over the crossfade
///   time; a new candidate loads under the one showing and crossfades in
///   when it is ready.
/// - Pausing keeps the frame for `pauseGrace` (a pause between songs or a
///   quick resume never flashes), then the layer melts back, unless the
///   user keeps it while paused; then media is paused.
/// - Hidden (covered, asleep, locked, behind a full-screen app) pauses at
///   once and lets everything go after `releaseAfterHidden`; seen again, it
///   loads and fades in like the first time.
/// - The window is ordered in only while something shows, fades or loads.
///
/// Pure: the app feeds inputs and the time, applies the plan, and calls
/// again at `wakeAt`.
public struct WallpaperStage: Equatable, Sendable {
    public struct Inputs: Equatable, Sendable {
        /// The feature is on and this display shows it.
        public var isEnabled: Bool
        public var music: WallpaperMusic
        /// Melt back to the user's wallpaper when the music pauses.
        public var returnsOnPause: Bool
        /// The candidate that should show (`nil`: none decided yet).
        public var wanted: String?
        /// Candidates whose media has frames on this display.
        public var ready: Set<String>
        /// The window can be seen.
        public var isVisible: Bool
        /// Seconds of each fade.
        public var crossfade: TimeInterval

        public init(
            isEnabled: Bool = true, music: WallpaperMusic, returnsOnPause: Bool = true, wanted: String?,
            ready: Set<String> = [], isVisible: Bool = true, crossfade: TimeInterval = 1.2
        ) {
            self.isEnabled = isEnabled
            self.music = music
            self.returnsOnPause = returnsOnPause
            self.wanted = wanted
            self.ready = ready
            self.isVisible = isVisible
            self.crossfade = crossfade
        }
    }

    public enum Playback: String, Equatable, Sendable {
        case play
        case pause
    }

    public struct Plan: Equatable, Sendable {
        /// The window is ordered in (something shows, fades or loads).
        public var isUp: Bool
        /// The layer's opacity, animated over the crossfade time: 1 over the
        /// user's wallpaper, 0 melted back.
        public var opacity: Double
        /// What shows; during a crossfade `back` fades out under it.
        public var front: String?
        public var back: String?
        /// Media to create or keep; everything else is let go.
        public var keep: Set<String>
        /// What kept media does.
        public var playback: Playback
        /// Call `update` again then, even if no input changes.
        public var wakeAt: Date?
    }

    /// A pause shorter than this keeps the layer.
    public static let pauseGrace: TimeInterval = 3
    /// Hidden this long, media is let go.
    /// Long: coming back to the desktop must find the wallpaper there,
    /// not the user's own for the seconds a video takes to load again.
    public static let releaseAfterHidden: TimeInterval = 600

    public private(set) var front: String?
    public private(set) var back: String?
    public private(set) var isShowing = false
    private var crossfadeEnds: Date?
    private var fadeOutEnds: Date?
    private var hiddenSince: Date?

    public init() {}

    public mutating func update(_ inputs: Inputs, now: Date) -> Plan {
        var wakes: [Date] = []
        let fade = max(0, inputs.crossfade)

        // Hidden: pause now, let go later.
        if inputs.isVisible {
            hiddenSince = nil
        } else if hiddenSince == nil {
            hiddenSince = now
        }
        let releaseAt = hiddenSince.map { $0.addingTimeInterval(Self.releaseAfterHidden) }
        let hiddenLong = releaseAt.map { now >= $0 } ?? false
        if let releaseAt, !hiddenLong { wakes.append(releaseAt) }

        // Does the music want the layer?
        let musicWants: Bool
        switch inputs.music {
        case .playing:
            musicWants = true
        case .paused(let since):
            if inputs.returnsOnPause {
                let end = since.addingTimeInterval(Self.pauseGrace)
                musicWants = now < end
                if musicWants { wakes.append(end) }
            } else {
                musicWants = true
            }
        case .stopped(let since):
            let end = since.addingTimeInterval(Self.pauseGrace)
            musicWants = now < end
            if musicWants { wakes.append(end) }
        }
        let wanted = inputs.isEnabled ? inputs.wanted : nil
        let wantedReady = wanted.map { inputs.ready.contains($0) } ?? false

        if hiddenLong {
            // Nobody sees it: drop everything at once, no fade.
            reset()
        } else if inputs.isEnabled, musicWants {
            fadeOutEnds = nil
            if isShowing {
                if let wanted, wanted != front, wantedReady {
                    back = front
                    front = wanted
                    crossfadeEnds = now.addingTimeInterval(fade)
                }
            } else if let wanted, wantedReady {
                // Fade in (again, if a fade-out was under way).
                if front != wanted { back = nil }
                front = wanted
                isShowing = true
            }
        } else if isShowing {
            // Melt back to the user's wallpaper.
            isShowing = false
            fadeOutEnds = now.addingTimeInterval(fade)
        }

        if let ends = crossfadeEnds {
            if now >= ends || back == nil {
                back = nil
                crossfadeEnds = nil
            } else {
                wakes.append(ends)
            }
        }
        if let ends = fadeOutEnds {
            if now >= ends {
                reset()
            } else {
                wakes.append(ends)
            }
        }

        // What to load and keep: what shows, and the wanted one while the
        // music wants it and the display can be seen.
        var keep: Set<String> = []
        if let front { keep.insert(front) }
        if let back { keep.insert(back) }
        let loading = inputs.isVisible && musicWants && !hiddenLong
        if loading, let wanted { keep.insert(wanted) }
        let isUp = isShowing || fadeOutEnds != nil || (loading && wanted != nil)
        let playback: Playback = inputs.isVisible && inputs.music == .playing && inputs.isEnabled ? .play : .pause
        return Plan(
            isUp: isUp, opacity: isShowing ? 1 : 0, front: isUp ? front : nil, back: isUp ? back : nil,
            keep: isUp ? keep : [], playback: playback, wakeAt: wakes.min()
        )
    }

    private mutating func reset() {
        front = nil
        back = nil
        isShowing = false
        crossfadeEnds = nil
        fadeOutEnds = nil
    }
}
