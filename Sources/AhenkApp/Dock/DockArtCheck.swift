import AhenkKit
import AppKit

/// Smoke check `dockArt`: the Dock tile drawn offscreen from a generated
/// cover (still, between beats, on a beat), its pixels checked, and the
/// ring's motion run through four seconds of the demo beat at 10 fps to
/// count the tiles that would reach the Dock. Nothing is shown.
@MainActor
enum DockArtCheck {
    static let pixelSide = 256

    static func run(palette: Palette, snapshots: URL?) throws -> String {
        guard let cover = DemoArtwork.makeImage(palette: palette, seed: 11, pixelSize: 512),
              let round = DockTileRenderer.roundCover(cover, pixelSide: pixelSide)
        else { throw SmokeFailure("could not draw a cover") }
        let colors = DockTileRenderer.ringColors(palette)
        let still = DockArtFrame.still(progress: 0.35)
        let calm = DockArtFrame(pulse: 0.05, level: 0.7, progress: 0.35, turn: 0.1, isPlaying: true)
        let beat = DockArtFrame(pulse: 1, level: 0.9, progress: 0.35, turn: 0.15, isPlaying: true)
        var images: [(String, NSBitmapImageRep)] = []
        for (name, frame) in [("still", still), ("calm", calm), ("beat", beat)] {
            images.append((name, try render(cover: round, colors: colors, frame: frame)))
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

        if let snapshots {
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            for (name, image) in images {
                try image.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("dock-\(name).png"))
            }
        }
        let saved = snapshots.map { ", snapshots in \($0.path)" } ?? ""
        return "tile drawn offscreen (\(pixelSide) px): cover in the middle, clear corners, ring lit \(lit[0]) → \(lit[1]) → \(lit[2]) px "
            + "(paused, calm, beat); \(sent) of \(frames) frames sent in 4 s of the demo beat at \(DockArtPolicy.normalFramesPerSecond) fps\(saved)"
    }

    /// The tile at 2× (`pixelSide` pixels for the Dock's 128 pt tile).
    static func render(cover: CGImage?, colors: [CGColor], frame: DockArtFrame) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSide, pixelsHigh: pixelSide, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SmokeFailure("no bitmap for the tile") }
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide))
        context.cgContext.scaleBy(x: 2, y: 2)
        DockTileRenderer.draw(in: context.cgContext, size: CGSize(width: pixelSide / 2, height: pixelSide / 2), cover: cover, colors: colors, frame: frame)
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
