import Foundation

/// An opaque sRGB colour with components in `0...1`.
///
/// Encodes as a `"#RRGGBB"` string so persisted settings stay readable in
/// `defaults read com.sinanmertsener.Ahenk`.
public struct SRGBColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    /// Parses `"#RRGGBB"`, `"RRGGBB"`, `"#RGB"` or `"RGB"` (case-insensitive).
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16)
        else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Builds a colour from a hex literal written in source code. Traps on a
    /// malformed literal, which is a programming error caught by the tests.
    public init(_ hexLiteral: StaticString) {
        guard let color = SRGBColor(hex: "\(hexLiteral)") else {
            preconditionFailure("Malformed colour literal \(hexLiteral)")
        }
        self = color
    }

    /// `"#RRGGBB"`, upper case.
    public var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public var description: String { hex }

    /// WCAG relative luminance in `0...1`.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio against `other`, in `1...21`.
    public func contrastRatio(with other: SRGBColor) -> Double {
        let a = luminance + 0.05
        let b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    /// Linear blend towards `other`; `amount` 0 keeps `self`, 1 gives `other`.
    public func mixed(with other: SRGBColor, amount: Double) -> SRGBColor {
        let t = Self.clamp(amount)
        return SRGBColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    public static let white = SRGBColor(red: 1, green: 1, blue: 1)
    public static let black = SRGBColor(red: 0, green: 0, blue: 0)

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = SRGBColor(hex: string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a #RRGGBB colour: \(string)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
