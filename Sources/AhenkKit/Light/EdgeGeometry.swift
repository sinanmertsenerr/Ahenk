import CoreGraphics
import Foundation

/// The numbers the shader and the window layout share for one screen and
/// one look: how deep the light reaches, the perimeter coordinate, and how
/// far the top/bottom light wraps up the sides and the corner light reaches
/// along the edges.
///
/// All lengths are whole points so the strips that carry the light sit on
/// pixel boundaries.
public struct EdgeMetrics: Equatable, Sendable {
    public let shape: EdgeShape
    /// How deep the light may reach into the screen; nothing is drawn
    /// further in.
    public let band: Double
    /// Corner radius of the perimeter coordinate. At least `band`, so every
    /// point of the band maps to exactly one place along the edge (no seam
    /// on the corner diagonals).
    public let paramRadius: Double
    /// `.top`/`.bottom`: how far the light wraps around the corners and up
    /// (or down) the sides before it has faded.
    public let wrap: Double
    /// `.corners`: how far each corner's light reaches along both edges.
    public let arm: Double

    public init(shape: EdgeShape, band: Double) {
        let short = min(shape.width, shape.height)
        let band = min(max(1, band.rounded(.up)), (short * 0.45).rounded(.down))
        let radius = min(max(band, shape.corners.maximum.rounded(.up)), max(1, (short / 2 - 1).rounded(.down)))
        self.shape = shape
        self.band = max(1, band)
        self.paramRadius = max(self.band, radius)
        let straightWidth = max(0, shape.width - 2 * paramRadius)
        let straightHeight = max(0, shape.height - 2 * paramRadius)
        wrap = min(min(220, max(24, 0.2 * shape.height)), straightHeight * 0.45).rounded(.down)
        arm = min(min(200, max(40, 0.1 * (shape.width + shape.height))), min(straightWidth, straightHeight) * 0.45).rounded(.down)
    }

    /// Start of each part of the outline along the perimeter coordinate:
    /// counter-clockwise from the left end of the bottom edge (y up).
    public struct Segments: Equatable, Sendable {
        public let straightWidth: Double
        public let straightHeight: Double
        /// Length of one quarter arc.
        public let arc: Double
        public var bottom: Double { 0 }
        public var bottomRight: Double { straightWidth }
        public var right: Double { bottomRight + arc }
        public var topRight: Double { right + straightHeight }
        public var top: Double { topRight + arc }
        public var topLeft: Double { top + straightWidth }
        public var left: Double { topLeft + arc }
        public var bottomLeft: Double { left + straightHeight }
        public var total: Double { bottomLeft + arc }

        /// The middle of each corner arc: bottom-right, top-right, top-left,
        /// bottom-left.
        public var cornerMiddles: [Double] {
            [bottomRight + arc / 2, topRight + arc / 2, topLeft + arc / 2, bottomLeft + arc / 2]
        }
    }

    public var segments: Segments {
        Segments(
            straightWidth: max(0, shape.width - 2 * paramRadius),
            straightHeight: max(0, shape.height - 2 * paramRadius),
            arc: Double.pi / 2 * paramRadius
        )
    }

    /// Length of the perimeter coordinate, in points.
    public var perimeter: Double { segments.total }
}

/// A point near the edge, described along the edge: `s` is the perimeter
/// coordinate (points), `tangent` points towards growing `s` and `normal`
/// into the screen.
public struct EdgePoint: Equatable, Sendable {
    public var s: Double
    public var tangent: SIMD2<Double>
    public var normal: SIMD2<Double>
}

/// The edge light's geometry as plain math: the same formulas as
/// EdgeLight.metal (`edgeDistance`, `edgePoint`, `positionMask`,
/// `bandWindow`), so tests and the window layout can tell where the shader
/// may draw.
public struct EdgeField: Sendable {
    public let metrics: EdgeMetrics

    public init(metrics: EdgeMetrics) {
        self.metrics = metrics
    }

    // MARK: Distance

    /// Inward distance from the visible edge in points: 0 on it, growing
    /// into the screen, negative outside the rounded corners and inside the
    /// notch.
    public func distance(x: Double, y: Double) -> Double {
        let shape = metrics.shape
        let halfWidth = shape.width / 2
        let halfHeight = shape.height / 2
        let corners = shape.corners
        var d = -Self.roundBox(
            x - halfWidth, y - halfHeight, halfWidth, halfHeight,
            topRight: corners.topRight, bottomRight: corners.bottomRight,
            topLeft: corners.topLeft, bottomLeft: corners.bottomLeft
        )
        if let notch = shape.notch {
            let outside = Self.roundBox(
                x - notch.midX, y - shape.height, notch.width / 2, notch.height,
                topRight: 0, bottomRight: notch.radius, topLeft: 0, bottomLeft: notch.radius
            )
            d = Self.smoothMin(d, outside, EdgeShape.notchFillet)
        }
        return d
    }

    /// Signed distance to a box centred at the origin with half-size
    /// `(bx, by)` and one radius per corner (negative inside).
    static func roundBox(
        _ px: Double, _ py: Double, _ bx: Double, _ by: Double,
        topRight: Double, bottomRight: Double, topLeft: Double, bottomLeft: Double
    ) -> Double {
        let radius = px > 0 ? (py > 0 ? topRight : bottomRight) : (py > 0 ? topLeft : bottomLeft)
        let qx = abs(px) - bx + radius
        let qy = abs(py) - by + radius
        return min(max(qx, qy), 0) + (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() - radius
    }

    /// Polynomial smooth minimum: like `min`, rounded over a width of `k`.
    static func smoothMin(_ a: Double, _ b: Double, _ k: Double) -> Double {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    // MARK: Along the edge

    /// Where `(x, y)` lies along the edge. Corners use `paramRadius`
    /// around a centre inside the screen, so the coordinate is continuous
    /// across the whole band.
    public func point(x: Double, y: Double) -> EdgePoint {
        let width = metrics.shape.width
        let height = metrics.shape.height
        let r = metrics.paramRadius
        let seg = metrics.segments
        if x < r, y < r {
            let a = atan2(r - y, r - x)
            return EdgePoint(s: seg.bottomLeft + a * r, tangent: SIMD2(sin(a), -cos(a)), normal: SIMD2(cos(a), sin(a)))
        }
        if x > width - r, y < r {
            let a = atan2(r - y, x - (width - r))
            return EdgePoint(s: seg.bottomRight + (Double.pi / 2 - a) * r, tangent: SIMD2(sin(a), cos(a)), normal: SIMD2(-cos(a), sin(a)))
        }
        if x > width - r, y > height - r {
            let a = atan2(y - (height - r), x - (width - r))
            return EdgePoint(s: seg.topRight + a * r, tangent: SIMD2(-sin(a), cos(a)), normal: SIMD2(-cos(a), -sin(a)))
        }
        if x < r, y > height - r {
            let a = atan2(y - (height - r), r - x)
            return EdgePoint(s: seg.topLeft + (Double.pi / 2 - a) * r, tangent: SIMD2(-sin(a), -cos(a)), normal: SIMD2(cos(a), -sin(a)))
        }
        let nearest = min(x, width - x, y, height - y)
        if nearest == y {
            return EdgePoint(s: x - r, tangent: SIMD2(1, 0), normal: SIMD2(0, 1))
        } else if nearest == width - x {
            return EdgePoint(s: seg.right + (y - r), tangent: SIMD2(0, 1), normal: SIMD2(-1, 0))
        } else if nearest == height - y {
            return EdgePoint(s: seg.top + (width - r - x), tangent: SIMD2(-1, 0), normal: SIMD2(0, -1))
        } else {
            return EdgePoint(s: seg.left + (height - r - y), tangent: SIMD2(0, -1), normal: SIMD2(1, 0))
        }
    }

    /// `delta` folded into `-perimeter/2 ... perimeter/2`.
    public func wrapped(_ delta: Double) -> Double {
        let total = metrics.perimeter
        return delta - total * (delta / total).rounded()
    }

    // MARK: Masks

    /// `1` where the position setting lets the light shine at perimeter
    /// coordinate `s`, fading to `0` outside.
    public func positionMask(s: Double, position: LightPosition) -> Double {
        let seg = metrics.segments
        switch position {
        case .allEdges:
            return 1
        case .bottom, .top:
            let center = position == .bottom ? seg.straightWidth / 2 : seg.top + seg.straightWidth / 2
            let half = seg.straightWidth / 2 + seg.arc + metrics.wrap
            return spanMask(s: s, center: center, half: half, fade: metrics.wrap * 0.8 + 1)
        case .corners:
            let half = seg.arc / 2 + metrics.arm
            return seg.cornerMiddles.map { spanMask(s: s, center: $0, half: half, fade: metrics.arm * 0.6 + 1) }.max() ?? 0
        }
    }

    private func spanMask(s: Double, center: Double, half: Double, fade: Double) -> Double {
        1 - Self.smoothstep(half - fade, half, abs(wrapped(s - center)))
    }

    /// How much light may show at inward distance `d`: anti-aliased at the
    /// edge (`pixel` = one pixel in points) and exactly 0 from `band` on.
    public func window(distance d: Double, pixel: Double) -> Double {
        let band = metrics.band
        return Self.smoothstep(-pixel, 0.5 * pixel, d) * (1 - Self.smoothstep(band * 0.72, band, d))
    }

    /// True where the shader may produce any light.
    public func mayLight(x: Double, y: Double, position: LightPosition, pixel: Double = 0.5) -> Bool {
        let d = distance(x: x, y: y)
        guard window(distance: d, pixel: pixel) > 0 else { return false }
        return positionMask(s: point(x: x, y: y).s, position: position) > 0
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

/// One rectangle of the screen that carries part of the light (one Metal
/// layer each). Rectangles are in points, origin at the screen's bottom-left
/// corner, y up.
public struct EdgeStrip: Equatable, Sendable, Identifiable {
    public enum Place: String, Sendable, CaseIterable {
        case bottom, top, left, right
        case bottomLeft, bottomRight, topLeft, topRight
    }

    public var place: Place
    public var rect: CGRect

    public var id: Place { place }

    public init(place: Place, rect: CGRect) {
        self.place = place
        self.rect = rect
    }
}

/// Which parts of a screen the light can reach for a position setting.
/// Only these strips are drawn and composited, never the whole screen.
public enum EdgeLayout {
    public static func strips(for metrics: EdgeMetrics, position: LightPosition) -> [EdgeStrip] {
        let shape = metrics.shape
        let width = shape.width
        let height = shape.height
        let band = metrics.band
        let corners = shape.corners
        var bottomDepth = max(band, corners.bottomLeft.rounded(.up), corners.bottomRight.rounded(.up))
        var topDepth = max(band + (shape.notch?.height.rounded(.up) ?? 0), corners.topLeft.rounded(.up), corners.topRight.rounded(.up))
        if bottomDepth + topDepth > height {
            bottomDepth = (height * bottomDepth / (bottomDepth + topDepth)).rounded(.down)
            topDepth = height - bottomDepth
        }
        let sideWidth = min(band, (width / 2).rounded(.down))
        let reach = metrics.paramRadius + metrics.wrap

        var strips: [EdgeStrip] = []
        func add(_ place: EdgeStrip.Place, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            guard w >= 1, h >= 1 else { return }
            strips.append(EdgeStrip(place: place, rect: CGRect(x: x, y: y, width: w, height: h)))
        }

        switch position {
        case .allEdges:
            add(.bottom, 0, 0, width, bottomDepth)
            add(.top, 0, height - topDepth, width, topDepth)
            add(.left, 0, bottomDepth, sideWidth, height - topDepth - bottomDepth)
            add(.right, width - sideWidth, bottomDepth, sideWidth, height - topDepth - bottomDepth)
        case .bottom:
            let top = min(reach, height)
            add(.bottom, 0, 0, width, bottomDepth)
            add(.left, 0, bottomDepth, sideWidth, top - bottomDepth)
            add(.right, width - sideWidth, bottomDepth, sideWidth, top - bottomDepth)
        case .top:
            let bottom = max(0, height - reach)
            add(.top, 0, height - topDepth, width, topDepth)
            add(.left, 0, bottom, sideWidth, height - topDepth - bottom)
            add(.right, width - sideWidth, bottom, sideWidth, height - topDepth - bottom)
        case .corners:
            let across = min(metrics.paramRadius + metrics.arm, (width / 2).rounded(.down))
            let low = min(max(metrics.paramRadius + metrics.arm, bottomDepth), (height / 2).rounded(.down))
            let high = min(max(metrics.paramRadius + metrics.arm, topDepth), height - low)
            add(.bottomLeft, 0, 0, across, low)
            add(.bottomRight, width - across, 0, across, low)
            add(.topLeft, 0, height - high, across, high)
            add(.topRight, width - across, height - high, across, high)
        }
        return strips
    }

    /// Area of `strips` in square points (what the GPU fills per frame at
    /// one pixel per point).
    public static func area(of strips: [EdgeStrip]) -> Double {
        strips.reduce(0) { $0 + $1.rect.width * $1.rect.height }
    }
}
