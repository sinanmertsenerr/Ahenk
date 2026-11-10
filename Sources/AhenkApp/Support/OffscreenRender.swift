import AhenkKit
import AppKit
import SwiftUI

/// Draws a SwiftUI view into a bitmap without showing it: the view lives in
/// a borderless, almost transparent window far outside every screen for a
/// few run-loop turns (so AppKit really lays it out and draws it), then its
/// layer tree is copied. For `--smoke` snapshots and the README pictures;
/// glass and blur from the window server are not part of the copy.
@MainActor
enum OffscreenRender {
    /// `background`: what a real window would paint under the view (its
    /// window background by default; `nil` keeps it transparent).
    static func bitmap<V: View>(
        of view: V, size: CGSize, background: Color? = Color(nsColor: .windowBackgroundColor), passes: Int = 4
    ) async throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(background ?? .clear))
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentView = hosting
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.orderFrontRegardless()
        for _ in 0..<passes {
            try await Task.sleep(for: .milliseconds(70))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SmokeFailure("Could not allocate a \(Int(size.width))×\(Int(size.height)) bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// Pixels on a coarse grid that differ from the most common colour:
    /// a cheap "something was drawn" test.
    static func drawnShare(_ bitmap: NSBitmapImageRep, step: Int = 6) -> Double {
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(color.redComponent * 31) << 10 | UInt32(color.greenComponent * 31) << 5 | UInt32(color.blueComponent * 31)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let background = counts.values.max() else { return 0 }
        return Double(total - background) / Double(total)
    }
}
