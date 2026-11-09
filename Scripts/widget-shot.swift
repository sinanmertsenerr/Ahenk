// Captures Ahenk's own windows, composed by the window server, and nothing
// else: the desktop widgets (and, with --light, the edge light) over the
// `--demo-backdrop` wallpaper, so the glass can be checked and screenshots
// taken without anything of the user's desktop. Needs the Screen Recording
// permission for the app that runs it (the terminal).
//
//   open -n dist/Ahenk.app --args --demo-scene album --demo-backdrop
//   swift Scripts/widget-shot.swift /tmp/album.png            # cropped to the widgets
//   swift Scripts/widget-shot.swift /tmp/desk.png --full --light
//   pkill -x Ahenk
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: swift Scripts/widget-shot.swift <out.png> [--light] [--full]")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let withLight = arguments.contains("--light")
let full = arguments.contains("--full")
// The edge light's windows sit at the Dock's level minus one.
let lightLevel = Int(CGWindowLevelForKey(.dockWindow)) - 1

do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? content.displays.first else {
        print("no display")
        exit(1)
    }
    let mine = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.sinanmertsener.Ahenk" }
    let included = mine.filter { window in
        if window.frame.height <= 40 { return false } // the menu bar
        if window.windowLayer >= lightLevel { return withLight && window.windowLayer == lightLevel }
        return true
    }
    guard !included.isEmpty else {
        print("no Ahenk windows on screen")
        exit(1)
    }
    let filter = SCContentFilter(display: display, including: included)
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int(display.frame.width * scale)
    configuration.height = Int(display.frame.height * scale)
    configuration.showsCursor = false
    let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    var result: CGImage = image
    let widgets = included.filter { $0.windowLayer < lightLevel && $0.frame.width < display.frame.width - 1 }
    if !full, let first = widgets.first {
        let union = widgets.map(\.frame).reduce(first.frame) { $0.union($1) }.insetBy(dx: -30, dy: -30)
        let crop = CGRect(
            x: (union.minX - display.frame.minX) * scale, y: (union.minY - display.frame.minY) * scale,
            width: union.width * scale, height: union.height * scale
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        result = image.cropping(to: crop) ?? image
    }
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("cannot write \(output.path)")
        exit(1)
    }
    CGImageDestinationAddImage(destination, result, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(output.path) (\(result.width)×\(result.height))")
} catch {
    print("capture failed: \(error)")
    exit(1)
}
