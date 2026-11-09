import AhenkKit
import AppKit

/// Smoke check `dockArt`: the Dock tile drawn offscreen from a generated
/// cover (still, between beats, on a beat), its pixels checked, the ring's
/// motion run through four seconds of the demo beat at 10 fps to count the
/// tiles that would reach the Dock, and the tile's own view drawn into a
/// bitmap through every size of the swell (each look once as a picture,
/// then copied). Nothing is shown.
@MainActor
enum DockArtCheck {
    static let pixelSide = 256

    static func run(palette: Palette, snapshots: URL?) throws -> String {
        guard let cover = DemoArtwork.makeImage(palette: palette, seed: 11, pixelSize: 512) else { throw SmokeFailure("could not draw a cover") }
        let parts = DockTileParts(artwork: cover, colors: DockTileRenderer.ringColors(palette), pixelSide: pixelSide)
        guard parts.cover != nil, parts.ring != nil else { throw SmokeFailure("could not prepare the tile's cover and ring") }
        let still = DockArtFrame.still(progress: 0.35)
        let calm = DockArtFrame(pulse: 0.05, level: 0.7, progress: 0.35, isPlaying: true)
        let beat = DockArtFrame(pulse: 1, level: 0.9, progress: 0.35, isPlaying: true)
        var images: [(String, NSBitmapImageRep)] = []
        for (name, frame) in [("still", still), ("calm", calm), ("beat", beat)] {
            images.append((name, try render(parts, frame: frame)))
        }
        let (stillImage, calmImage, beatImage) = (images[0].1, images[1].1, images[2].1)

        // The cover in the middle, nothing in the corners.
        let middle = try pixel(beatImage, x: pixelSide / 2, y: pixelSide / 2)
        guard middle.alphaComponent > 0.99 else { throw SmokeFailure("the cover is missing from the tile's middle") }
        for corner in [(1, 1), (pixelSide - 2, 1), (1, pixelSide - 2), (pixelSide - 2, pixelSide - 2)] {
            guard try pixel(beatImage, x: corner.0, y: corner.1).alphaComponent < 0.05 else {
                throw SmokeFailure("the tile is not clear in its corners")
            }
        }
        // The ring: lit on the beat, more than between beats, more than paused.
        let lit = [stillImage, calmImage, beatImage].map { ringCoverage($0) }
        guard Double(lit[2]) > Double(lit[1]) * 1.15, lit[1] > lit[0], lit[0] > 0 else {
            throw SmokeFailure("the ring does not swell with the beat (paused \(lit[0]), calm \(lit[1]), beat \(lit[2]))")
        }

        // Four seconds of the demo beat at 10 fps: how many tiles are sent.
        var motion = DockRingMotion()
        var shown: DockArtFrame?
        var sent = 0
        let frames = 4 * DockArtPolicy.normalFramesPerSecond
        for index in 0..<frames {
            let time = 10 + Double(index) / Double(DockArtPolicy.normalFramesPerSecond)
            let frame = motion.frame(features: DemoBeat.features(at: time), at: time, progress: time / 200, isPlaying: true)
            if DockRingMotion.differs(frame, from: shown) {
                shown = frame
                sent += 1
            }
        }
        guard sent > 4, sent <= frames else { throw SmokeFailure("\(sent) tiles in 4 s of the demo beat") }

        // The view as the Dock draws it: each look becomes a picture once,
        // later frames copy it. Drawn into a bitmap here, as the Dock would.
        let view = DockTileView(frame: NSRect(x: 0, y: 0, width: pixelSide / 2, height: pixelSide / 2))
        view.setArtwork(cover, colors: DockTileRenderer.ringColors(palette))
        guard let cache = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SmokeFailure("no bitmap for the tile view") }
        let clock = ContinuousClock()
        var firstPass = Duration.zero, laterPass = Duration.zero
        let steps = (0...DockTileLook.pulseSteps).map { Double($0) / Double(DockTileLook.pulseSteps) }
        for pass in 0..<3 {
            let elapsed = clock.measure {
                for pulse in steps {
                    view.state = DockArtFrame(pulse: pulse, level: 0.8, progress: 0.4, isPlaying: true)
                    view.cacheDisplay(in: view.bounds, to: cache)
                }
            }
            if pass == 0 { firstPass = elapsed } else { laterPass += elapsed }
        }
        guard view.pictureCount == steps.count else { throw SmokeFailure("\(view.pictureCount) pictures for \(steps.count) looks") }
        func milliseconds(_ duration: Duration, tiles: Int) -> Double {
            (Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) / Double(tiles)
        }
        let fresh = milliseconds(firstPass, tiles: steps.count), copied = milliseconds(laterPass, tiles: 2 * steps.count)
        guard copied < 3 else { throw SmokeFailure("a prepared tile takes \(String(format: "%.1f", copied)) ms") }
        // One frame on a clear bitmap (the passes above drew over each other).
        guard let last = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SmokeFailure("no bitmap for the tile view") }
        view.state = beat
        view.cacheDisplay(in: view.bounds, to: last)
        let viewMiddle = last.colorAt(x: last.pixelsWide / 2, y: last.pixelsHigh / 2)?.alphaComponent ?? 0
        let viewCorner = last.colorAt(x: 1, y: 1)?.alphaComponent ?? 1
        guard viewMiddle > 0.99, viewCorner < 0.05 else { throw SmokeFailure("the tile view did not draw the cover in a clear tile") }

        if let snapshots {
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            for (name, image) in images {
                try image.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("dock-\(name).png"))
            }
            // The tile's own view on a beat.
            try last.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("dock-view.png"))
        }
        let saved = snapshots.map { ", snapshots in \($0.path)" } ?? ""
        return "tile drawn offscreen (\(pixelSide) px): cover in the middle, clear corners, ring lit \(lit[0]) → \(lit[1]) → \(lit[2]) px "
            + "(paused, calm, beat); \(sent) of \(frames) frames sent in 4 s of the demo beat at \(DockArtPolicy.normalFramesPerSecond) fps; "
            + "the tile view keeps \(view.pictureCount) looks as pictures (\(String(format: "%.2f", fresh)) ms a tile the first time, "
            + "\(String(format: "%.2f", copied)) ms afterwards)\(saved)"
    }

    /// The tile at 2× (`pixelSide` pixels for the Dock's 128 pt tile).
    static func render(_ parts: DockTileParts, frame: DockArtFrame) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSide, pixelsHigh: pixelSide, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SmokeFailure("no bitmap for the tile") }
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide))
        context.cgContext.scaleBy(x: 2, y: 2)
        DockTileRenderer.draw(in: context.cgContext, size: CGSize(width: pixelSide / 2, height: pixelSide / 2), parts: parts, frame: frame)
        context.flushGraphics()
        return bitmap
    }

    private static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        guard let color = bitmap.colorAt(x: x, y: y) else { throw SmokeFailure("no pixel at \(x), \(y)") }
        return color
    }

    /// Visible pixels between the cover and the tile's edge.
    private static func ringCoverage(_ bitmap: NSBitmapImageRep) -> Int {
        let center = Double(pixelSide) / 2
        let inner = 0.36 * Double(pixelSide)
        var count = 0
        for y in stride(from: 0, to: pixelSide, by: 2) {
            for x in stride(from: 0, to: pixelSide, by: 2) {
                let distance = hypot(Double(x) - center, Double(y) - center)
                guard distance > inner, distance < center else { continue }
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 { count += 1 }
            }
        }
        return count
    }
}
