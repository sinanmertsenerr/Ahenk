import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Edge light geometry")
struct EdgeGeometryTests {
    /// This Mac's built-in display: 1512 × 982 points, a 185 × 32 notch.
    static let macBook = EdgeShape.display(width: 1512, height: 982, notch: CGRect(x: 665, y: 950, width: 185, height: 32))
    static let external = EdgeShape.display(width: 2560, height: 1440, notch: nil)

    @Test("A notched display gets round top corners and the notch; others only the minimum radius")
    func displayShapes() {
        let mac = Self.macBook
        #expect(mac.corners.topLeft == EdgeShape.notchedPanelTopRadius)
        #expect(mac.corners.topRight == EdgeShape.notchedPanelTopRadius)
        #expect(mac.corners.bottomLeft == EdgeShape.minimumCornerRadius)
        let notch = try? #require(mac.notch)
        #expect(notch?.minX == 665 && notch?.width == 185 && notch?.height == 32)
        #expect(notch.map { abs($0.radius - 32 * EdgeShape.notchCornerShare) < 1e-9 } == true)
        #expect(Self.external.notch == nil)
        #expect(Self.external.corners == .all(EdgeShape.minimumCornerRadius))
    }

    @Test("The notch comes from the menu bar's auxiliary areas, in screen coordinates")
    func notchFromScreenAreas() throws {
        // A second display to the right of the main one: global x starts at 1512.
        let frame = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let rect = try #require(EdgeShape.notchRect(
            frame: frame,
            topLeftArea: CGRect(x: 1512, y: 950, width: 665, height: 32),
            topRightArea: CGRect(x: 1512 + 850, y: 950, width: 662, height: 32),
            safeAreaTop: 32
        ))
        #expect(rect == CGRect(x: 665, y: 950, width: 185, height: 32))
        #expect(EdgeShape.notchRect(frame: frame, topLeftArea: nil, topRightArea: nil, safeAreaTop: 0) == nil)
        #expect(EdgeShape.notchRect(frame: frame, topLeftArea: CGRect(x: 0, y: 0, width: 10, height: 10), topRightArea: nil, safeAreaTop: 32) == nil)
    }

    @Test("Shapes clamp radii and notches to the screen")
    func clamping() {
        let tiny = EdgeShape(width: 40, height: 20, corners: .all(100), notch: .init(minX: -5, width: 100, height: 50, radius: 90))
        #expect(tiny.corners.maximum == 10)
        let notch = tiny.notch
        #expect(notch?.minX == 0)
        #expect((notch?.width ?? 0) <= 40)
        #expect((notch?.height ?? 0) <= 20.0 / 3)
        #expect((notch?.radius ?? 0) <= (notch?.height ?? 0))
    }

    @Test("Metrics: whole points, the coordinate radius covers the band, wrap and arm stay apart")
    func metrics() {
        let look = LightLook(style: .fireworks, thickness: 40, glow: 1)
        let metrics = EdgeMetrics(shape: Self.macBook, band: look.band)
        #expect(metrics.band == metrics.band.rounded())
        #expect(metrics.band <= 982 * 0.45)
        #expect(metrics.paramRadius >= metrics.band)
        #expect(metrics.paramRadius >= Self.macBook.corners.maximum)
        let seg = metrics.segments
        #expect(abs(metrics.perimeter - (2 * (1512 - 2 * metrics.paramRadius) + 2 * (982 - 2 * metrics.paramRadius) + 2 * .pi * metrics.paramRadius)) < 1e-6)
        // The top and bottom light never meet on a side; corner arms never meet.
        #expect(2 * (metrics.paramRadius + metrics.wrap) < 982)
        #expect(2 * (metrics.paramRadius + metrics.arm) < 982)
        #expect(seg.cornerMiddles.count == 4)
        // An absurd band is clamped.
        #expect(EdgeMetrics(shape: Self.macBook, band: 10_000).band == (982 * 0.45).rounded(.down))
    }

    @Test("Distance: zero on the edge, inwards positive, around the notch, outside the rounded corner negative")
    func distance() {
        let field = EdgeField(metrics: EdgeMetrics(shape: Self.macBook, band: 60))
        #expect(abs(field.distance(x: 756, y: 0)) < 1e-9)
        #expect(abs(field.distance(x: 756, y: 30) - 30) < 1e-9)
        #expect(abs(field.distance(x: 0, y: 491)) < 1e-9)
        #expect(abs(field.distance(x: 300, y: 982 - 12) - 12) < 1e-9)
        // Just below the notch the light hugs the notch, not the top edge.
        #expect(abs(field.distance(x: 757, y: 982 - 32 - 5) - 5) < 1e-6)
        // Inside the notch and outside the rounded top corner: no light.
        #expect(field.distance(x: 757, y: 975) < 0)
        #expect(field.distance(x: 0.5, y: 981.5) < 0)
        // The notch's fillet rounds the junction: slightly less than the plain minimum.
        let junction = field.distance(x: 665 - 2, y: 982 - 2)
        #expect(junction < 2 && junction > 0)
    }

    @Test("The perimeter coordinate runs counter-clockwise without a jump across the band")
    func perimeterCoordinate() {
        let metrics = EdgeMetrics(shape: Self.external, band: 80)
        let field = EdgeField(metrics: metrics)
        let r = metrics.paramRadius
        let seg = metrics.segments
        #expect(abs(field.point(x: r, y: 3).s) < 1e-9)
        #expect(abs(field.point(x: 2560 - 3, y: r).s - seg.right) < 1e-9)
        #expect(abs(field.point(x: 2560 - r, y: 1440 - 3).s - seg.top) < 1e-9)
        #expect(abs(field.point(x: 3, y: 1440 - r).s - seg.left) < 1e-9)
        // Walk once around the screen 20 points in: s grows smoothly and wraps once.
        var previous = field.point(x: r + 1, y: 20).s
        var wraps = 0
        var path: [(Double, Double)] = []
        for x in stride(from: r + 1, through: 2540.0, by: 2) { path.append((x, 20)) }
        for y in stride(from: 20.0, through: 1420, by: 2) { path.append((2540, y)) }
        for x in stride(from: 2540.0, through: 20, by: -2) { path.append((x, 1420)) }
        for y in stride(from: 1420.0, through: 20, by: -2) { path.append((20, y)) }
        for x in stride(from: 20.0, through: r + 1, by: 2) { path.append((x, 20)) }
        for (x, y) in path {
            let s = field.point(x: x, y: y).s
            var step = s - previous
            if step < -metrics.perimeter / 2 { step += metrics.perimeter; wraps += 1 }
            #expect(step >= -1e-9 && step < 6, "jump at \(x), \(y): \(step)")
            previous = s
        }
        #expect(wraps <= 1)
        // Normals point into the screen, tangents along growing s.
        let bottom = field.point(x: 900, y: 10)
        #expect(bottom.normal == SIMD2(0, 1) && bottom.tangent == SIMD2(1, 0))
        let corner = field.point(x: 10, y: 10)
        #expect(abs(corner.normal.x - corner.normal.y) < 1e-9 && corner.normal.x > 0)
    }

    @Test("Position masks: bottom wraps up the sides, top around, corners only near corners")
    func positionMasks() {
        let metrics = EdgeMetrics(shape: Self.external, band: 60)
        let field = EdgeField(metrics: metrics)
        func lit(_ x: Double, _ y: Double, _ position: LightPosition) -> Bool {
            field.mayLight(x: x, y: y, position: position)
        }
        #expect(lit(1280, 5, .bottom) && !lit(1280, 1435, .bottom))
        #expect(lit(5, metrics.paramRadius + metrics.wrap * 0.1, .bottom))
        #expect(!lit(5, 720, .bottom))
        #expect(lit(1280, 1435, .top) && !lit(1280, 5, .top))
        #expect(lit(5, 5, .corners) && lit(2555, 1435, .corners))
        #expect(!lit(1280, 5, .corners) && !lit(5, 720, .corners))
        #expect(lit(1280, 5, .allEdges) && lit(5, 720, .allEdges) && !lit(1280, 720, .allEdges))
    }

    @Test("Strips cover every lit point, never overlap and stay off the middle", arguments: LightPosition.allCases)
    func stripsCoverTheLight(position: LightPosition) {
        for (shape, band) in [(Self.macBook, 64.0), (Self.external, 120.0), (Self.macBook, 7.0), (EdgeShape(width: 120, height: 76), 30.0)] {
            let metrics = EdgeMetrics(shape: shape, band: band)
            let field = EdgeField(metrics: metrics)
            let strips = EdgeLayout.strips(for: metrics, position: position)
            #expect(!strips.isEmpty)
            for (index, strip) in strips.enumerated() {
                #expect(strip.rect.minX >= 0 && strip.rect.minY >= 0)
                #expect(strip.rect.maxX <= shape.width && strip.rect.maxY <= shape.height)
                #expect(strip.rect.minX == strip.rect.minX.rounded() && strip.rect.height == strip.rect.height.rounded())
                for other in strips[(index + 1)...] {
                    #expect(!strip.rect.intersects(other.rect), "\(strip.place) overlaps \(other.place)")
                }
            }
            let step = max(1.0, min(shape.width, shape.height) / 150)
            var y = 0.25
            while y < shape.height {
                var x = 0.25
                while x < shape.width {
                    if field.mayLight(x: x, y: y, position: position, pixel: 0.5) {
                        #expect(strips.contains { $0.rect.contains(CGPoint(x: x, y: y)) }, "\(position): lit \(x), \(y) is in no strip")
                    }
                    x += step
                }
                y += step
            }
            #expect(!strips.contains { $0.rect.contains(CGPoint(x: shape.width / 2, y: shape.height / 2)) } || shape.width < 200)
            // Far less than the whole screen.
            #expect(EdgeLayout.area(of: strips) < shape.width * shape.height * 0.6 || shape.width < 200)
        }
    }

    @Test("Looks: the band grows with thickness, glow and the style's particles")
    func looks() {
        let thin = LightLook(style: .glow, thickness: 4, glow: 0.2)
        let thick = LightLook(style: .glow, thickness: 30, glow: 0.9)
        let particles = LightLook(style: .fireworks, thickness: 4, glow: 0.2)
        #expect(thick.band > thin.band)
        #expect(particles.band > thin.band)
        #expect(thin.reach > 0)
        let preview = LightLook(settings: LightSettings(), scale: 0.3)
        #expect(preview.thickness >= 1.5 && preview.detail == 0.3)
        #expect(Set(LightStyle.allCases.map(\.shaderIndex)).count == LightStyle.allCases.count)
        #expect(LightStyle.allCases.map(\.shaderIndex).max() == Int32(LightStyle.allCases.count - 1))
        #expect(LightStyle.allCases.count >= 22)
    }
}
