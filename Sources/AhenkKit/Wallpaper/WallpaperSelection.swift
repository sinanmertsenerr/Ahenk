import Foundation

/// Which candidate the live wallpaper shows, and in what order the picker
/// dots list them.
///
/// Order: the preferred source first (motion artwork or music videos), the
/// other next, the user's own videos after them, the cover last. The
/// choice: a video the user pinned in Settings, else the dot the user
/// picked for this song, else the first candidate that has not failed; in
/// Low Power Mode (or while the Mac is hot) only the cover and generated
/// motion, unless the user picked a video. While a lookup that would beat
/// the best known candidate is still running, nothing is chosen until the
/// wait is over, so a song does not start with the cover and switch a
/// second later.
public enum WallpaperSelection {
    /// How long to wait for a better source before settling.
    public static let patience: TimeInterval = 3

    public static func rank(_ kind: WallpaperCandidate.Kind, preference: WallpaperSourcePreference) -> Int {
        switch (preference, kind) {
        case (.motionArtwork, .motionArtwork): 0
        case (.motionArtwork, .songVideo): 1
        case (.motionArtwork, .artistVideo): 2
        case (.musicVideo, .songVideo): 0
        case (.musicVideo, .artistVideo): 1
        case (.musicVideo, .motionArtwork): 2
        case (_, .generated): 3
        case (_, .userVideo): 4
        case (_, .artwork): 5
        }
    }

    /// The candidates in the dots' order, each once.
    public static func ordered(_ candidates: [WallpaperCandidate], preference: WallpaperSourcePreference) -> [WallpaperCandidate] {
        var seen: Set<String> = []
        return candidates.enumerated()
            .filter { seen.insert($0.element.id).inserted }
            .sorted { a, b in
                let ra = rank(a.element.kind, preference: preference)
                let rb = rank(b.element.kind, preference: preference)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// What to show now, or `nil` (nothing usable yet, or still waiting
    /// for a better source).
    public static func choose(
        _ ordered: [WallpaperCandidate], preference: WallpaperSourcePreference, pinned: String? = nil, pick: String? = nil,
        failed: Set<String> = [], pending: Set<WallpaperCandidate.Kind> = [], waited: Bool = true, allowsVideo: Bool = true
    ) -> WallpaperCandidate? {
        let usable = ordered.filter { !failed.contains($0.id) }
        if let pinned, let found = usable.first(where: { $0.id == pinned }) { return found }
        if let pick, let found = usable.first(where: { $0.id == pick }) { return found }
        let allowed = allowsVideo ? usable : usable.filter { !$0.kind.isVideo }
        guard let best = allowed.first else { return nil }
        if !waited, pending.contains(where: { rank($0, preference: preference) < rank(best.kind, preference: preference) }) {
            return nil
        }
        return best
    }
}

/// How much work the live wallpaper may do.
public enum WallpaperQuality: String, Equatable, Sendable {
    /// Videos up to 1080p, motion at 30 fps.
    case full
    /// Videos up to 720p and a lower bit rate, motion at 20 fps.
    case reduced
    /// No video decoding: only the cover (or generated motion) moves.
    case minimal
}

/// Video size and motion rate from the power state.
public struct WallpaperPowerPlan: Equatable, Sendable {
    public var quality: WallpaperQuality
    public var reason: LightFramePlan.Reason
    /// The longest side, in pixels, a video is decoded at.
    public var maximumVideoSide: Int
    /// Bits per second a stream may use; 0 leaves it to the resolution.
    public var peakBitRate: Double
    /// Frames per second of Ahenk's own motion (the cover, the demo).
    public var animationFrameRate: Int

    /// Real videos may play.
    public var allowsVideo: Bool { quality != .minimal }
}

/// - Low Power Mode (with "run lighter on battery") or a hot Mac → the
///   cover only, no video decoding;
/// - otherwise 1080p, motion at 30 fps (a dimmed wallpaper gains nothing
///   from more; 4K would only cost power). Battery power alone changes
///   nothing here: measured, a 720p video costs as much to show as a
///   1080p one (the cost is the full-screen frame, not its decoding).
public enum WallpaperPowerPolicy {
    public static func plan(_ inputs: LightFrameInputs) -> WallpaperPowerPlan {
        if inputs.isThermallyConstrained {
            return minimal(.thermal)
        }
        if inputs.lighterOnBattery, inputs.isLowPowerMode {
            return minimal(.lowPowerMode)
        }
        return WallpaperPowerPlan(quality: .full, reason: .normal, maximumVideoSide: 1920, peakBitRate: 0, animationFrameRate: 30)
    }

    private static func reduced(_ reason: LightFramePlan.Reason) -> WallpaperPowerPlan {
        WallpaperPowerPlan(quality: .reduced, reason: reason, maximumVideoSide: 1280, peakBitRate: 2_500_000, animationFrameRate: 20)
    }

    private static func minimal(_ reason: LightFramePlan.Reason) -> WallpaperPowerPlan {
        WallpaperPowerPlan(quality: .minimal, reason: reason, maximumVideoSide: 960, peakBitRate: 1_500_000, animationFrameRate: 15)
    }
}
