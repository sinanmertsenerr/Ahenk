import Foundation

/// Where the sound effects are applied for the player that is followed.
public enum SoundEffectRoute: Sendable, Equatable {
    /// The switch is off, or nothing is followed.
    case off
    /// Ahenk's own player (song files): in its own audio chain.
    case ownPlayer
    /// Another app: its sound is taken through a muting process tap and
    /// played by Ahenk with the effects.
    case tap(AudioTapTarget)
    /// The demo: an invented player with nothing to hear.
    case demo
    case unavailable(SoundEffectObstacle)

    /// Effects are wanted and can be applied.
    public var isAvailable: Bool {
        switch self {
        case .ownPlayer, .tap, .demo: true
        case .off, .unavailable: false
        }
    }
}

/// Why the effects cannot be applied to the followed player.
public enum SoundEffectObstacle: String, Sendable, Equatable {
    /// macOS has not been asked for system audio access yet.
    case needsPermission
    /// System audio access is denied.
    case permissionDenied
    /// Process taps need macOS 14.2.
    case needsNewerSystem
    /// The app's own sound cannot be told apart (Ahenk hears every app at
    /// once); muting everything is never done.
    case notHeardSeparately
    /// A video, a podcast or an advert: Ahenk does not listen to those.
    case notMusic
    /// The player cannot be told (no app, no process).
    case unknownPlayer
}

/// Decides the route of the sound effects from what plays and what Ahenk
/// may do. Pure: the app's controller carries the route out.
public enum SoundEffectRouter {
    /// The player effects belong to: the source and its app. A browser's
    /// tabs are one player; so are the songs of one app.
    public static func playerKey(_ snapshot: NowPlayingSnapshot?) -> String? {
        guard let snapshot else { return nil }
        return "\(snapshot.track.source.rawValue)|\(snapshot.bundleIdentifier ?? "")"
    }

    /// True when the effects must be switched off because another player
    /// is followed now than the one they were switched on for. Nothing
    /// being followed for a while changes nothing.
    public static func mustSwitchOff(enabledFor previous: String?, now current: String?) -> Bool {
        guard let previous, let current else { return false }
        return previous != current
    }

    public static func route(
        enabled: Bool, snapshot: NowPlayingSnapshot?, permission: AudioCapturePermission, isDemo: Bool,
        tapsSupported: Bool, hearsEverything: Bool
    ) -> SoundEffectRoute {
        guard enabled, let snapshot else { return .off }
        if snapshot.track.source == .local { return .ownPlayer }
        if isDemo { return .demo }
        guard AudioCapturePolicy.reactsTo(snapshot) else { return .unavailable(.notMusic) }
        guard tapsSupported else { return .unavailable(.needsNewerSystem) }
        switch permission {
        case .denied: return .unavailable(.permissionDenied)
        case .notDetermined: return .unavailable(.needsPermission)
        case .authorized, .unknown: break
        }
        let target = AudioTapTarget(snapshot: snapshot)
        guard target.isResolvable else { return .unavailable(.unknownPlayer) }
        if hearsEverything { return .unavailable(.notHeardSeparately) }
        return .tap(target)
    }

    /// Who can change the speed of the followed player.
    public static func speedControl(for snapshot: NowPlayingSnapshot?, tabTakesRate: Bool) -> SoundSpeedControl {
        guard let snapshot else { return .none }
        if snapshot.track.source == .local { return .ownPlayer }
        return tabTakesRate ? .browserTab : .none
    }
}

/// Whether a process tap may silence what it hears. It may only when all
/// of this holds: the tap is on the processes of one app (never the tap on
/// everything), that app is the one the effects were asked for, and Ahenk's
/// own output already plays the processed sound.
public enum SoundEffectTapRule {
    public static func mutes(request: AudioTapRequest, tapsProcesses: Bool, effectsFor target: AudioTapTarget?, outputRuns: Bool) -> Bool {
        guard tapsProcesses, outputRuns, let target, case .app(let tapped) = request else { return false }
        return tapped.source == target.source && tapped.bundleIdentifier == target.bundleIdentifier
    }

    /// The same question before the output is started: is it worth starting?
    public static func wantsMute(request: AudioTapRequest, tapsProcesses: Bool, effectsFor target: AudioTapTarget?) -> Bool {
        mutes(request: request, tapsProcesses: tapsProcesses, effectsFor: target, outputRuns: true)
    }
}
