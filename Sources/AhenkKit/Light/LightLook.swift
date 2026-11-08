import Foundation

/// What one edge light looks like, derived from the settings: the style,
/// the line, the halo and how far the light reaches into the screen.
///
/// `detail` scales particle sizes and spacing: 1 on a real screen, smaller
/// for the miniature screens of the Settings gallery.
public struct LightLook: Equatable, Sendable {
    public var style: LightStyle
    public var position: LightPosition
    /// Width of the bright line along the edge, in points.
    public var thickness: Double
    /// `0...1`: how far and how strongly the halo spreads.
    public var glow: Double
    /// `0...1`: overall brightness.
    public var intensity: Double
    /// Animation speed multiplier.
    public var speed: Double
    public var detail: Double

    public init(
        style: LightStyle = .glow, position: LightPosition = .allEdges, thickness: Double = 10, glow: Double = 0.6,
        intensity: Double = 0.8, speed: Double = 1, detail: Double = 1
    ) {
        self.style = style
        self.position = position
        self.thickness = max(0.5, thickness)
        self.glow = min(1, max(0, glow))
        self.intensity = min(1, max(0, intensity))
        self.speed = max(0.05, speed)
        self.detail = max(0.1, detail)
    }

    /// The look of `settings`. `scale` shrinks the line and the particles
    /// (Settings previews draw a whole screen in a few dozen points).
    public init(settings: LightSettings, scale: Double = 1) {
        self.init(
            style: settings.style, position: settings.position,
            thickness: max(scale < 1 ? 1.5 : 0.5, settings.thickness * scale),
            glow: settings.glow, intensity: settings.intensity, speed: settings.speed, detail: scale
        )
    }

    /// How far the halo spreads from the edge, in points.
    public var reach: Double {
        thickness * (0.5 + 3 * glow) + 12 * glow * detail
    }

    /// How deep the light may reach into the screen, in points: the line
    /// swelling on a kick, the halo and the style's particles. Nothing is
    /// drawn further in; the strips that carry the light are this deep.
    public var band: Double {
        thickness * 1.9 + reach * 1.15 + style.extraReach * detail
    }
}

extension LightStyle {
    /// The style's number in EdgeLight.metal (`switch (u.style)`). Stable:
    /// add new styles at the end.
    public var shaderIndex: Int32 {
        switch self {
        case .glow: 0
        case .pulse: 1
        case .breathe: 2
        case .wave: 3
        case .spectrum: 4
        case .snake: 5
        case .twinSnakes: 6
        case .lava: 7
        case .aurora: 8
        case .rainbow: 9
        case .neonTube: 10
        case .plasma: 11
        case .fire: 12
        case .embers: 13
        case .snow: 14
        case .hearts: 15
        case .fireworks: 16
        case .sparkles: 17
        case .bubbles: 18
        case .lightning: 19
        case .rain: 20
        case .starfield: 21
        }
    }

    /// Extra depth (points, at detail 1) for what the style draws beyond
    /// the line and its halo: rings, flames, particles, bursts.
    public var extraReach: Double {
        switch self {
        case .glow: 6
        case .pulse: 34
        case .breathe: 12
        case .wave: 26
        case .spectrum: 46
        case .snake: 6
        case .twinSnakes: 6
        case .lava: 30
        case .aurora: 40
        case .rainbow: 14
        case .neonTube: 8
        case .plasma: 18
        case .fire: 40
        case .embers: 52
        case .snow: 46
        case .hearts: 50
        case .fireworks: 70
        case .sparkles: 16
        case .bubbles: 54
        case .lightning: 32
        case .rain: 46
        case .starfield: 56
        }
    }
}

extension LightPosition {
    /// The position's number in EdgeLight.metal.
    public var shaderIndex: Int32 {
        switch self {
        case .allEdges: 0
        case .bottom: 1
        case .top: 2
        case .corners: 3
        }
    }
}
