// Draws the browser extension's toolbar icons (Extension/icons/icon*.png):
// a rounded square in Ahenk's violet with four bars rising like a level
// meter around a ring. Our own artwork, generated, no external assets.
//
//   swift Scripts/make-extension-icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("Extension/icons", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.04, dy: s * 0.04)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.24, yRadius: s * 0.24)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.20, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.28, blue: 0.62, alpha: 1),
    ])
    gradient?.draw(in: shape, angle: -55)
    // A soft ring.
    NSColor(white: 1, alpha: 0.35).setStroke()
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.17, dy: s * 0.17))
    ring.lineWidth = max(1, s * 0.05)
    ring.stroke()
    // Four bars like a level meter.
    NSColor.white.setFill()
    let heights: [CGFloat] = [0.26, 0.44, 0.34, 0.2]
    let barWidth = s * 0.085
    let gap = s * 0.05
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (s - total) / 2
    for height in heights {
        let h = s * height
        let bar = NSRect(x: x, y: (s - h) / 2, width: barWidth, height: h)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

for size in [16, 32, 48, 128] {
    guard let data = draw(size: size) else { fatalError("could not draw \(size)") }
    try data.write(to: folder.appendingPathComponent("icon\(size).png"))
    print("icon\(size).png")
}
