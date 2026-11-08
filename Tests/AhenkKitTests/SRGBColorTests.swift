import Foundation
import Testing
@testable import AhenkKit

@Suite("SRGBColor and Palette")
struct SRGBColorTests {
    @Test("Parses long and short hex forms", arguments: [
        ("#FF8800", "#FF8800"), ("ff8800", "#FF8800"), ("#f80", "#FF8800"), (" #0a0B0c ", "#0A0B0C"),
    ])
    func parsesHex(input: String, expected: String) throws {
        #expect(try #require(SRGBColor(hex: input)).hex == expected)
    }

    @Test("Rejects malformed hex", arguments: ["", "#", "#12", "#12345", "#1234567", "#GGGGGG", "red"])
    func rejectsMalformedHex(input: String) {
        #expect(SRGBColor(hex: input) == nil)
    }

    @Test("Components are clamped")
    func clamps() {
        let c = SRGBColor(red: 2, green: -1, blue: .nan)
        #expect(c.red == 1 && c.green == 0 && c.blue == 0)
    }

    @Test("Codes as a hex string")
    func codable() throws {
        let data = try JSONEncoder().encode([SRGBColor("#123456")])
        #expect(String(decoding: data, as: UTF8.self) == ##"["#123456"]"##)
        let decoded = try JSONDecoder().decode([SRGBColor].self, from: data)
        #expect(decoded == [SRGBColor("#123456")])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([SRGBColor].self, from: Data(#"["blue"]"#.utf8))
        }
    }

    @Test("Luminance and contrast follow WCAG")
    func contrast() {
        #expect(abs(SRGBColor.white.luminance - 1) < 1e-9)
        #expect(SRGBColor.black.luminance == 0)
        #expect(abs(SRGBColor.white.contrastRatio(with: .black) - 21) < 1e-9)
        #expect(SRGBColor("#777777").contrastRatio(with: SRGBColor("#777777")) == 1)
    }

    @Test("Mixing blends linearly")
    func mixing() {
        let mid = SRGBColor.black.mixed(with: .white, amount: 0.5)
        #expect(abs(mid.red - 0.5) < 1e-9)
        #expect(SRGBColor.black.mixed(with: .white, amount: 7) == .white)
    }

    @Test("Palette accessors fall back gracefully")
    func paletteFallbacks() {
        let one = Palette(colors: [SRGBColor("#102030")])
        #expect(one.secondary == one.primary && one.tertiary == one.primary)
        #expect(Palette(colors: []) == Palette.neutral)
    }
}
