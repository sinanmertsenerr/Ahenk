import AhenkKit
import AppKit
import CoreText

/// How a lyric line is laid out in its column: rows of words (or letters),
/// each with its place, and where every character starts (for fills).
/// Coordinates are points with y growing downwards from the line's top.
struct LyricLineLayout {
    struct Unit {
        let text: String
        /// The unit's advance box: x from the column's left, y the row's top.
        let rect: CGRect
        let row: Int
        /// Index of the word the unit belongs to.
        let word: Int
        /// Its characters, counted over the whole line without spaces.
        let characters: Range<Int>
    }

    struct Row {
        let units: Range<Int>
        /// The row's text and its extent.
        let text: String
        let rect: CGRect
        let characters: Range<Int>
        /// x (from the column's left) where each counted character starts,
        /// then where the last one ends.
        let boundaries: [CGFloat]
    }

    let units: [Unit]
    let rows: [Row]
    let size: CGSize
    let rowHeight: CGFloat
    let baseline: CGFloat
    let characterCount: Int
    /// 1, or less when the line had to shrink to fit its rows.
    let fit: CGFloat
    let font: NSFont
}

/// Lays lines out with one font: wraps them into balanced rows inside a
/// column, shrinking the font a little when a line would need more rows
/// than allowed.
final class LyricsTypesetter {
    enum Units {
        case words
        case letters
    }

    let font: NSFont
    /// Extra space between letters, in points.
    let tracking: CGFloat
    /// Row height as a multiple of the font's line height.
    let rowSpacing: CGFloat

    init(font: NSFont, tracking: CGFloat = 0, rowSpacing: CGFloat = 1.08) {
        self.font = font
        self.tracking = tracking
        self.rowSpacing = rowSpacing
    }

    func layout(_ text: String, width: CGFloat, maxRows: Int, units: Units, centered: Bool) -> LyricLineLayout {
        var fit: CGFloat = 1
        var font = self.font
        var result = layout(text, font: font, width: width, units: units, centered: centered, fit: fit)
        while result.rows.count > maxRows, fit > 0.62 {
            fit -= 0.1
            font = NSFont(descriptor: self.font.fontDescriptor, size: self.font.pointSize * fit) ?? self.font
            result = layout(text, font: font, width: width, units: units, centered: centered, fit: fit)
        }
        return result
    }

    private func layout(_ text: String, font: NSFont, width: CGFloat, units mode: Units, centered: Bool, fit: CGFloat) -> LyricLineLayout {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let ascent = font.ascender
        let descent = -font.descender
        let lineHeight = ceil(ascent + descent)
        let rowHeight = ceil(lineHeight * rowSpacing)
        let space = advance(" ", font: font) + tracking
        let metrics = words.map { measure($0, font: font) }
        let wrapped = LyricsWrap.rows(widths: metrics.map { Double($0.width) }, space: Double(space), maxWidth: Double(width))

        var units: [LyricLineLayout.Unit] = []
        var rows: [LyricLineLayout.Row] = []
        var character = 0
        for (rowIndex, wordRange) in wrapped.enumerated() {
            let rowWidth = CGFloat(LyricsWrap.width(of: wordRange, widths: metrics.map { Double($0.width) }, space: Double(space)))
            var x = centered ? (width - rowWidth) / 2 : 0
            let top = CGFloat(rowIndex) * rowHeight
            let firstUnit = units.count
            let firstCharacter = character
            var boundaries: [CGFloat] = []
            for wordIndex in wordRange {
                let word = words[wordIndex]
                let measured = metrics[wordIndex]
                let count = measured.offsets.count - 1
                for offset in 0..<count { boundaries.append(x + measured.offsets[offset]) }
                switch mode {
                case .words:
                    units.append(.init(
                        text: word, rect: CGRect(x: x, y: top, width: measured.width, height: lineHeight),
                        row: rowIndex, word: wordIndex, characters: character..<(character + count)
                    ))
                case .letters:
                    for (offset, letter) in measured.letters.enumerated() {
                        let start = measured.offsets[offset]
                        let end = measured.offsets[offset + 1]
                        units.append(.init(
                            text: letter, rect: CGRect(x: x + start, y: top, width: max(1, end - start), height: lineHeight),
                            row: rowIndex, word: wordIndex, characters: (character + offset)..<(character + offset + 1)
                        ))
                    }
                }
                character += count
                x += measured.width + space
            }
            if let last = units.last, units.count > firstUnit {
                boundaries.append(last.rect.maxX)
            } else {
                boundaries.append(x)
            }
            let rowX = centered ? (width - rowWidth) / 2 : 0
            rows.append(.init(
                units: firstUnit..<units.count,
                text: wordRange.map { words[$0] }.joined(separator: " "),
                rect: CGRect(x: rowX, y: top, width: rowWidth, height: lineHeight),
                characters: firstCharacter..<character, boundaries: boundaries
            ))
        }
        let height = rows.isEmpty ? 0 : CGFloat(rows.count - 1) * rowHeight + lineHeight
        let widest = rows.map(\.rect.width).max() ?? 0
        return LyricLineLayout(
            units: units, rows: rows, size: CGSize(width: min(width, max(widest, 1)), height: height),
            rowHeight: rowHeight, baseline: ceil(ascent), characterCount: character, fit: fit, font: font
        )
    }

    private struct Measured {
        let width: CGFloat
        let letters: [String]
        /// Start of each letter, then the end of the last one.
        let offsets: [CGFloat]
    }

    private func measure(_ word: String, font: NSFont) -> Measured {
        let line = CTLineCreateWithAttributedString(attributed(word, font: font))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var letters: [String] = []
        var offsets: [CGFloat] = []
        var index = word.startIndex
        while index < word.endIndex {
            let next = word.index(after: index)
            let utf16 = word.utf16.distance(from: word.utf16.startIndex, to: index.samePosition(in: word.utf16) ?? word.utf16.startIndex)
            offsets.append(CTLineGetOffsetForStringIndex(line, utf16, nil))
            letters.append(String(word[index..<next]))
            index = next
        }
        offsets.append(width)
        return Measured(width: width, letters: letters, offsets: offsets)
    }

    private func advance(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text, font: font)), nil, nil, nil))
    }

    func attributed(_ text: String, font: NSFont) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

/// A unit of text drawn once into an image, with room around it for its
/// glow and shadow.
struct LyricSprite {
    let image: CGImage
    /// The image's size in points.
    let size: CGSize
    /// Points of padding on every side: the text's own box starts here.
    let inset: CGFloat
}

/// How a sprite's text is painted.
struct LyricInk: Hashable {
    var color: SRGBColor
    var alpha: Double = 1
    /// A soft dark shadow that keeps light text readable on light wallpapers.
    var shade: Double = 0.55
    var shadeBlur: Double = 7
    /// A coloured glow around the letters (neon, karaoke); 0 for none.
    var glow: Double = 0
    var glowColor: SRGBColor = .white
    var glowBlur: Double = 0
}

/// Draws and keeps sprites: the same text, font and ink are drawn once.
/// A few hundred stay (least recently used go first).
final class LyricSpriteCache {
    private struct Key: Hashable {
        let text: String
        let font: String
        let size: CGFloat
        let ink: LyricInk
        let tracking: CGFloat
        let scale: CGFloat
    }

    private var sprites: [Key: LyricSprite] = [:]
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int = 600) {
        self.limit = limit
    }

    func sprite(_ text: String, font: NSFont, ink: LyricInk, tracking: CGFloat = 0, scale: CGFloat) -> LyricSprite? {
        let key = Key(text: text, font: font.fontName, size: font.pointSize, ink: ink, tracking: tracking, scale: scale)
        if let sprite = sprites[key] { return sprite }
        guard let sprite = Self.draw(text, font: font, ink: ink, tracking: tracking, scale: scale) else { return nil }
        sprites[key] = sprite
        order.append(key)
        if order.count > limit {
            let drop = order.prefix(order.count - limit)
            drop.forEach { sprites[$0] = nil }
            order.removeFirst(drop.count)
        }
        return sprite
    }

    func removeAll() {
        sprites = [:]
        order = []
    }

    var count: Int { sprites.count }

    static func draw(_ text: String, font: NSFont, ink: LyricInk, tracking: CGFloat, scale: CGFloat) -> LyricSprite? {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(ink.color).withAlphaComponent(ink.alpha)]
        if tracking != 0 { attributes[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        // Glyphs (script capitals, accents) may reach past the advance box.
        let glyphBounds = CTLineGetImageBounds(line, nil)
        let overhang = max(0, -glyphBounds.minX, glyphBounds.maxX - width)
        let blur = max(ink.shade > 0 ? ink.shadeBlur : 0, ink.glow > 0 ? ink.glowBlur : 0)
        let inset = ceil(blur * 1.6 + 3 + overhang)
        let boxHeight = ceil(font.ascender - font.descender)
        let size = CGSize(width: ceil(width) + 2 * inset, height: boxHeight + 2 * inset)
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 16_384, pixelHeight < 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldSmoothFonts(false)
        // CoreText draws from the baseline in a y-up context.
        let origin = CGPoint(x: inset, y: inset + (-font.descender))
        func drawText() {
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        if ink.shade > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: ink.shadeBlur, color: CGColor(gray: 0, alpha: ink.shade))
            drawText()
            context.restoreGState()
        }
        if ink.glow > 0 {
            let glow = CGColor(srgbRed: ink.glowColor.red, green: ink.glowColor.green, blue: ink.glowColor.blue, alpha: min(1, ink.glow))
            context.saveGState()
            context.setShadow(offset: .zero, blur: ink.glowBlur, color: glow)
            drawText()
            drawText()
            context.restoreGState()
            context.saveGState()
            context.setShadow(offset: .zero, blur: ink.glowBlur * 0.35, color: glow)
            drawText()
            context.restoreGState()
        }
        drawText()
        guard let image = context.makeImage() else { return nil }
        return LyricSprite(image: image, size: size, inset: inset)
    }
}
