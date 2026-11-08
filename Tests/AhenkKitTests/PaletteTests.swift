import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Palette extraction")
struct PaletteTests {
    private func close(_ a: SRGBColor, _ b: SRGBColor, within distance: Double = 0.05) -> Bool {
        a.okLab.distance(to: b.okLab) < distance
    }

    @Test("OKLab round-trips and gamut-maps")
    func okLabRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#7C5CFF", "#0E5E6F", "#FFD9A0"] {
            let color = SRGBColor(hex: hex)!
            let back = SRGBColor(okLab: color.okLab)
            #expect(abs(back.red - color.red) < 1e-3 && abs(back.green - color.green) < 1e-3 && abs(back.blue - color.blue) < 1e-3, "\(hex)")
        }
        #expect(abs(SRGBColor.white.okLab.l - 1) < 1e-3)
        #expect(abs(SRGBColor.black.okLab.l) < 1e-3)
        #expect(SRGBColor(hex: "#808080")!.okLab.chroma < 1e-3, "grey has no chroma")
        // Far outside sRGB: lightness and hue are kept, chroma shrinks.
        let wild = SRGBColor(okLab: OKLab(l: 0.7, a: 0.4, b: 0.3))
        #expect(abs(wild.okLab.l - 0.7) < 0.01)
        #expect(wild.okLab.chroma < 0.5)
    }

    @Test("Readable variants reach the contrast target in the same hue")
    func readableVariants() {
        let dark = Palette.darkBackdrop
        for hex in ["#0E5E6F", "#5B3CC4", "#7A1F3D", "#1C2A4A", "#FF2E88", "#000000", "#FFC53D"] {
            let color = SRGBColor(hex: hex)!
            let onDark = color.readable(on: dark)
            #expect(onDark.contrastRatio(with: dark) >= 4.5, "\(hex) on dark")
            let onWhite = color.readable(on: .white)
            #expect(onWhite.contrastRatio(with: .white) >= 4.5, "\(hex) on white")
            if color.okLab.chroma > 0.05 {
                let hueShift = abs(remainder(onDark.okLab.hue - color.okLab.hue, 2 * .pi))
                #expect(hueShift < 0.35, "\(hex) keeps its hue on dark")
            }
        }
        let alreadyFine = SRGBColor(hex: "#FFD9A0")!
        #expect(alreadyFine.readable(on: dark) == alreadyFine, "unchanged when it already passes")
    }

    @Test("Palettes carry text-safe and vivid variants for every colour")
    func paletteVariants() {
        let palette = Palette(colors: [SRGBColor("#0E5E6F"), SRGBColor("#FF7A6B"), SRGBColor("#202020")])
        #expect(palette.onDark.count == 3 && palette.onLight.count == 3 && palette.vivid.count == 3)
        for color in palette.onDark { #expect(color.contrastRatio(with: Palette.darkBackdrop) >= 4.5) }
        for color in palette.onLight { #expect(color.contrastRatio(with: .white) >= 4.5) }
        #expect(palette.vivid[0].okLab.l >= 0.71, "light colours read as light")
        #expect(palette.vivid[0].okLab.chroma > palette.primary.okLab.chroma - 0.01)
        #expect(palette.backdrop.okLab.l <= 0.25)
        // Codable keeps only the colours and rebuilds the variants.
        let decoded = try? JSONDecoder().decode(Palette.self, from: JSONEncoder().encode(palette))
        #expect(decoded == palette)
        #expect(decoded?.onDark == palette.onDark)
    }

    @Test("A solid cover gives its colour plus two shades")
    func solid() {
        let red = SRGBColor("#D2302C")
        let swatches = PaletteExtractor.swatches(from: TestImages.solid(red))
        #expect(swatches.count == 3)
        #expect(close(swatches[0].color, red))
        #expect(swatches[0].population > 0.99)
        #expect(swatches[1].color.okLab.l != swatches[2].color.okLab.l)
    }

    @Test("Colours come out ordered by area")
    func orderedByArea() {
        let teal = SRGBColor("#0E7C86")
        let coral = SRGBColor("#FF6F59")
        let gold = SRGBColor("#F2C14E")
        let image = TestImages.bands([teal, coral, gold], weights: [6, 3, 1])
        let swatches = PaletteExtractor.swatches(from: image)
        #expect(swatches.count >= 3)
        #expect(close(swatches[0].color, teal))
        #expect(close(swatches[1].color, coral))
        #expect(close(swatches[2].color, gold))
        #expect(swatches[0].population > swatches[1].population)
    }

    @Test("A colourful accent beats a large grey background")
    func accentOverGrey() {
        let grey = SRGBColor("#2A2A2A")
        let magenta = SRGBColor("#E0218A")
        let swatches = PaletteExtractor.swatches(from: TestImages.bands([grey, magenta], weights: [85, 15]))
        #expect(close(swatches[0].color, magenta), "the light should glow magenta, not grey")
        #expect(swatches.contains { close($0.color, grey) }, "grey stays in the palette")
    }

    @Test("Greyscale covers still give three distinct colours")
    func greyscale() {
        let image = TestImages.gradient([SRGBColor("#111111"), SRGBColor("#EEEEEE")])
        let palette = PaletteExtractor.palette(from: image)
        #expect(palette.colors.count >= 3)
        #expect(Set(palette.colors).count == palette.colors.count)
        #expect(palette.colors.allSatisfy { $0.okLab.chroma < 0.05 })
    }

    @Test("A gradient gives several colours along it, deterministically")
    func gradient() {
        let image = TestImages.gradient([SRGBColor("#2F6BFF"), SRGBColor("#FF2E88"), SRGBColor("#FFC53D")])
        let first = PaletteExtractor.palette(from: image)
        let second = PaletteExtractor.palette(from: image)
        #expect(first == second)
        #expect(first.colors.count >= 3)
        #expect(first.colors.count <= PaletteExtractor.maximumColors)
    }

    @Test("Transparent pixels are ignored; a one-pixel image works")
    func edgeCases() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(SRGBColor("#3366CC").cgColor())
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 40))
        let swatches = PaletteExtractor.swatches(from: context.makeImage()!)
        #expect(close(swatches[0].color, SRGBColor("#3366CC")))
        #expect(swatches[0].population > 0.99, "only the opaque quarter counts")

        let tiny = PaletteExtractor.palette(from: TestImages.solid(SRGBColor("#44AA66"), width: 1, height: 1))
        #expect(tiny.colors.count == 3)
    }
}
