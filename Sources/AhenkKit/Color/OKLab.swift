import Foundation

/// A colour in Björn Ottosson's OKLab space: `l` is perceived lightness
/// (0 black … 1 white), `a`/`b` the green–red and blue–yellow axes.
/// Distances in OKLab track perceived differences, which is what palette
/// clustering and lightness adjustments need.
public struct OKLab: Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// Colourfulness: 0 for greys, about 0.3 for the most vivid sRGB colours.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// Hue angle in radians.
    public var hue: Double { atan2(b, a) }

    public func distance(to other: OKLab) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// The same hue with another lightness and chroma.
    public func with(lightness: Double? = nil, chroma newChroma: Double? = nil) -> OKLab {
        let currentChroma = chroma
        let targetChroma = max(0, newChroma ?? currentChroma)
        let scale = currentChroma > 1e-9 ? targetChroma / currentChroma : 0
        return OKLab(l: lightness ?? l, a: a * scale, b: b * scale)
    }
}

extension SRGBColor {
    public var okLab: OKLab {
        let r = Self.linear(red)
        let g = Self.linear(green)
        let b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Converts from OKLab. Colours outside sRGB keep their lightness and
    /// hue and lose just enough chroma to fit.
    public init(okLab lab: OKLab) {
        let lightness = min(1, max(0, lab.l))
        if let exact = Self.convert(OKLab(l: lightness, a: lab.a, b: lab.b)) {
            self = exact
            return
        }
        var low = 0.0
        var high = lab.chroma
        var best = Self.convert(OKLab(l: lightness, a: 0, b: 0)) ?? SRGBColor(red: lightness, green: lightness, blue: lightness)
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if let fitted = Self.convert(lab.with(lightness: lightness, chroma: mid)) {
                best = fitted
                low = mid
            } else {
                high = mid
            }
        }
        self = best
    }

    /// `nil` when the colour falls outside the sRGB gamut.
    private static func convert(_ lab: OKLab) -> SRGBColor? {
        let l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        let tolerance = 1e-4
        guard [r, g, b].allSatisfy({ $0 >= -tolerance && $0 <= 1 + tolerance }) else { return nil }
        return SRGBColor(red: gamma(r), green: gamma(g), blue: gamma(b))
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        let v = min(1, max(0, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// The same hue made just light (or dark) enough to reach
    /// `minimumContrast` against `background`. Lightness moves away from the
    /// background; if even white or black cannot reach it, the closest
    /// extreme is returned.
    public func readable(on background: SRGBColor, minimumContrast: Double = 4.5) -> SRGBColor {
        if contrastRatio(with: background) >= minimumContrast { return self }
        let lab = okLab
        let goLighter = background.luminance < 0.18
        var low = lab.l
        var high = goLighter ? 1.0 : 0.0
        let extreme = SRGBColor(okLab: lab.with(lightness: high))
        guard extreme.contrastRatio(with: background) >= minimumContrast else {
            return goLighter ? .white : .black
        }
        var best = extreme
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let candidate = SRGBColor(okLab: lab.with(lightness: mid))
            if candidate.contrastRatio(with: background) >= minimumContrast {
                best = candidate
                high = mid
            } else {
                low = mid
            }
        }
        return best
    }
}
