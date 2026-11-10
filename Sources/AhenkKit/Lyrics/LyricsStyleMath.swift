import CoreGraphics
import Foundation

// The numbers behind the eight lyric styles: pure functions of time and
// layout, so every frame can be computed (and tested) without drawing.
// The app turns them into Core Animation layer properties.

/// Easing curves (input and output 0…1).
public enum LyricsEasing {
    public static func outCubic(_ x: Double) -> Double {
        let t = 1 - unit(x)
        return 1 - t * t * t
    }

    public static func inOutCubic(_ x: Double) -> Double {
        let t = unit(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Overshoots a little before settling (a spring without the bounce).
    public static func outBack(_ x: Double, overshoot: Double = 1.6) -> Double {
        let t = unit(x) - 1
        return 1 + (overshoot + 1) * t * t * t + overshoot * t * t
    }

    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = unit((x - edge0) / max(1e-9, edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    public static func unit(_ x: Double) -> Double {
        x.isFinite ? min(1, max(0, x)) : 0
    }
}

/// Deterministic noise for flicker and glitches: the same inputs always
/// give the same value, so previews, checks and the desktop agree.
public enum LyricsNoise {
    /// Uniform in 0..<1.
    public static func unit(_ seed: UInt64, _ a: Int, _ b: Int = 0) -> Double {
        var z = seed &+ UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Uniform in -1..<1.
    public static func signed(_ seed: UInt64, _ a: Int, _ b: Int = 0) -> Double {
        unit(seed, a, b) * 2 - 1
    }
}

/// Breaks a line into rows that fit a width, evened out.
public enum LyricsWrap {
    /// The words on each row (ranges into `widths`): as few rows as fit
    /// `maxWidth` one after the other, then balanced so the rows end up
    /// about as long as each other. A word wider than `maxWidth` gets a row
    /// of its own.
    public static func rows(widths: [Double], space: Double, maxWidth: Double) -> [Range<Int>] {
        guard !widths.isEmpty else { return [] }
        let greedy = greedyRows(widths: widths, space: space, maxWidth: maxWidth)
        guard greedy.count > 1 else { return greedy }
        // The narrowest width that still needs no more rows.
        var low = widths.max() ?? 0
        var high = maxWidth
        for _ in 0..<24 where high - low > 0.5 {
            let middle = (low + high) / 2
            if greedyRows(widths: widths, space: space, maxWidth: middle).count <= greedy.count {
                high = middle
            } else {
                low = middle
            }
        }
        return greedyRows(widths: widths, space: space, maxWidth: high)
    }

    static func greedyRows(widths: [Double], space: Double, maxWidth: Double) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var width = 0.0
        for (index, word) in widths.enumerated() {
            if index > start, width + space + word > maxWidth + 0.001 {
                rows.append(start..<index)
                start = index
                width = word
            } else {
                width += (index > start ? space : 0) + word
            }
        }
        rows.append(start..<widths.count)
        return rows
    }

    /// The width of a row of `widths` joined by `space`.
    public static func width(of row: Range<Int>, widths: [Double], space: Double) -> Double {
        guard !row.isEmpty else { return 0 }
        return row.reduce(0) { $0 + widths[$1] } + space * Double(row.count - 1)
    }
}

/// Karaoke: the line lights up from its first letter to its last as it is sung.
public enum KaraokeFill {
    /// How far a row is lit, in points. `boundaries` are the x positions of
    /// the row's character boundaries (`count + 1` values from its left
    /// edge); `lit` is how many of the row's characters are sung
    /// (fractional).
    public static func width(lit: Double, boundaries: [Double]) -> Double {
        guard let last = boundaries.last, boundaries.count > 1 else { return 0 }
        let position = min(Double(boundaries.count - 1), max(0, lit))
        let index = Int(position.rounded(.down))
        if index >= boundaries.count - 1 { return last }
        let fraction = position - Double(index)
        return boundaries[index] + (boundaries[index + 1] - boundaries[index]) * fraction
    }

    /// The characters sung on each row, for a line `progress` (0…1 of all
    /// its characters) over rows of `counts` characters.
    public static func litPerRow(progress: Double, counts: [Int]) -> [Double] {
        let total = Double(counts.reduce(0, +))
        var remaining = LyricsEasing.unit(progress) * total
        return counts.map { count in
            let lit = min(Double(count), max(0, remaining))
            remaining -= Double(count)
            return lit
        }
    }
}

/// Typewriter: letters strike one after another while the line is sung.
public enum TypewriterReveal {
    /// Letters typed (fractional) when `progress` (0…1) of the line has
    /// been sung; typing finishes at `share` of the singing.
    public static func typed(progress: Double, count: Int, share: Double = 0.85) -> Double {
        min(1, LyricsEasing.unit(progress) / max(0.05, share)) * Double(count)
    }

    /// The strike of letter `index`: 0 before it is typed, rising to 1 over
    /// `length` letters' worth of typing.
    public static func strike(index: Int, typed: Double, length: Double = 1.6) -> Double {
        LyricsEasing.unit((typed - Double(index)) / max(0.01, length))
    }
}

/// Glitch: a new line decodes out of noise; strong beats tear it.
public enum GlitchMotion {
    public static let decodeDuration: Double = 0.5

    /// While a line decodes, letter `index` of `count` shows a random
    /// character (`alphabetSize` to choose from) that changes 25 times a
    /// second; `nil` once the letter has resolved (left to right).
    public static func scramble(index: Int, count: Int, sinceStart: Double, seed: UInt64, alphabetSize: Int) -> Int? {
        guard alphabetSize > 0, count > 0 else { return nil }
        let resolveAt = decodeDuration * (0.35 + 0.65 * Double(index) / Double(max(1, count - 1)))
        guard sinceStart < resolveAt else { return nil }
        let step = Int(max(0, sinceStart) * 25)
        return Int(LyricsNoise.unit(seed, index, step) * Double(alphabetSize)) % alphabetSize
    }

    /// How strongly the line tears `sinceBeat` seconds after a beat (only
    /// every other strong beat, briefly).
    public static func tear(beatIndex: Int, sinceBeat: Double, strength: Double) -> Double {
        guard strength > 0.55, beatIndex % 2 == 0, sinceBeat >= 0, sinceBeat < 0.14 else { return 0 }
        return (1 - sinceBeat / 0.14) * LyricsEasing.unit((strength - 0.55) / 0.45)
    }

    /// The sideways shift of slice `slice` during a tear of `intensity`.
    public static func sliceOffset(slice: Int, beatIndex: Int, intensity: Double, maximum: Double) -> Double {
        guard intensity > 0 else { return 0 }
        let chosen = LyricsNoise.unit(0x611C_4E5E, beatIndex, slice) > 0.4
        return chosen ? LyricsNoise.signed(0x611C_4E5F, beatIndex, slice) * maximum * intensity : 0
    }

    /// The red/cyan split, in points: wider with onsets and while decoding.
    public static func split(onset: Double, decoding: Bool) -> Double {
        (decoding ? 3.5 : 1.8) + 3 * LyricsEasing.unit(onset)
    }
}

/// Cinema: a film title's slow fade, a gentle zoom and a hairline that
/// grows as the line is sung.
public enum CinemaMotion {
    public struct Frame: Equatable, Sendable {
        public var opacity: Double
        public var scale: Double
        /// Points the line has risen.
        public var rise: Double
    }

    public static func frame(enter: Double, exit: Double, sinceStart: Double) -> Frame {
        let fadeIn = LyricsEasing.smoothstep(0, 1, enter)
        let fadeOut = 1 - LyricsEasing.smoothstep(0, 1, exit)
        let settle = LyricsEasing.unit(sinceStart / 6)
        return Frame(opacity: fadeIn * fadeOut, scale: 1.035 - 0.035 * LyricsEasing.outCubic(settle), rise: 6 * LyricsEasing.outCubic(enter) + 8 * exit)
    }

    /// The hairline's share of its full width.
    public static func hairline(sung: Double, exit: Double) -> Double {
        LyricsEasing.outCubic(sung) * (1 - LyricsEasing.unit(exit))
    }
}

/// The instrumental part's countdown and note.
public enum LyricsCountdown {
    /// The ring's share left (1 at the start of the pause, 0 when the next
    /// line comes).
    public static func ring(fraction: Double) -> Double {
        1 - LyricsEasing.unit(fraction)
    }

    /// The note's hop with the beat (points).
    public static func hop(beatPhase: Double, beat: Double, amplitude: Double) -> Double {
        let phase = LyricsEasing.unit(beatPhase)
        return amplitude * (0.35 * sin(phase * .pi) + 0.65 * LyricsEasing.unit(beat))
    }
}

/// The lyrics widget's size.
public enum LyricsLayout {
    /// Widest the text column gets at text scale 1.
    public static let columnWidth: Double = 560
    public static let height: Double = 300
    public static let coverSide: Double = 176
    public static let coverGap: Double = 30
    public static let margin: Double = 22

    public static func scaled(_ value: Double, textScale: Double) -> Double {
        value * min(1.6, max(0.6, textScale.isFinite ? textScale : 1))
    }

    public static func widgetSize(textScale: Double, showsCover: Bool) -> CGSize {
        let textScale = min(1.6, max(0.6, textScale.isFinite ? textScale : 1))
        let column = scaled(columnWidth, textScale: textScale)
        let cover = showsCover ? scaled(coverSide, textScale: (textScale + 2) / 3) + coverGap : 0
        let height = max(scaled(height, textScale: textScale), showsCover ? scaled(coverSide, textScale: (textScale + 2) / 3) + 2 * margin : 0)
        return CGSize(width: (2 * margin + cover + column).rounded(), height: height.rounded())
    }

    /// The cover's side (it grows with the text, more slowly).
    public static func coverSide(textScale: Double) -> Double {
        let textScale = min(1.6, max(0.6, textScale.isFinite ? textScale : 1))
        return scaled(coverSide, textScale: (textScale + 2) / 3).rounded()
    }
}

/// The lyrics' colours from the cover.
public struct LyricsColors: Equatable, Sendable {
    /// The lines: a light tone of the cover's most colourful colour, so
    /// they read on any dark or busy wallpaper (with their shadow).
    public let ink: SRGBColor
    /// Glows, fills and accents: the cover's colours made vivid, the most
    /// colourful first.
    public let accents: [SRGBColor]

    /// Without album colours: white lines, warm and cool accents.
    public static let plain = LyricsColors(
        ink: .white,
        accents: [SRGBColor(red: 1, green: 0.84, blue: 0.4), SRGBColor(red: 0.55, green: 0.85, blue: 1), SRGBColor(red: 1, green: 0.55, blue: 0.75)]
    )

    public init(ink: SRGBColor, accents: [SRGBColor]) {
        self.ink = ink
        self.accents = accents
    }

    public init(palette: Palette, useAlbumColors: Bool) {
        guard useAlbumColors else {
            self = .plain
            return
        }
        let labs = palette.colors.map(\.okLab)
        let best = labs.max { ($0.chroma * 3 + $0.l * 0.5) < ($1.chroma * 3 + $1.l * 0.5) } ?? OKLab(l: 1, a: 0, b: 0)
        ink = SRGBColor(okLab: best.with(lightness: max(0.88, best.l), chroma: min(0.1, max(best.chroma > 0.02 ? 0.045 : 0, best.chroma))))
        let vivid = zip(palette.vivid, palette.colors.map(\.okLab.chroma)).sorted { $0.1 > $1.1 }.map(\.0)
        accents = vivid.isEmpty ? LyricsColors.plain.accents : vivid
    }

    public func accent(_ index: Int) -> SRGBColor {
        accents[((index % accents.count) + accents.count) % accents.count]
    }
}
