import Foundation

/// The colours that drive the light, the player tint and the lyrics for one
/// piece of artwork, most prominent first.
///
/// Step 2 fills this from artwork (extraction plus contrast-safe variants);
/// the demo provider hands out fixed palettes.
public struct Palette: Hashable, Sendable, Codable {
    public var colors: [SRGBColor]

    public init(colors: [SRGBColor]) {
        self.colors = colors.isEmpty ? Palette.neutral.colors : colors
    }

    public var primary: SRGBColor { colors[0] }
    public var secondary: SRGBColor { colors.count > 1 ? colors[1] : primary }
    public var tertiary: SRGBColor { colors.count > 2 ? colors[2] : secondary }

    /// Shown when nothing better is known (no artwork yet).
    public static let neutral = Palette(colors: [
        SRGBColor("#8E8CF7"),
        SRGBColor("#F78CC8"),
        SRGBColor("#8CE3F7"),
    ])
}
