import Foundation

/// The colours the edge light is drawn with: always four slots, which the
/// shader blends into one smooth cycle around the screen.
///
/// Fewer colours are spread so every slot holds a real colour and no part
/// of the cycle is flat: one colour fills all four, two alternate
/// (`a b a b`), three swing back (`a b c b`).
public struct LightColors: Equatable, Sendable {
    public static let slotCount = 4

    /// Exactly ``slotCount`` sRGB colours.
    public let slots: [SRGBColor]
    /// The shader draws a hue wheel instead of the slots.
    public let isRainbow: Bool

    public init(colors: [SRGBColor], isRainbow: Bool = false) {
        slots = Self.spread(colors.isEmpty ? Palette.neutral.vivid : colors)
        self.isRainbow = isRainbow
    }

    /// The colours for a colour source: the album's palette lifted to read
    /// as light (or a neutral palette while there is no cover), the user's
    /// own colours, or the rainbow.
    public static func resolve(source: LightColorSource, album: Palette?, custom: [SRGBColor]) -> LightColors {
        switch source {
        case .album:
            LightColors(colors: Array((album ?? .neutral).vivid.prefix(slotCount)))
        case .custom:
            LightColors(colors: Array((custom.isEmpty ? LightSettings().customColors : custom).prefix(slotCount)))
        case .rainbow:
            LightColors(colors: rainbow, isRainbow: true)
        }
    }

    /// What rainbow slots blend through when a crossfade starts or ends at
    /// the rainbow.
    public static let rainbow = [SRGBColor("#FF5A5A"), SRGBColor("#FFD84D"), SRGBColor("#4DE8A0"), SRGBColor("#6A8CFF")]

    static func spread(_ colors: [SRGBColor]) -> [SRGBColor] {
        let colors = Array(colors.prefix(slotCount))
        switch colors.count {
        case 1: return Array(repeating: colors[0], count: slotCount)
        case 2: return [colors[0], colors[1], colors[0], colors[1]]
        case 3: return [colors[0], colors[1], colors[2], colors[1]]
        default: return colors
        }
    }
}

/// Blends from one set of light colours to the next in OKLab, so a new
/// album cover flows in instead of switching. A change in the middle of a
/// blend starts from the colours on screen at that moment.
public struct PaletteCrossfade: Sendable {
    public var duration: Double
    public private(set) var target: LightColors
    private var from: [OKLab]
    private var to: [OKLab]
    private var start: Double = -.infinity

    public init(_ colors: LightColors, duration: Double = 1.5) {
        self.duration = max(0, duration)
        target = colors
        to = colors.slots.map(\.okLab)
        from = to
    }

    /// Starts blending towards `colors` at `time`. Rainbow on or off
    /// switches at once (the shader draws it differently).
    public mutating func set(_ colors: LightColors, at time: Double) {
        guard colors != target else { return }
        from = labs(at: time)
        to = colors.slots.map(\.okLab)
        start = time
        target = colors
    }

    /// The four slots at `time`.
    public func colors(at time: Double) -> [SRGBColor] {
        guard !isSettled(at: time) else { return target.slots }
        return labs(at: time).map { SRGBColor(okLab: $0) }
    }

    public func isSettled(at time: Double) -> Bool {
        duration <= 0 || time >= start + duration
    }

    private func labs(at time: Double) -> [OKLab] {
        guard !isSettled(at: time) else { return to }
        let linear = max(0, min(1, (time - start) / duration))
        let t = linear * linear * (3 - 2 * linear)
        return zip(from, to).map { a, b in
            OKLab(l: a.l + (b.l - a.l) * t, a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t)
        }
    }
}
