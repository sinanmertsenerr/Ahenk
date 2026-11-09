import AhenkKit
import AppKit

/// Each lyric style's own typeface. All are fonts every Mac has (macOS's
/// system fonts and the faces in /System/Library/Fonts), so nothing is
/// bundled; every one of them has the Turkish letters (checked by
/// `--smoke`). None of them is all capitals: small-capital faces draw the
/// Turkish "i" without its dot.
enum LyricsFonts {
    struct Face {
        /// Shown under each style in Settings.
        let name: String
        /// Size at text scale 1.
        let pointSize: CGFloat
        /// How large the face looks for its size, 1 being a plain sans:
        /// titles and numbers use it to look the same size in every style.
        var optical: CGFloat = 1
        let make: (CGFloat) -> NSFont
    }

    /// A font of `style` that looks `size` points large.
    static func font(for style: LyricStyle, looking size: CGFloat) -> NSFont {
        let face = face(for: style)
        return face.make(max(8, size / face.optical))
    }

    static func face(for style: LyricStyle) -> Face {
        switch style {
        case .fisheye:
            // A heavy slab serif: big, round counters that read well magnified.
            Face(name: "Superclarendon", pointSize: 52, optical: 1.05) { named("Superclarendon-Black", $0) ?? serif($0, .black) }
        case .spread:
            Face(name: "SF Pro Expanded", pointSize: 32, optical: 1.12) { NSFont.systemFont(ofSize: $0, weight: .heavy, width: .expanded) }
        case .karaoke:
            Face(name: "SF Pro Rounded", pointSize: 40) { size in
                let base = NSFont.systemFont(ofSize: size, weight: .heavy)
                return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            }
        case .typewriter:
            Face(name: "American Typewriter", pointSize: 38) { named("AmericanTypewriter-Semibold", $0) ?? NSFont.monospacedSystemFont(ofSize: $0, weight: .medium) }
        case .neon:
            // A sign painter's script, as hand-bent tubes are.
            Face(name: "SignPainter", pointSize: 60, optical: 0.78) { named("SignPainter-HouseScriptSemibold", $0) ?? named("SignPainter-HouseScript", $0) ?? serif($0, .bold) }
        case .echo:
            Face(name: "Futura Condensed", pointSize: 52, optical: 0.9) { named("Futura-CondensedExtraBold", $0) ?? NSFont.systemFont(ofSize: $0, weight: .black, width: .condensed) }
        case .glitch:
            Face(name: "SF Mono", pointSize: 32, optical: 1.08) { NSFont.monospacedSystemFont(ofSize: $0, weight: .heavy) }
        case .cinema:
            Face(name: "Didot", pointSize: 40) { named("Didot-Bold", $0) ?? serif($0, .semibold) }
        }
    }

    static func font(for style: LyricStyle, scale: CGFloat) -> NSFont {
        let face = face(for: style)
        return face.make(max(8, face.pointSize * scale))
    }

    /// Letters a lyric font must have.
    static let requiredCharacters = "ğĞşŞıİçÇöÖüÜâÂ’“”…"

    static func coversRequiredCharacters(_ font: NSFont) -> Bool {
        let utf16 = Array(requiredCharacters.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, utf16, &glyphs, utf16.count)
    }

    private static func named(_ name: String, _ size: CGFloat) -> NSFont? {
        guard let font = NSFont(name: name, size: size), font.fontName == name else { return nil }
        return font
    }

    private static func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}
