import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Cover flow geometry")
struct CoverFlowGeometryTests {
    let geometry = CoverFlowGeometry()

    @Test("The centre card faces the viewer; side cards turn away symmetrically")
    func cards() {
        let center = geometry.card(atOffset: 0)
        #expect(center.x == 0 && center.angle == 0 && center.scale == 1 && center.shade == 0 && center.opacity == 1)
        for offset in [0.25, 0.5, 1, 2, 3.5] {
            let right = geometry.card(atOffset: offset)
            let left = geometry.card(atOffset: -offset)
            #expect(right.x == -left.x)
            #expect(right.angle == -left.angle)
            #expect(right.scale == left.scale && right.zIndex == left.zIndex)
            #expect(right.angle < 0, "cards on the right face left")
        }
        #expect(geometry.card(atOffset: 1).angle == -geometry.maxAngle)
        #expect(geometry.card(atOffset: 3).angle == -geometry.maxAngle, "the turn stops growing after the first card")
        #expect(geometry.card(atOffset: 1).scale == geometry.sideScale)
        #expect(geometry.card(atOffset: 1).x == geometry.centerGap)
        #expect(geometry.card(atOffset: 2).x == geometry.centerGap + geometry.sideSpacing)
        #expect(geometry.card(atOffset: 3).opacity == 1)
        #expect(geometry.card(atOffset: 3.5).opacity == 0.5, "cards fade out over one card beyond the radius")
        #expect(geometry.card(atOffset: 4).opacity == 0)
        #expect(geometry.card(atOffset: .nan).opacity == 0)
    }

    @Test("Cards move outwards steadily and nearer cards stay in front")
    func monotonic() {
        var lastX = -Double.infinity
        var lastZ = Double.infinity
        for step in 0...40 {
            let card = geometry.card(atOffset: Double(step) / 10)
            #expect(card.x >= lastX)
            #expect(card.zIndex <= lastZ)
            #expect(card.shade <= CoverFlowGeometry.maximumShade)
            lastX = card.x
            lastZ = card.zIndex
        }
    }

    @Test("Index math: nearest card, dragging with resistance at the ends, momentum")
    func indexMath() {
        #expect(CoverFlowGeometry.nearestIndex(to: 2.4, count: 5) == 2)
        #expect(CoverFlowGeometry.nearestIndex(to: 2.6, count: 5) == 3)
        #expect(CoverFlowGeometry.nearestIndex(to: -3, count: 5) == 0)
        #expect(CoverFlowGeometry.nearestIndex(to: 99, count: 5) == 4)
        #expect(CoverFlowGeometry.nearestIndex(to: 1, count: 0) == 0)
        let step = geometry.dragStep
        #expect(geometry.position(dragging: -step * 2, from: 1, count: 5) == 3, "dragging left moves to later cards")
        #expect(geometry.position(dragging: step * 3, from: 1, count: 5) == -2.0 / 3, "past the first card at a third of the pace")
        #expect(geometry.position(dragging: -step * 7, from: 1, count: 5) == 4 + 4.0 / 3)
        #expect(geometry.restingIndex(position: 2.2, velocity: 0, count: 5) == 2)
        #expect(geometry.restingIndex(position: 2.2, velocity: -900, count: 5) == 4, "a fast fling carries on")
        #expect(geometry.restingIndex(position: 2.2, velocity: -1_000_000, count: 50) == 5, "at most three cards")
        #expect(geometry.restingIndex(position: 0.3, velocity: 5_000, count: 5) == 0)
    }

    @Test("Only cards near the position are drawn")
    func visibleRange() {
        #expect(geometry.visibleIndices(around: 0, count: 10) == 0...4)
        #expect(geometry.visibleIndices(around: 5.5, count: 10) == 2...9)
        #expect(geometry.visibleIndices(around: 9, count: 10) == 5...9)
        #expect(geometry.visibleIndices(around: 0, count: 0) == nil)
        #expect(geometry.width > geometry.cardSide)
    }
}

@Suite("Widget placement")
struct WidgetPlacementTests {
    let screen = CGRect(x: 0, y: 70, width: 1512, height: 912)

    @Test("A saved anchor gives the frame back, for every anchor kind")
    func roundTrip() {
        let size = CGSize(width: 300, height: 200)
        for widget in DesktopWidget.allCases {
            let frame = CGRect(x: 400, y: 300, width: size.width, height: size.height)
            let normalized = WidgetPlacement.normalizedAnchor(of: frame, anchor: widget.anchor, in: screen)
            let restored = WidgetPlacement.frame(size: size, anchor: widget.anchor, at: normalized, in: screen)
            #expect(abs(restored.minX - frame.minX) < 1e-6 && abs(restored.minY - frame.minY) < 1e-6, "\(widget)")
        }
    }

    @Test("The player keeps its bar in place when it changes size")
    func bottomAnchor() {
        let point = NormalizedPoint(x: 0.5, y: 0.1)
        let large = WidgetPlacement.frame(size: CGSize(width: 640, height: 420), anchor: .bottomCenter, at: point, in: screen)
        let small = WidgetPlacement.frame(size: CGSize(width: 600, height: 110), anchor: .bottomCenter, at: point, in: screen)
        #expect(large.minY == small.minY)
        #expect(large.midX == small.midX)
    }

    @Test("Frames are kept on the screen, also after a resolution change")
    func clamping() {
        let size = CGSize(width: 300, height: 200)
        let corner = WidgetPlacement.frame(size: size, anchor: .topLeft, at: NormalizedPoint(x: 1, y: 0), in: screen)
        #expect(screen.insetBy(dx: WidgetPlacement.edgeMargin, dy: WidgetPlacement.edgeMargin).contains(corner))
        let saved = WidgetPlacement.normalizedAnchor(of: CGRect(x: 1180, y: 700, width: 300, height: 200), anchor: .topLeft, in: screen)
        let smaller = CGRect(x: 0, y: 40, width: 1024, height: 700)
        let moved = WidgetPlacement.frame(size: size, anchor: .topLeft, at: saved, in: smaller)
        #expect(smaller.contains(moved))
        let huge = WidgetPlacement.clamp(CGRect(x: -50, y: -50, width: 3000, height: 2000), into: screen)
        let margin = CGFloat(WidgetPlacement.edgeMargin)
        #expect(abs(huge.minX - (screen.minX + margin)) < 1e-9)
        #expect(abs(huge.maxY - (screen.maxY - margin)) < 1e-9, "an oversized frame keeps its top left on screen")
        #expect(NormalizedPoint(x: .nan, y: 7) == NormalizedPoint(x: 0.5, y: 1))
    }

    @Test("Default layout: clock top left, the list under it, the player in the lower middle")
    func defaults() throws {
        let sizes: [DesktopWidget: CGSize] = [
            .clock: CGSize(width: 260, height: 190), .continuePlaying: CGSize(width: 300, height: 460),
            .player: CGSize(width: 680, height: 430), .lyrics: CGSize(width: 600, height: 300),
        ]
        let frames = WidgetPlacement.defaultFrames(sizes: sizes, in: screen)
        let clock = try #require(frames[.clock])
        let list = try #require(frames[.continuePlaying])
        let player = try #require(frames[.player])
        #expect(clock.minX < screen.midX && clock.maxY > screen.midY)
        #expect(list.maxY <= clock.minY && list.minX == clock.minX)
        #expect(player.minY < screen.midY)
        #expect(!player.intersects(list) && !player.intersects(clock))
        for frame in frames.values {
            #expect(screen.contains(frame))
        }
        let narrow = CGRect(x: 0, y: 0, width: 1100, height: 700)
        let tight = WidgetPlacement.defaultFrames(sizes: sizes, in: narrow)
        #expect(narrow.contains(try #require(tight[.continuePlaying])), "the list shrinks to fit a short screen")
    }

    @Test("Positions are saved per screen and reset per screen")
    func persistence() throws {
        let settings = AppSettings()
        settings.layout.setPosition(NormalizedPoint(x: 0.2, y: 0.8), of: DesktopWidget.clock.rawValue, on: "SCREEN-A")
        settings.layout.setPosition(NormalizedPoint(x: 0.5, y: 0.1), of: DesktopWidget.player.rawValue, on: "SCREEN-A")
        settings.layout.setPosition(NormalizedPoint(x: 0.7, y: 0.7), of: DesktopWidget.clock.rawValue, on: "SCREEN-B")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.layout.position(of: "clock", on: "SCREEN-A") == NormalizedPoint(x: 0.2, y: 0.8))
        #expect(decoded.layout.position(of: "clock", on: "SCREEN-B") == NormalizedPoint(x: 0.7, y: 0.7))
        decoded.layout.resetPositions(on: "SCREEN-A")
        #expect(decoded.layout.position(of: "clock", on: "SCREEN-A") == nil)
        #expect(decoded.layout.position(of: "player", on: "SCREEN-A") == nil)
        #expect(decoded.layout.position(of: "clock", on: "SCREEN-B") != nil)
    }
}

@Suite("Clock text")
struct ClockTextTests {
    // 2026-11-09 14:25:30 UTC, a Monday.
    let date = Date(timeIntervalSince1970: 1_794_234_330)
    let utc = TimeZone(identifier: "UTC")!

    @Test("24- and 12-hour time")
    func time() {
        let english = Locale(identifier: "en_US")
        #expect(ClockText.time(date, twentyFourHour: true, locale: english, timeZone: utc) == .init(digits: "14:25", dayPeriod: nil))
        let twelve = ClockText.time(date, twentyFourHour: false, locale: english, timeZone: utc)
        #expect(twelve.digits == "2:25")
        #expect(twelve.dayPeriod == "PM")
        let morning = Date(timeIntervalSince1970: 1_794_215_100) // 09:05 UTC
        #expect(ClockText.time(morning, twentyFourHour: true, locale: english, timeZone: utc).digits == "09:05")
        #expect(ClockText.uses24Hour(.system, systemUses24Hour: true))
        #expect(!ClockText.uses24Hour(.twelveHour, systemUses24Hour: true))
        #expect(ClockText.uses24Hour(.twentyFourHour, systemUses24Hour: false))
        #expect(ClockText.localeUses24Hour(Locale(identifier: "tr_TR")))
        #expect(!ClockText.localeUses24Hour(Locale(identifier: "en_US")))
    }

    @Test("The date follows the language")
    func dateText() {
        #expect(ClockText.date(date, locale: Locale(identifier: "tr_TR"), timeZone: utc) == "9 Kasım Pazartesi")
        #expect(ClockText.date(date, locale: Locale(identifier: "en_US"), timeZone: utc) == "Monday, November 9")
        #expect(ClockText.date(date, locale: Locale(identifier: "en_GB"), timeZone: utc) == "Monday 9 November")
    }

    @Test("The clock wakes at the next minute")
    func nextMinute() {
        #expect(abs(ClockText.secondsToNextMinute(after: date, timeZone: utc) - 30) < 1e-6)
        let exact = Date(timeIntervalSince1970: 1_794_234_300)
        #expect(ClockText.secondsToNextMinute(after: exact, timeZone: utc) == 60)
    }
}
