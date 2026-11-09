import AhenkKit
import AppKit

/// Demo helpers for screenshots and visual checks (`--demo` only):
/// `--demo-backdrop` puts a generated wallpaper behind the widgets, so they
/// can be captured on their glass without anything of the user's desktop;
/// `--demo-scene` opens the player in one state.
@MainActor
enum DemoStage {
    /// A borderless window just under the widgets that covers the screen
    /// with a generated dusk gradient. Clicks pass through it.
    static func makeBackdrop(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: DesktopWidgetWindow.level.rawValue - 1)
        let view = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.imageScaling = .scaleAxesIndependently
        view.image = backdropImage(size: screen.frame.size, scale: screen.backingScaleFactor)
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        return window
    }

    private static func backdropImage(size: CGSize, scale: CGFloat) -> NSImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let sky = [
            CGColor(srgbRed: 0.07, green: 0.09, blue: 0.20, alpha: 1),
            CGColor(srgbRed: 0.27, green: 0.17, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.78, green: 0.42, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.98, green: 0.72, blue: 0.48, alpha: 1),
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 0.45, 0.8, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }
        let fields: [(CGPoint, CGFloat, CGColor)] = [
            (CGPoint(x: 0.18, y: 0.72), 0.42, CGColor(srgbRed: 0.18, green: 0.45, blue: 0.62, alpha: 0.55)),
            (CGPoint(x: 0.78, y: 0.30), 0.38, CGColor(srgbRed: 0.95, green: 0.45, blue: 0.40, alpha: 0.45)),
            (CGPoint(x: 0.55, y: 0.85), 0.30, CGColor(srgbRed: 0.55, green: 0.35, blue: 0.75, alpha: 0.40)),
        ]
        for (center, radius, color) in fields {
            guard let clear = color.copy(alpha: 0),
                  let gradient = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, 1])
            else { continue }
            let point = CGPoint(x: center.x * w, y: center.y * h)
            context.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius * w, options: [])
        }
        // A dark band of "hills" along the bottom.
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.06, blue: 0.12, alpha: 0.85))
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 0, y: h * 0.16))
        context.addCurve(to: CGPoint(x: w * 0.45, y: h * 0.13), control1: CGPoint(x: w * 0.15, y: h * 0.24), control2: CGPoint(x: w * 0.3, y: h * 0.08))
        context.addCurve(to: CGPoint(x: w, y: h * 0.2), control1: CGPoint(x: w * 0.62, y: h * 0.19), control2: CGPoint(x: w * 0.82, y: h * 0.27))
        context.addLine(to: CGPoint(x: w, y: 0))
        context.closePath()
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

extension DesktopPlayerController {
    /// Opens the player in a named state (`--demo-scene`); never takes the
    /// keyboard.
    func applyDemoScene(_ name: String) {
        let model = self.model
        Task { @MainActor in
            // Let the albums of the playing song arrive first.
            for _ in 0..<60 where model.albums.value == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            switch name {
            case "search":
                model.query = "nova"
            case "album":
                if let album = model.playingAlbum ?? model.albums.value?.first { model.open(.album(album)) }
            case "artist":
                model.openPlayingArtist()
            case "queue":
                if let album = model.playingAlbum, let songs = await model.loadAlbumSongs(album) {
                    model.play(songs, at: 1, context: .album(id: album.id, title: album.title))
                    model.addToQueue(Array(model.recent.prefix(2)))
                }
                model.isQueueOpen = true
            case "small":
                model.setSize(.small)
            case "small-search":
                model.setSize(.small)
                model.isSearchOpen = true
                model.query = "harbor"
            case "off":
                model.settings.player.enabled = false
            case "lyrics-versions":
                self.lyrics.panel = .versions
            case "lyrics-search":
                self.lyrics.panel = .search
                self.lyrics.search()
            case "status":
                model.show(PlayerStatus(text: "Playing in the browser needs the Ahenk browser extension.".l10n, kind: .problem))
            case "loading":
                // The demo takes its time to start this one, so the loading
                // state stays on screen.
                model.router.demoStartDelay = 10
                if let album = model.playingAlbum, let songs = await model.loadAlbumSongs(album) {
                    model.play(songs, at: 2, context: .album(id: album.id, title: album.title))
                }
            default:
                break
            }
        }
    }
}
