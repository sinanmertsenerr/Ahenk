import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Lyrics style math")
struct LyricsStyleMathTests {
    @Test("Wrapping: one row when it fits, balanced rows when not, a long word alone")
    func wrapping() {
        let widths: [Double] = [60, 40, 80, 50, 70]
        #expect(LyricsWrap.rows(widths: widths, space: 10, maxWidth: 400) == [0..<5])
        let rows = LyricsWrap.rows(widths: widths, space: 10, maxWidth: 200)
        #expect(rows.count == 2)
        let lengths = rows.map { LyricsWrap.width(of: $0, widths: widths, space: 10) }
        #expect(lengths.allSatisfy { $0 <= 200 })
        #expect(abs(lengths[0] - lengths[1]) <= 70, "balanced, not one long and one short row")
        #expect(LyricsWrap.rows(widths: [500, 20], space: 10, maxWidth: 200) == [0..<1, 1..<2])
        #expect(LyricsWrap.rows(widths: [], space: 10, maxWidth: 200).isEmpty)
    }

    @Test("Fisheye: the word under the lens is largest and the rest shrink with distance")
    func fisheye() {
        let centers = [0.1, 0.3, 0.5, 0.7, 0.9]
        let scales = FisheyeLens.scales(centers: centers, focus: 0.5, radius: 0.2, minimum: 0.7, maximum: 1)
        #expect(abs(scales[2] - 1) < 1e-9)
        #expect(scales[1] < scales[2] && scales[0] < scales[1] && abs(scales[1] - scales[3]) < 1e-9)
        #expect(scales.allSatisfy { $0 >= 0.7 && $0 <= 1 })
        let widths = [80.0, 60, 100, 40, 90]
        let lefts = FisheyeLens.pack(widths: widths, scales: scales, space: 10, leading: true, origin: 0, center: 0)
        #expect(lefts[0] == 0)
        for index in 1..<lefts.count {
            #expect(lefts[index] >= lefts[index - 1] + widths[index - 1] * scales[index - 1], "words never overlap")
        }
        let centered = FisheyeLens.pack(widths: widths, scales: scales, space: 10, leading: false, origin: 0, center: 300)
        let right = centered.last! + widths.last! * scales.last!
        #expect(abs((centered[0] + right) / 2 - 300) < 1e-9)
        #expect(abs(FisheyeLens.bob(index: 0, beatPhase: 0.25, energy: 1, amplitude: 3) - 3) < 1e-9)
    }

    @Test("Karaoke: rows light up in order, up to their last letter")
    func karaoke() {
        #expect(KaraokeFill.litPerRow(progress: 0, counts: [10, 6]) == [0, 0])
        #expect(KaraokeFill.litPerRow(progress: 0.5, counts: [10, 6]) == [8, 0])
        #expect(KaraokeFill.litPerRow(progress: 1, counts: [10, 6]) == [10, 6])
        let boundaries: [Double] = [0, 10, 25, 30]
        #expect(KaraokeFill.width(lit: 0, boundaries: boundaries) == 0)
        #expect(KaraokeFill.width(lit: 1.5, boundaries: boundaries) == 17.5)
        #expect(KaraokeFill.width(lit: 3, boundaries: boundaries) == 30)
        #expect(KaraokeFill.width(lit: 9, boundaries: boundaries) == 30)
        #expect(KaraokeFill.width(lit: 1, boundaries: [0]) == 0)
    }

    @Test("Typewriter: letters are typed one after another and finish before the singing does")
    func typewriter() {
        #expect(TypewriterReveal.typed(progress: 0, count: 20) == 0)
        #expect(TypewriterReveal.typed(progress: 0.85, count: 20) == 20)
        #expect(TypewriterReveal.typed(progress: 0.425, count: 20) == 10)
        #expect(TypewriterReveal.strike(index: 5, typed: 4) == 0)
        #expect(abs(TypewriterReveal.strike(index: 5, typed: 5.8) - 0.5) < 1e-9)
        #expect(TypewriterReveal.strike(index: 5, typed: 9) == 1)
    }

    @Test("Spread: letters come in from wide, rest in place, leave wide")
    func spread() {
        #expect(abs(SpreadMotion.factor(enter: 0, sung: 0, exit: 0, beat: 0) - 1.9) < 1e-9)
        #expect(abs(SpreadMotion.factor(enter: 1, sung: 0, exit: 0, beat: 0) - 1) < 1e-9)
        #expect(SpreadMotion.factor(enter: 1, sung: 1, exit: 0, beat: 0) > 1)
        #expect(SpreadMotion.factor(enter: 1, sung: 1, exit: 1, beat: 0) > 2)
        let middle = SpreadMotion.opacity(index: 5, count: 11, enter: 0.3, exit: 0)
        let edge = SpreadMotion.opacity(index: 0, count: 11, enter: 0.3, exit: 0)
        #expect(middle > edge, "the middle appears first")
        #expect(SpreadMotion.opacity(index: 0, count: 11, enter: 1, exit: 0) == 1)
        #expect(SpreadMotion.opacity(index: 0, count: 11, enter: 1, exit: 1) == 0)
    }

    @Test("Neon: words light up in order with a flicker, then hum")
    func neon() {
        let times = (0..<4).map { NeonSign.ignitionTime(index: $0, count: 4, sungDuration: 3) }
        #expect(times == times.sorted() && times[0] == 0 && times[3] < 1.4)
        #expect(NeonSign.ignition(since: -0.1, seed: 1) == 0)
        #expect(NeonSign.ignition(since: 0.5, seed: 1) == 1)
        #expect(NeonSign.ignition(since: 0.1, seed: 9) == NeonSign.ignition(since: 0.1, seed: 9), "the same flicker every time")
        for step in 0..<200 {
            let hum = NeonSign.hum(time: Double(step) * 0.05, seed: 3)
            #expect(hum >= 0.5 && hum <= 1)
        }
    }

    @Test("Echo: copies lag behind the line; a beat's ripple grows and fades")
    func echo() {
        #expect(EchoTrail.delayed(0.5, copy: 1, delay: 0.07, duration: 0.5) < 0.5)
        #expect(EchoTrail.delayed(1, copy: 3, delay: 0.07, duration: 0.5) < 1)
        let start = EchoTrail.ripple(sinceBeat: 0, strength: 1)
        let later = EchoTrail.ripple(sinceBeat: 0.3, strength: 1)
        #expect(start.scale == 1 && start.opacity > later.opacity && later.scale > 1)
        #expect(EchoTrail.ripple(sinceBeat: 2, strength: 1).opacity == 0)
        #expect(EchoTrail.ripple(sinceBeat: .infinity, strength: 1).opacity == 0)
    }

    @Test("Glitch: a line decodes from left to right and is whole after the decode; tears only on strong beats")
    func glitch() {
        let count = 12
        let early = (0..<count).map { GlitchMotion.scramble(index: $0, count: count, sinceStart: 0.2, seed: 4, alphabetSize: 20) }
        #expect(early.first! == nil && early.last! != nil, "left letters resolve first")
        #expect((0..<count).allSatisfy { GlitchMotion.scramble(index: $0, count: count, sinceStart: GlitchMotion.decodeDuration, seed: 4, alphabetSize: 20) == nil })
        #expect(GlitchMotion.scramble(index: 11, count: count, sinceStart: 0.1, seed: 4, alphabetSize: 20)
            == GlitchMotion.scramble(index: 11, count: count, sinceStart: 0.1, seed: 4, alphabetSize: 20))
        #expect(GlitchMotion.tear(beatIndex: 4, sinceBeat: 0.02, strength: 1) > 0)
        #expect(GlitchMotion.tear(beatIndex: 5, sinceBeat: 0.02, strength: 1) == 0)
        #expect(GlitchMotion.tear(beatIndex: 4, sinceBeat: 0.02, strength: 0.3) == 0)
        #expect(GlitchMotion.tear(beatIndex: 4, sinceBeat: 0.5, strength: 1) == 0)
        #expect(GlitchMotion.sliceOffset(slice: 2, beatIndex: 4, intensity: 0, maximum: 16) == 0)
        #expect(abs(GlitchMotion.sliceOffset(slice: 2, beatIndex: 4, intensity: 1, maximum: 16)) <= 16)
        #expect(GlitchMotion.split(onset: 1, decoding: false) > GlitchMotion.split(onset: 0, decoding: false))
    }

    @Test("Cinema: a slow fade with a settling zoom and a hairline that follows the singing")
    func cinema() {
        let start = CinemaMotion.frame(enter: 0, exit: 0, sinceStart: 0)
        let settled = CinemaMotion.frame(enter: 1, exit: 0, sinceStart: 8)
        let gone = CinemaMotion.frame(enter: 1, exit: 1, sinceStart: 8)
        #expect(start.opacity == 0 && settled.opacity == 1 && gone.opacity == 0)
        #expect(start.scale > settled.scale && abs(settled.scale - 1) < 1e-9)
        #expect(CinemaMotion.hairline(sung: 0, exit: 0) == 0 && CinemaMotion.hairline(sung: 1, exit: 0) == 1)
        #expect(CinemaMotion.hairline(sung: 1, exit: 1) == 0)
    }

    @Test("The countdown ring empties as the pause passes; easing stays in range")
    func countdownAndEasing() {
        #expect(LyricsCountdown.ring(fraction: 0) == 1 && LyricsCountdown.ring(fraction: 1) == 0)
        #expect(LyricsCountdown.ring(fraction: 2) == 0)
        for x in stride(from: -0.5, through: 1.5, by: 0.1) {
            #expect((0...1).contains(LyricsEasing.outCubic(x)) && (0...1).contains(LyricsEasing.inOutCubic(x)))
        }
        #expect(LyricsEasing.outBack(0.7) > 1, "a slight overshoot")
        #expect(LyricsEasing.unit(.nan) == 0)
        #expect(LyricsNoise.unit(1, 2, 3) == LyricsNoise.unit(1, 2, 3))
        #expect((0..<1).contains(LyricsNoise.unit(99, -5, 7)))
    }

    @Test("Colors: light ink from the cover's most colorful color, readable on dark; white without album colors")
    func colors() {
        let palette = Palette(colors: [SRGBColor("#0E5E6F"), SRGBColor("#FF7A6B"), SRGBColor("#FFD9A0")])
        let colors = LyricsColors(palette: palette, useAlbumColors: true)
        #expect(colors.ink.okLab.l >= 0.87)
        #expect(colors.ink.contrastRatio(with: Palette.darkBackdrop) >= 7)
        #expect(colors.ink.okLab.a > 0, "a warm tone from the coral, not the teal")
        #expect(colors.accents.count == 3 && colors.accent(4) == colors.accents[1])
        #expect(LyricsColors(palette: palette, useAlbumColors: false) == .plain)
        let grey = LyricsColors(palette: Palette(colors: [SRGBColor("#808080")]), useAlbumColors: true)
        #expect(grey.ink.okLab.chroma < 0.02)
    }

    @Test("The widget grows with the text and is narrower without the cover")
    func layout() {
        let base = LyricsLayout.widgetSize(textScale: 1, showsCover: true)
        let large = LyricsLayout.widgetSize(textScale: 1.5, showsCover: true)
        let bare = LyricsLayout.widgetSize(textScale: 1, showsCover: false)
        #expect(large.width > base.width && large.height > base.height)
        #expect(bare.width < base.width && bare.height <= base.height)
        #expect(LyricsLayout.widgetSize(textScale: 99, showsCover: true) == LyricsLayout.widgetSize(textScale: 1.6, showsCover: true))
        #expect(LyricsLayout.coverSide(textScale: 1.5) > LyricsLayout.coverSide(textScale: 1))
    }
}
