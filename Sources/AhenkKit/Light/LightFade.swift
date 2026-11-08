import Foundation

/// One fade of the edge light, driven by frame times: in when music starts
/// (or a display lets the light back), out when it stops (or the light steps
/// aside). Re-targeting in the middle continues from where the fade is, so
/// the light never jumps.
///
/// Once a fade-out has finished the fade is ``isIdle``: the renderer draws
/// one last empty frame and stops its display link.
public struct LightFade: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        case fadingIn
        case on
        case fadingOut
    }

    /// Seconds from 0 to 1.
    public var fadeIn: Double
    /// Seconds from 1 to 0.
    public var fadeOut: Double

    /// Linear progress `0...1`; ``value`` is the eased brightness.
    public private(set) var progress: Double
    public private(set) var isTargetOn: Bool
    private var lastTime: Double?

    public init(fadeIn: Double, fadeOut: Double, isOn: Bool = false) {
        self.fadeIn = max(0, fadeIn)
        self.fadeOut = max(0, fadeOut)
        progress = isOn ? 1 : 0
        isTargetOn = isOn
    }

    /// The light after music starts or stops: in over 0.8 s, out over 1.6 s.
    public static func music(isOn: Bool = false) -> LightFade {
        LightFade(fadeIn: 0.8, fadeOut: 1.6, isOn: isOn)
    }

    /// One display stepping aside (an app came to the front, full screen)
    /// and coming back: quicker, so it gets out of the way at once.
    public static func presence(isOn: Bool = false) -> LightFade {
        LightFade(fadeIn: 0.6, fadeOut: 0.45, isOn: isOn)
    }

    /// Sets where the fade goes from now on.
    public mutating func set(on: Bool) {
        isTargetOn = on
    }

    /// Moves the fade to `time` (seconds on any steady clock). The first
    /// call only remembers the time; going backwards changes nothing.
    public mutating func advance(to time: Double) {
        defer { lastTime = max(lastTime ?? time, time) }
        guard let lastTime, time > lastTime else { return }
        let elapsed = time - lastTime
        if isTargetOn {
            progress = fadeIn > 0 ? min(1, progress + elapsed / fadeIn) : 1
        } else {
            progress = fadeOut > 0 ? max(0, progress - elapsed / fadeOut) : 0
        }
    }

    /// Forgets the last time, so the next `advance` starts a new timeline
    /// (after the display link slept).
    public mutating func resetClock() {
        lastTime = nil
    }

    /// Eased brightness `0...1` (smoothstep of the progress).
    public var value: Double {
        progress * progress * (3 - 2 * progress)
    }

    public var phase: Phase {
        if isTargetOn {
            return progress >= 1 ? .on : .fadingIn
        }
        return progress <= 0 ? .off : .fadingOut
    }

    /// Off and staying off: nothing to draw.
    public var isIdle: Bool { phase == .off }
}
