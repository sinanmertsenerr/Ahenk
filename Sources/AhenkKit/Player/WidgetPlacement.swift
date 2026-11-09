import CoreGraphics
import Foundation

/// The desktop widgets, each its own window. Raw values are the keys of
/// the saved positions (`DesktopLayout`): never rename one.
public enum DesktopWidget: String, CaseIterable, Sendable, Codable {
    case clock
    case continuePlaying
    /// Cover flow, search and the player bar.
    case player
    /// Step 6: the synced lyrics beside the album cover.
    case lyrics

    /// The point of the widget its saved position names: the player keeps
    /// its bar in place when it grows or shrinks.
    public var anchor: WidgetAnchor {
        switch self {
        case .clock, .continuePlaying: .topLeft
        case .player: .bottomCenter
        case .lyrics: .center
        }
    }
}

public enum WidgetAnchor: Sendable {
    case topLeft
    case bottomCenter
    case center
}

/// Where widgets go on a screen. Rectangles are in AppKit's global screen
/// coordinates (origin at the bottom left); positions are saved relative to
/// the screen's visible frame (`NormalizedPoint`), so they survive
/// resolution changes, and every frame is kept inside the visible frame.
public enum WidgetPlacement {
    /// Widgets stay at least this far inside the visible frame.
    public static let edgeMargin: Double = 8

    /// The anchor point of a widget in screen coordinates.
    public static func point(_ normalized: NormalizedPoint, in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.minX + normalized.x * visible.width, y: visible.minY + normalized.y * visible.height)
    }

    /// The widget's frame for its saved (or default) anchor position, kept
    /// inside `visible`.
    public static func frame(size: CGSize, anchor: WidgetAnchor, at normalized: NormalizedPoint, in visible: CGRect) -> CGRect {
        let point = point(normalized, in: visible)
        let origin: CGPoint
        switch anchor {
        case .topLeft: origin = CGPoint(x: point.x, y: point.y - size.height)
        case .bottomCenter: origin = CGPoint(x: point.x - size.width / 2, y: point.y)
        case .center: origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        }
        return clamp(CGRect(origin: origin, size: size), into: visible)
    }

    /// The saved position of a widget at `frame`.
    public static func normalizedAnchor(of frame: CGRect, anchor: WidgetAnchor, in visible: CGRect) -> NormalizedPoint {
        let point: CGPoint
        switch anchor {
        case .topLeft: point = CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomCenter: point = CGPoint(x: frame.midX, y: frame.minY)
        case .center: point = CGPoint(x: frame.midX, y: frame.midY)
        }
        guard visible.width > 0, visible.height > 0 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        return NormalizedPoint(x: (point.x - visible.minX) / visible.width, y: (point.y - visible.minY) / visible.height)
    }

    /// `frame` moved (never resized) so it lies inside `visible` with the
    /// margin; a frame larger than the screen keeps its top-left corner in.
    public static func clamp(_ frame: CGRect, into visible: CGRect, margin: Double = edgeMargin) -> CGRect {
        let inner = visible.insetBy(dx: min(margin, visible.width / 2), dy: min(margin, visible.height / 2))
        var origin = frame.origin
        if frame.width <= inner.width {
            origin.x = min(max(origin.x, inner.minX), inner.maxX - frame.width)
        } else {
            origin.x = inner.minX
        }
        if frame.height <= inner.height {
            origin.y = min(max(origin.y, inner.minY), inner.maxY - frame.height)
        } else {
            origin.y = inner.maxY - frame.height
        }
        return CGRect(origin: origin, size: frame.size)
    }

    /// The default layout: the clock at the top left, Continue Playing
    /// under it, the player in the lower middle (moved right if it would
    /// cover the list), the lyrics (Step 6) right of the middle.
    public static func defaultFrames(sizes: [DesktopWidget: CGSize], in visible: CGRect) -> [DesktopWidget: CGRect] {
        let left = visible.minX + max(40, visible.width * 0.06)
        let top = visible.maxY - max(20, visible.height * 0.03)
        var frames: [DesktopWidget: CGRect] = [:]
        var nextTop = top
        if let clock = sizes[.clock] {
            let frame = clamp(CGRect(x: left, y: top - clock.height, width: clock.width, height: clock.height), into: visible)
            frames[.clock] = frame
            nextTop = frame.minY - 4
        }
        if let list = sizes[.continuePlaying] {
            let height = min(list.height, max(160, nextTop - visible.minY - 24))
            frames[.continuePlaying] = clamp(CGRect(x: left, y: nextTop - height, width: list.width, height: height), into: visible)
        }
        if let player = sizes[.player] {
            var frame = CGRect(x: visible.midX - player.width / 2, y: visible.minY + max(20, visible.height * 0.045), width: player.width, height: player.height)
            if let list = frames[.continuePlaying], frame.intersects(list) {
                frame.origin.x = max(frame.minX, list.maxX + 24)
            }
            frames[.player] = clamp(frame, into: visible)
        }
        if let lyrics = sizes[.lyrics] {
            let center = CGPoint(x: visible.minX + visible.width * 0.62, y: visible.minY + visible.height * 0.58)
            frames[.lyrics] = clamp(CGRect(x: center.x - lyrics.width / 2, y: center.y - lyrics.height / 2, width: lyrics.width, height: lyrics.height), into: visible)
        }
        return frames
    }
}
