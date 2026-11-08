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
