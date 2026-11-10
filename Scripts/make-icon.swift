// Draws Ahenk's app icon and writes AppIcon.icns (every size macOS asks
// for) plus a 1024 px PNG. The design is Ahenk's own: a night-blue tile
// whose edge glows in four colours, like the edge light around a screen,
// and a ring in the same colours around a warm disc, like the Dock icon
// while a song plays (cover and beating ring).
//
//   swift Scripts/make-icon.swift <output folder>
//
// make-app.sh runs it when the script is newer than its last output.
import AppKit
import CoreImage
import Foundation
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: swift Scripts/make-icon.swift <output folder>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
let canvas = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255, alpha: alpha
    )
}

/// The colours of the light, in turn around the circle (the last one
/// closes the loop).
let lightStops: [(Double, UInt32)] = [(0, 0xFF5E7A), (0.22, 0xFFB547), (0.45, 0x34D6C4), (0.65, 0x4C8DFF), (0.84, 0x9B6BFF), (1, 0xFF5E7A)]

func lightColor(at t: Double) -> CGColor {
    func channels(_ hex: UInt32) -> [Double] { [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)].map { $0 / 255 } }
    let t = t - floor(t)
    let upper = lightStops.firstIndex { $0.0 >= t } ?? lightStops.count - 1
    let lower = max(0, upper - 1)
    let span = lightStops[upper].0 - lightStops[lower].0
    let f = span > 0 ? (t - lightStops[lower].0) / span : 0
    let a = channels(lightStops[lower].1), b = channels(lightStops[upper].1)
    return CGColor(srgbRed: a[0] + (b[0] - a[0]) * f, green: a[1] + (b[1] - a[1]) * f, blue: a[2] + (b[2] - a[2]) * f, alpha: 1)
}

/// A conic gradient around `center` from `angle`, as thin wedges (Core
/// Graphics on macOS has no conic gradient of its own).
func drawConic(in context: CGContext, center: CGPoint, angle: Double) {
    let steps = 720
    let reach = canvas * 2
    for step in 0..<steps {
        let a0 = angle + Double(step) / Double(steps) * 2 * .pi
        let a1 = angle + Double(step + 1) / Double(steps) * 2 * .pi + 0.002
        context.move(to: center)
        context.addLine(to: CGPoint(x: center.x + cos(a0) * reach, y: center.y + sin(a0) * reach))
        context.addLine(to: CGPoint(x: center.x + cos(a1) * reach, y: center.y + sin(a1) * reach))
        context.closePath()
        context.setFillColor(lightColor(at: (Double(step) + 0.5) / Double(steps)))
        context.fillPath()
    }
}

/// A transparent 1024 × 1024 layer, drawn by `draw`.
func layer(_ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}

let ciContext = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])

func blurred(_ image: CGImage, radius: Double) -> CGImage {
    let input = CIImage(cgImage: image).clampedToExtent()
    let blur = input.applyingGaussianBlur(sigma: radius).cropped(to: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    return ciContext.createCGImage(blur, from: blur.extent)!
}

/// macOS's icon grid: an 824 pt tile with continuous corners in the 1024
/// canvas, room for the shadow around it.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tileRect).cgPath
let center = CGPoint(x: canvas / 2, y: canvas / 2 - 4)

/// A stroke of `path`, coloured by the light's conic gradient.
func lightStroke(_ path: CGPath, width: Double, in context: CGContext, angle: Double = .pi / 2) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    drawConic(in: context, center: center, angle: angle)
    context.restoreGState()
}

// The tile: a deep night gradient with a soft lift in the middle.
let tile = layer { context in
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x0D0B1A))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let base = CGGradient(colorsSpace: space, colors: [color(0x231A45), color(0x120E25), color(0x09080F)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: [])
    let lift = CGGradient(colorsSpace: space, colors: [color(0x3B2C6E, 0.55), color(0x3B2C6E, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(lift, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])
    context.restoreGState()
}

// The edge light: a thin line just inside the tile's edge and its halo.
let edgePath = RoundedRectangle(cornerRadius: 158, style: .continuous).path(in: tileRect.insetBy(dx: 26, dy: 26)).cgPath
let edgeLine = layer { lightStroke(edgePath, width: 9, in: $0) }
let edgeHalo = blurred(layer { lightStroke(edgePath, width: 34, in: $0) }, radius: 22)

// The ring around the cover, its halo, and the warm disc in the middle.
let ringRadius = 218.0
let ringPath = CGPath(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2), transform: nil)
let ringLine = layer { lightStroke(ringPath, width: 44, in: $0, angle: -.pi / 3) }
let ringHalo = blurred(layer { lightStroke(ringPath, width: 70, in: $0, angle: -.pi / 3) }, radius: 30)
let disc = layer { context in
    let radius = 128.0
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.saveGState()
    context.addEllipse(in: rect)
    context.clip()
    let warm = CGGradient(colorsSpace: space, colors: [color(0xFFE2B0), color(0xFFB27A), color(0xF2706F)] as CFArray, locations: [0, 0.55, 1])!
    context.drawRadialGradient(
        warm, startCenter: CGPoint(x: center.x - 34, y: center.y + 40), startRadius: 0,
        endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation]
    )
    context.restoreGState()
}
let discHalo = blurred(layer { context in
    context.setFillColor(color(0xFFB27A, 0.32))
    context.fillEllipse(in: CGRect(x: center.x - 136, y: center.y - 136, width: 272, height: 272))
}, radius: 24)

// Everything in order; halos add light, so they are drawn with "screen".
let icon = layer { context in
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    context.draw(tile, in: full)
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.setBlendMode(.screen)
    context.setAlpha(0.85)
    context.draw(edgeHalo, in: full)
    context.setAlpha(1)
    context.draw(edgeLine, in: full)
    context.setAlpha(0.9)
    context.draw(ringHalo, in: full)
    context.draw(discHalo, in: full)
    context.setAlpha(1)
    context.setBlendMode(.normal)
    context.draw(ringLine, in: full)
    context.draw(disc, in: full)
    // A faint highlight along the top, as glass catches light.
    let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gloss, start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.midY + 80), options: [])
    context.restoreGState()
}

// Every size macOS asks for, then iconutil.
func png(_ image: CGImage, size: Int) -> Data {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(icon, size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(icon, size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try png(icon, size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))
let icns = output.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed (\(iconutil.terminationStatus))")
    exit(1)
}
try? fileManager.removeItem(at: iconset)
print("wrote \(icns.path) and AppIcon.png")
