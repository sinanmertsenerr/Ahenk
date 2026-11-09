import AhenkKit
import AppKit
import SwiftUI

extension Color {
    init(_ rgb: SRGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

extension SRGBColor {
    /// The sRGB value of a SwiftUI colour (alpha is dropped).
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}

extension NSColor {
    convenience init(_ rgb: SRGBColor) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension SRGBColor {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    func cgColor(alpha: Double) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
