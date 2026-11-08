import AppKit

/// The menu bar glyph: a screen outline with a small equalizer inside,
/// drawn in code as a template image so it follows the menu bar appearance.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.5
            screen.stroke()
            // Three bars of different heights, sitting on the bottom edge.
            let bars: [(x: CGFloat, height: CGFloat)] = [(5.25, 4), (8.25, 6.5), (11.25, 3)]
            for bar in bars {
                NSBezierPath(roundedRect: NSRect(x: bar.x, y: 5.5, width: 1.75, height: bar.height), xRadius: 0.875, yRadius: 0.875).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ahenk"
        return image
    }()

    /// The glyph with a dot in the top-right corner: Ahenk has a question
    /// (several sources are playing).
    static let attention: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            MenuBarIcon.image.draw(in: rect)
            // Cut a gap around the dot so it reads apart from the outline.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 11, y: 10.5, width: 8.5, height: 8.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12, width: 5.5, height: 5.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ahenk"
        return image
    }()

    /// `image` drawn at `size` with rounded corners, for menu rows.
    static func rounded(_ image: NSImage, size: CGFloat = 18, radius: CGFloat = 4) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            image.draw(in: rect)
            return true
        }
    }
}
