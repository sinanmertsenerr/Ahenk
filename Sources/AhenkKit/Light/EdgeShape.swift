import CoreGraphics
import Foundation

/// The visible outline of one display: its size, how round each corner is
/// and the camera notch, in points with the origin at the bottom-left corner
/// and y pointing up (as AppKit lays out a screen).
///
/// The edge light follows this outline: its brightest line hugs the rounded
/// corners and wraps around the notch instead of running behind it.
public struct EdgeShape: Equatable, Sendable {
    public struct Corners: Equatable, Sendable {
        public var topLeft: Double
        public var topRight: Double
        public var bottomLeft: Double
        public var bottomRight: Double

        public init(topLeft: Double, topRight: Double, bottomLeft: Double, bottomRight: Double) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.bottomLeft = bottomLeft
            self.bottomRight = bottomRight
        }

        public static func all(_ radius: Double) -> Corners {
            Corners(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
        }

        public var maximum: Double { max(topLeft, topRight, bottomLeft, bottomRight) }
    }

    /// The camera housing at the top centre of recent MacBook displays.
    public struct Notch: Equatable, Sendable {
        public var minX: Double
        public var width: Double
        public var height: Double
        /// Radius of its two lower corners.
        public var radius: Double

        public init(minX: Double, width: Double, height: Double, radius: Double) {
            self.minX = minX
            self.width = width
            self.height = height
            self.radius = radius
        }

        public var midX: Double { minX + width / 2 }
    }

    public var width: Double
    public var height: Double
    public var corners: Corners
    public var notch: Notch?

    public init(width: Double, height: Double, corners: Corners = .all(EdgeShape.minimumCornerRadius), notch: Notch? = nil) {
        self.width = max(1, width)
        self.height = max(1, height)
        let limit = min(self.width, self.height) / 2
        func clamp(_ radius: Double) -> Double { min(limit, max(0, radius)) }
        self.corners = Corners(
            topLeft: clamp(corners.topLeft), topRight: clamp(corners.topRight),
            bottomLeft: clamp(corners.bottomLeft), bottomRight: clamp(corners.bottomRight)
        )
        if let notch, notch.width > 0, notch.height > 0 {
            let minX = min(max(0, notch.minX), self.width)
            let width = min(notch.width, self.width - minX)
            let height = min(notch.height, self.height / 3)
            self.notch = Notch(minX: minX, width: width, height: height, radius: min(max(0, notch.radius), height, width / 2))
        } else {
            self.notch = nil
        }
    }

    // MARK: Displays

    /// Every corner of the light is at least this round, so the band never
    /// ends in a hard square (displays without rounded corners included).
    public static let minimumCornerRadius = 6.0
    /// MacBook panels with a notch round their two top corners; the light
    /// follows that curve.
    public static let notchedPanelTopRadius = 10.0
    /// The notch's lower corners are round too, at about this share of its
    /// height.
    public static let notchCornerShare = 0.3
    /// Width of the smooth fillet where the notch meets the top edge (the
    /// shader uses the same constant).
    public static let notchFillet = 6.0

    /// The outline of a display of `width` × `height` points. `notch` is the
    /// camera housing in the same coordinates (y up; from the menu bar's
    /// auxiliary areas), `nil` when there is none. A notched display is a
    /// MacBook panel, whose top corners are round.
    public static func display(width: Double, height: Double, notch: CGRect?) -> EdgeShape {
        guard let notch, notch.width > 0, notch.height > 0 else {
            return EdgeShape(width: width, height: height)
        }
        let top = max(minimumCornerRadius, notchedPanelTopRadius)
        return EdgeShape(
            width: width, height: height,
            corners: Corners(topLeft: top, topRight: top, bottomLeft: minimumCornerRadius, bottomRight: minimumCornerRadius),
            notch: Notch(minX: notch.minX, width: notch.width, height: notch.height, radius: notch.height * notchCornerShare)
        )
    }

    /// The camera housing between the menu bar's two auxiliary areas, in
    /// the screen's own coordinates (y up), or `nil`. `frame` and the areas
    /// are in global coordinates, as `NSScreen` reports them.
    public static func notchRect(frame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?, safeAreaTop: Double) -> CGRect? {
        guard safeAreaTop > 0, let left = topLeftArea, let right = topRightArea else { return nil }
        let minX = left.maxX - frame.minX
        let maxX = right.minX - frame.minX
        guard maxX - minX > 1 else { return nil }
        return CGRect(x: minX, y: frame.height - safeAreaTop, width: maxX - minX, height: safeAreaTop)
    }
}
