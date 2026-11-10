import Foundation

/// How much work the edge light may do per frame.
public enum LightQuality: Equatable, Sendable {
    /// Every particle layer and noise octave, full resolution.
    case full
    /// Fewer particles and octaves, drawn at half resolution (the halo is
    /// soft anyway; particles get a little softer).
    case light

    /// The value the shader reads (`quality`).
    public var shaderValue: Float {
        switch self {
        case .full: 1
        case .light: 0
        }
    }
}

/// What decides how hard the light may work on one display.
public struct LightFrameInputs: Equatable, Sendable {
    /// Settings › General › Run lighter on battery (also covers Low Power
    /// Mode).
    public var lighterOnBattery: Bool
    public var isOnBattery: Bool
    public var isLowPowerMode: Bool
    /// The Mac is hot (thermal state serious or critical).
    public var isThermallyConstrained: Bool
    /// The display shows the light's window (not occluded, not asleep).
    public var isVisible: Bool
    /// The display's highest refresh rate.
    public var maximumFramesPerSecond: Int

    public init(
        lighterOnBattery: Bool = true, isOnBattery: Bool = false,
        isLowPowerMode: Bool = false, isThermallyConstrained: Bool = false, isVisible: Bool = true,
        maximumFramesPerSecond: Int = 60
    ) {
        self.lighterOnBattery = lighterOnBattery
        self.isOnBattery = isOnBattery
        self.isLowPowerMode = isLowPowerMode
        self.isThermallyConstrained = isThermallyConstrained
        self.isVisible = isVisible
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

/// The frame rate and quality the light runs at on one display.
public struct LightFramePlan: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case normal
        case battery
        case lowPowerMode
        case thermal
        /// Occluded, asleep or on another Space: no frames at all.
        case hidden
    }

    /// 0 means paused.
    public var framesPerSecond: Int
    public var quality: LightQuality
    /// Share of the display's backing scale the strips are drawn at.
    public var resolutionScale: Double
    public var reason: Reason

    public var isPaused: Bool { framesPerSecond == 0 }
}

/// Frame rate and quality from power state and visibility:
///
/// - hidden → paused (0 fps);
/// - the Mac running hot, or (with "Run lighter on battery")
///   battery power or Low Power Mode → 30 fps, ``LightQuality/light``, half
///   resolution;
/// - otherwise 60 fps (never more: the light moves smoothly at 60 and a
///   120 Hz display would only double the cost), full quality.
public enum LightFramePolicy {
    public static let normalFramesPerSecond = 60
    public static let lighterFramesPerSecond = 30

    public static func plan(_ inputs: LightFrameInputs) -> LightFramePlan {
        guard inputs.isVisible else {
            return LightFramePlan(framesPerSecond: 0, quality: .light, resolutionScale: 0.5, reason: .hidden)
        }
        let ceiling = max(1, inputs.maximumFramesPerSecond)
        let reason: LightFramePlan.Reason
        if inputs.isThermallyConstrained {
            reason = .thermal
        } else if inputs.lighterOnBattery, inputs.isLowPowerMode {
            reason = .lowPowerMode
        } else if inputs.lighterOnBattery, inputs.isOnBattery {
            reason = .battery
        } else {
            return LightFramePlan(
                framesPerSecond: min(normalFramesPerSecond, ceiling), quality: .full, resolutionScale: 1, reason: .normal
            )
        }
        return LightFramePlan(
            framesPerSecond: min(lighterFramesPerSecond, ceiling), quality: .light, resolutionScale: 0.5, reason: reason
        )
    }
}
