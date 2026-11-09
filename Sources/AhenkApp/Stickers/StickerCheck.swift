import AhenkKit
import AppKit

/// Smoke check `stickers`: a generated photo (an invented mug on a studio
/// backdrop) is cut out by Vision on this Mac, the backdrop and the hole in
/// the handle come out clear, the white border goes round the outline, a
/// sticker window sits at the widgets' level and never activates Ahenk, the
/// sticker is drawn offscreen turned, and the store keeps and drops it.
/// Nothing is shown and no real photo is read.
@MainActor
enum StickerCheck {
    static func run(snapshots: URL?) async throws -> String {
        guard let photo = DemoStickerArt.makeImage(.mug) else { throw SmokeFailure("could not draw the photo") }
        let input = SendableCGImage(photo)
        let started = ContinuousClock.now
        let job = Task.detached(priority: .userInitiated) { try StickerCutter.cut(input.image) }
        let cutout = try await job.value
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        guard cutout.foundSubject else { throw SmokeFailure("Vision found no subject in the generated photo") }
        let picture = NSBitmapImageRep(cgImage: cutout.image)
        let w = picture.pixelsWide, h = picture.pixelsHigh
        guard w > 200, h > 200, w < 600, h < 600 else { throw SmokeFailure("the cut-out is \(w)×\(h) px") }
        func alpha(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) -> CGFloat {
            rep.colorAt(x: min(rep.pixelsWide - 1, Int(x * Double(rep.pixelsWide))), y: min(rep.pixelsHigh - 1, Int(y * Double(rep.pixelsHigh))))?.alphaComponent ?? -1
        }
        guard alpha(picture, 0.25, 0.6) > 0.95 else { throw SmokeFailure("the mug's body is not opaque") }
        guard alpha(picture, 0.995, 0.005) < 0.05, alpha(picture, 0.005, 0.995) < 0.05 else {
            throw SmokeFailure("the backdrop was not cut away")
        }
        guard alpha(picture, 0.84, 0.5) < 0.1 else { throw SmokeFailure("the hole in the handle is not clear") }

        // The border: a white band round the outline.
        let bordered = StickerCutter.bordered(cutout.image, border: true)
        let scale = StickerCutter.borderScale(for: cutout.image)
        guard bordered.width > cutout.image.width, abs(Double(bordered.width) / Double(cutout.image.width) - scale) < 0.02 else {
            throw SmokeFailure("the border did not grow the picture as expected")
        }
        let borderRep = NSBitmapImageRep(cgImage: bordered)
        let pad = (Double(bordered.width) - Double(cutout.image.width)) / 2
        let edge = borderRep.colorAt(x: Int(pad * 0.75), y: borderRep.pixelsHigh / 2)
        guard let edge, edge.alphaComponent > 0.9, edge.brightnessComponent > 0.9, edge.saturationComponent < 0.1 else {
            throw SmokeFailure("no white border outside the outline")
        }

        // The window: the widgets' level, every Space, never active.
        let sticker = Sticker(name: "Mug", pixelWidth: w, pixelHeight: h, placement: .widget(.player, dx: 120, dy: 80), width: 200, rotation: 0.35)
        let shownSize = CGSize(width: sticker.size.width * scale, height: sticker.size.height * scale)
        let frame = StickerGeometry.windowFrame(center: CGPoint(x: -30_000, y: -30_000), size: shownSize)
        let window = StickerWindow(stickerID: sticker.id, frame: frame)
        defer { window.close() }
        guard window.level == DesktopWidgetWindow.level, window.collectionBehavior.contains(.canJoinAllSpaces),
              window.collectionBehavior.contains(.stationary), window.styleMask.contains(.nonactivatingPanel),
              !window.canBecomeKey, !window.canBecomeMain
        else { throw SmokeFailure("the sticker window could activate Ahenk or leave the widgets' level") }
        let view = StickerView(width: sticker.width, aspect: sticker.aspect, rotation: sticker.rotation)
        view.frame = CGRect(origin: .zero, size: frame.size)
        window.contentView = view
        view.setPicture(bordered, scale: scale)
        guard let drawn = view.snapshot() else { throw SmokeFailure("the sticker could not be drawn") }
        guard alpha(drawn, 0.5, 0.5) > 0.9, alpha(drawn, 0.02, 0.02) < 0.05 else {
            throw SmokeFailure("the turned sticker is not where it should be in its window")
        }

        // Kept and dropped, in memory.
        let store = StickerStore(directory: nil)
        try store.add(sticker, png: cutout.png)
        guard store.imageData(for: sticker.id) == cutout.png, store.stickers.count == 1 else { throw SmokeFailure("the store lost the sticker") }
        store.remove(id: sticker.id)
        guard store.stickers.isEmpty else { throw SmokeFailure("the sticker was not removed") }

        if let snapshots {
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try cutout.png.write(to: snapshots.appendingPathComponent("sticker-cutout.png"))
            try drawn.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("sticker-turned.png"))
        }
        let saved = snapshots.map { ", snapshots in \($0.path)" } ?? ""
        return "Vision cut the subject out of a generated \(photo.width)×\(photo.height) photo in \(milliseconds) ms (\(w)×\(h) px, backdrop and handle hole clear); "
            + "white border round the outline; window at the widgets' level, never active; drawn turned offscreen; kept and removed\(saved)"
    }
}
