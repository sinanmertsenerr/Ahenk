import Foundation

/// The colours that drive the light, the player tint and the lyrics for one
/// piece of artwork, most important first, plus variants that are safe to
/// use in specific places.
///
/// `PaletteExtractor` builds palettes from artwork; the demo hands out fixed
/// ones. Only `colors` is stored when encoded: the variants are derived.
public struct Palette: Hashable, Sendable, Codable {
    /// Text and icons on dark glass or a dark desktop are checked against
    /// this colour.
    public static let darkBackdrop = SRGBColor("#141418")
    /// WCAG AA for normal text.
    public static let minimumTextContrast = 4.5

    /// At least one colour; extracted palettes have three to six.
    public let colors: [SRGBColor]
    /// `colors`, each lightened just enough for text on `darkBackdrop`.
    public let onDark: [SRGBColor]
    /// `colors`, each darkened just enough for text on white.
    public let onLight: [SRGBColor]
    /// `colors`, bright and saturated enough to read as light (the edge
    /// light, glows). Greys stay grey but are lifted towards white.
    public let vivid: [SRGBColor]

    public init(colors: [SRGBColor]) {
        let colors = colors.isEmpty ? Palette.neutralColors : colors
        self.colors = colors
        onDark = colors.map { $0.readable(on: Palette.darkBackdrop, minimumContrast: Palette.minimumTextContrast) }
        onLight = colors.map { $0.readable(on: .white, minimumContrast: Palette.minimumTextContrast) }
        vivid = colors.map(Palette.vivid)
    }

    public var primary: SRGBColor { colors[0] }
    public var secondary: SRGBColor { colors.count > 1 ? colors[1] : primary }
    public var tertiary: SRGBColor { colors.count > 2 ? colors[2] : secondary }

    /// A dark, slightly tinted colour for glass behind light text.
    public var backdrop: SRGBColor {
        let lab = primary.okLab
        return SRGBColor(okLab: lab.with(lightness: min(lab.l, 0.24), chroma: lab.chroma * 0.7))
    }

    /// `colors` adjusted for text on any `background`.
    public func readable(on background: SRGBColor, minimumContrast: Double = Palette.minimumTextContrast) -> [SRGBColor] {
        colors.map { $0.readable(on: background, minimumContrast: minimumContrast) }
    }

    /// Shown when nothing better is known (no artwork yet).
    public static let neutral = Palette(colors: neutralColors)

    private static let neutralColors = [
        SRGBColor("#8E8CF7"),
        SRGBColor("#F78CC8"),
        SRGBColor("#8CE3F7"),
    ]

    private static func vivid(_ color: SRGBColor) -> SRGBColor {
        let lab = color.okLab
        guard lab.chroma > 0.03 else {
            return SRGBColor(okLab: lab.with(lightness: max(lab.l, 0.85), chroma: lab.chroma))
        }
        return SRGBColor(okLab: lab.with(lightness: min(0.86, max(lab.l, 0.72)), chroma: max(lab.chroma, 0.13)))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case colors }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(colors: try container.decode([SRGBColor].self, forKey: .colors))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colors, forKey: .colors)
    }

    // Equality and hashing follow the stored colours; the variants derive
    // from them.
    public static func == (lhs: Palette, rhs: Palette) -> Bool { lhs.colors == rhs.colors }
    public func hash(into hasher: inout Hasher) { hasher.combine(colors) }
}
