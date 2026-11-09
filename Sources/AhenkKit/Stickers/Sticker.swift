import CoreGraphics
import Foundation

/// Where a sticker sits.
public enum StickerPlacement: Hashable, Sendable {
    /// Free on the desktop of a display: its centre relative to the
    /// display's visible frame (it survives resolution changes).
    case desktop(display: String, center: NormalizedPoint)
    /// Stuck on a widget: its centre's offset from the widget's anchor
    /// point, in points. It moves with the widget and hides with it.
    case widget(DesktopWidget, dx: Double, dy: Double)

    public var widget: DesktopWidget? {
        if case .widget(let widget, _, _) = self { return widget }
        return nil
    }
}

extension StickerPlacement: Codable {
    private enum CodingKeys: String, CodingKey { case kind, display, x, y, widget, dx, dy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "widget":
            let widget = try c.decode(DesktopWidget.self, forKey: .widget)
            let dx = try c.decode(Double.self, forKey: .dx), dy = try c.decode(Double.self, forKey: .dy)
            guard dx.isFinite, dy.isFinite else { throw DecodingError.dataCorruptedError(forKey: .dx, in: c, debugDescription: "offset") }
            self = .widget(widget, dx: dx, dy: dy)
        default:
            let display = try c.decode(String.self, forKey: .display)
            self = .desktop(display: display, center: NormalizedPoint(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .desktop(let display, let center):
            try c.encode("desktop", forKey: .kind)
            try c.encode(display, forKey: .display)
            try c.encode(center.x, forKey: .x)
            try c.encode(center.y, forKey: .y)
        case .widget(let widget, let dx, let dy):
            try c.encode("widget", forKey: .kind)
            try c.encode(widget, forKey: .widget)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        }
    }
}

/// A cut-out photo on the desktop. The image itself is a PNG next to the
/// list (`StickerStore`); nothing leaves the Mac.
public struct Sticker: Hashable, Sendable, Identifiable {
    /// On-screen width in points (the height follows the picture).
    public static let widthRange: ClosedRange<Double> = 48...640

    public var id: UUID
    /// The photo's file name without its extension (Settings lists it).
    public var name: String
    /// The cut-out's size in pixels (its aspect ratio).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var placement: StickerPlacement
    public var width: Double
    /// Radians, counter-clockwise (AppKit's direction).
    public var rotation: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, pixelWidth: Int, pixelHeight: Int, placement: StickerPlacement,
        width: Double, rotation: Double = 0, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
        self.placement = placement
        self.width = Self.clampedWidth(width)
        self.rotation = StickerGeometry.normalizedRotation(rotation)
        self.createdAt = createdAt
    }

    /// Height over width of the picture.
    public var aspect: Double { Double(pixelHeight) / Double(pixelWidth) }

    /// The sticker's size on screen, in points.
    public var size: CGSize { CGSize(width: width, height: width * aspect) }

    /// The PNG's file name in the stickers folder.
    public var imageFileName: String { "\(id.uuidString).png" }

    public static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return 180 }
        return min(widthRange.upperBound, max(widthRange.lowerBound, width))
    }
}

extension Sticker: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, pixelWidth, pixelHeight, placement, width, rotation, createdAt }

    /// Lenient: a broken placement puts the sticker back on the main
    /// display's middle instead of losing it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let placement = (try? c.decode(StickerPlacement.self, forKey: .placement))
            ?? .desktop(display: StickerGeometry.mainDisplayKey, center: NormalizedPoint(x: 0.5, y: 0.5))
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: (try? c.decode(String.self, forKey: .name)) ?? "",
            pixelWidth: try c.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: try c.decode(Int.self, forKey: .pixelHeight),
            placement: placement,
            width: (try? c.decode(Double.self, forKey: .width)) ?? 180,
            rotation: (try? c.decode(Double.self, forKey: .rotation)) ?? 0,
            createdAt: (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try c.encode(placement, forKey: .placement)
        try c.encode(width, forKey: .width)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// A display as stickers see it: its stable ID, its whole frame and the
/// part not covered by the menu bar and the Dock (AppKit screen points,
/// origin at the bottom left).
public struct StickerDisplay: Equatable, Sendable {
    public var id: String
    public var frame: CGRect
    public var visible: CGRect

    public init(id: String, frame: CGRect, visible: CGRect) {
        self.id = id
        self.frame = frame
        self.visible = visible
    }
}

/// Where stickers go, how big their windows are and how they stay on
/// screen. Rectangles are in AppKit's global screen coordinates.
public enum StickerGeometry {
    /// Stands for "the main display" in a placement whose display is not
    /// known (a damaged file).
    public static let mainDisplayKey = "main"
    /// Room around the sticker in its window: the handles and the shadow.
    public static let windowMargin: Double = 22
    /// A sticker's centre stays at least this far inside its display's
    /// visible frame, so at least half of it can always be grabbed.
    public static let edgeInset: Double = 12
    /// Rotations this close to a quarter turn snap onto it.
    public static let snapAngle = 3.0 * .pi / 180
    /// New stickers are about this long on their longer side.
    public static let defaultLongSide: Double = 200

    /// Angle in `(-π, π]`.
    public static func normalizedRotation(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }

    /// `angle` snapped onto the nearest quarter turn when within `snapAngle`.
    public static func snappedRotation(_ angle: Double) -> Double {
        let normalized = normalizedRotation(angle)
        let quarter = Double.pi / 2
        let nearest = (normalized / quarter).rounded() * quarter
        return abs(normalized - nearest) <= snapAngle ? normalizedRotation(nearest) : normalized
    }

    /// The width that makes the longer side `defaultLongSide`, never more
    /// than a third of the screen's shorter side.
    public static func defaultWidth(pixelWidth: Int, pixelHeight: Int, screen: CGSize? = nil) -> Double {
        let aspect = Double(max(1, pixelHeight)) / Double(max(1, pixelWidth))
        var longSide = defaultLongSide
        if let screen, screen.width > 0, screen.height > 0 {
            longSide = min(longSide, min(screen.width, screen.height) / 3)
        }
        let width = aspect >= 1 ? longSide / aspect : longSide
        return Sticker.clampedWidth(width)
    }

    /// The width a resize asks for, within the allowed range and never
    /// wider than 90 % of the screen (or taller, for its aspect).
    public static func clampedWidth(_ width: Double, aspect: Double, screen: CGSize?) -> Double {
        var upper = Sticker.widthRange.upperBound
        if let screen, screen.width > 0, screen.height > 0 {
            upper = min(upper, screen.width * 0.9, screen.height * 0.9 / max(0.05, aspect))
        }
        guard width.isFinite else { return Sticker.clampedWidth(180) }
        return max(Sticker.widthRange.lowerBound, min(max(Sticker.widthRange.lowerBound, upper), width))
    }

    /// The square window that holds the sticker at any rotation, with room
    /// for the handles, centred on `center`.
    public static func windowFrame(center: CGPoint, size: CGSize) -> CGRect {
        let side = (hypot(size.width, size.height) + 2 * windowMargin).rounded(.up)
        return CGRect(x: (center.x - side / 2).rounded(), y: (center.y - side / 2).rounded(), width: side, height: side)
    }

    /// The point of a widget's frame that its position names (top left,
    /// bottom centre, centre): attached stickers keep their offset from it,
    /// so a player that grows upwards does not move them.
    public static func anchorPoint(of frame: CGRect, anchor: WidgetAnchor) -> CGPoint {
        switch anchor {
        case .topLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomCenter: CGPoint(x: frame.midX, y: frame.minY)
        case .center: CGPoint(x: frame.midX, y: frame.midY)
        }
    }

    /// `center` moved onto `visible` (inset by `edgeInset`).
    public static func clampCenter(_ center: CGPoint, into visible: CGRect) -> CGPoint {
        let inner = visible.insetBy(dx: min(edgeInset, visible.width / 2), dy: min(edgeInset, visible.height / 2))
        return CGPoint(x: min(max(center.x, inner.minX), inner.maxX), y: min(max(center.y, inner.minY), inner.maxY))
    }

    /// The display a point is on: the one containing it, else the nearest.
    public static func display(at point: CGPoint, in displays: [StickerDisplay]) -> StickerDisplay? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        return displays.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// Where a sticker's centre is on screen, kept on its display; `nil`
    /// when it is stuck on a widget that is not shown (it hides with it).
    /// A desktop sticker whose display is gone goes to the first display.
    public static func center(
        of placement: StickerPlacement, displays: [StickerDisplay], widgets: [DesktopWidget: CGRect]
    ) -> CGPoint? {
        switch placement {
        case .desktop(let id, let normalized):
            guard let display = displays.first(where: { $0.id == id }) ?? displays.first else { return nil }
            let point = WidgetPlacement.point(normalized, in: display.visible)
            return clampCenter(point, into: display.visible)
        case .widget(let widget, let dx, let dy):
            guard let frame = widgets[widget] else { return nil }
            let anchor = anchorPoint(of: frame, anchor: widget.anchor)
            let point = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
            guard let display = self.display(at: point, in: displays) else { return point }
            return clampCenter(point, into: display.visible)
        }
    }

    /// The placement after the sticker was dragged to `center`: a desktop
    /// sticker takes the display under it, a stuck one keeps its widget with
    /// a new offset.
    public static func placement(
        movedTo center: CGPoint, from placement: StickerPlacement, displays: [StickerDisplay], widgets: [DesktopWidget: CGRect]
    ) -> StickerPlacement {
        if case .widget(let widget, _, _) = placement, let frame = widgets[widget] {
            return attached(to: widget, frame: frame, center: center)
        }
        return onDesktop(center: center, displays: displays) ?? placement
    }

    /// Stuck on `widget` (whose window is at `frame`) where the sticker is now.
    public static func attached(to widget: DesktopWidget, frame: CGRect, center: CGPoint) -> StickerPlacement {
        let anchor = anchorPoint(of: frame, anchor: widget.anchor)
        return .widget(widget, dx: (center.x - anchor.x).rounded(), dy: (center.y - anchor.y).rounded())
    }

    /// Free on the desktop where the sticker is now.
    public static func onDesktop(center: CGPoint, displays: [StickerDisplay]) -> StickerPlacement? {
        guard let display = display(at: center, in: displays) else { return nil }
        let point = clampCenter(center, into: display.visible)
        let normalized = NormalizedPoint(
            x: display.visible.width > 0 ? (point.x - display.visible.minX) / display.visible.width : 0.5,
            y: display.visible.height > 0 ? (point.y - display.visible.minY) / display.visible.height : 0.5
        )
        return .desktop(display: display.id, center: normalized)
    }

    /// Where a new sticker goes: dropped on a widget, it sticks there at
    /// the drop point; else it is free at `point`, or the middle of the
    /// first display, moved down a little per sticker already there so new
    /// ones do not hide each other.
    public static func newPlacement(
        at point: CGPoint?, onto widget: DesktopWidget?, widgets: [DesktopWidget: CGRect], displays: [StickerDisplay], existing: Int
    ) -> StickerPlacement {
        if let widget, let frame = widgets[widget] {
            return attached(to: widget, frame: frame, center: point ?? CGPoint(x: frame.midX, y: frame.midY))
        }
        if let point, let placement = onDesktop(center: point, displays: displays) { return placement }
        guard let display = displays.first else {
            return .desktop(display: mainDisplayKey, center: NormalizedPoint(x: 0.5, y: 0.5))
        }
        let step = Double(existing % 6) * 0.04
        let center = WidgetPlacement.point(NormalizedPoint(x: 0.62 + step, y: 0.6 - step), in: display.visible)
        return onDesktop(center: center, displays: displays) ?? .desktop(display: display.id, center: NormalizedPoint(x: 0.5, y: 0.5))
    }
}
