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

@Suite("Player window layout")
struct PlayerLayoutTests {
    @Test("The large player stacks albums, search and bar; a page replaces the albums")
    func large() {
        let state = PlayerLayoutState(size: .large)
        #expect(PlayerLayout.rows(state) == [PlayerLayout.albumsHeight, PlayerLayout.searchHeight, PlayerLayout.barHeight])
        let size = PlayerLayout.size(state)
        #expect(Double(size.width) == PlayerLayout.largeWidth + 2 * PlayerLayout.margin)
        let content = PlayerLayout.albumsHeight + PlayerLayout.searchHeight + PlayerLayout.barHeight + 2 * PlayerLayout.spacing
        #expect(Double(size.height) == content + 2 * PlayerLayout.margin)
        var page = state
        page.showsPage = true
        #expect(PlayerLayout.rows(page).first == PlayerLayout.pageHeight)
        #expect(PlayerLayout.size(page).height > size.height, "a page grows the window upwards")
        var plain = state
        plain.showsAlbums = false
        #expect(PlayerLayout.rows(plain).first == PlayerLayout.accessoryHeight, "messages keep a row when the albums are off")
        let nothing = PlayerLayoutState(size: .large, showsAlbums: false, showsSearch: false, showsBar: false)
        #expect(nothing.isEmpty)
        #expect(!PlayerLayoutState(size: .small, showsAlbums: false, showsSearch: false, showsBar: false).isEmpty)
    }

    @Test("The small player is its bar and buttons; search opens on request and pages grow it")
    func small() {
        let closed = PlayerLayoutState(size: .small)
        #expect(PlayerLayout.rows(closed) == [PlayerLayout.accessoryHeight, PlayerLayout.barHeight])
        #expect(Double(PlayerLayout.size(closed).width) == PlayerLayout.smallWidth + 2 * PlayerLayout.margin)
        var open = closed
        open.isSearchOpen = true
        #expect(PlayerLayout.rows(open) == [PlayerLayout.accessoryHeight, PlayerLayout.searchHeight, PlayerLayout.barHeight])
        open.showsPage = true
        #expect(PlayerLayout.rows(open).first == PlayerLayout.pageHeight)
        var hiddenSearch = open
        hiddenSearch.showsSearch = false
        #expect(!hiddenSearch.hasSearch, "the search setting wins")
        var noBar = closed
        noBar.showsBar = false
        #expect(noBar.hasBar, "the small player always has its bar")
        // The bar stays in place: both sizes share the bottom anchor.
        let screen = CGRect(x: 0, y: 70, width: 1512, height: 912)
        let point = NormalizedPoint(x: 0.5, y: 0.05)
        let large = WidgetPlacement.frame(size: PlayerLayout.size(PlayerLayoutState(size: .large)), anchor: .bottomCenter, at: point, in: screen)
        let small = WidgetPlacement.frame(size: PlayerLayout.size(closed), anchor: .bottomCenter, at: point, in: screen)
        #expect(large.minY == small.minY && large.midX == small.midX)
    }

    @Test("The queue panel sits beside the player where it fits, else it becomes a page")
    func queuePanel() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let player = CGRect(x: 200, y: 40, width: 788, height: 420)
        let right = try #require(PlayerLayout.queueFrame(besides: player, height: 440, in: screen))
        #expect(right.minX > player.midX && right.minY == player.minY)
        // The two glass surfaces (inside their margins) are one spacing apart.
        let playerGlassRight = player.maxX - PlayerLayout.margin
        let queueGlassLeft = right.minX + PlayerLayout.margin
        #expect(Double(queueGlassLeft - playerGlassRight) == PlayerLayout.spacing)
        let atEdge = CGRect(x: 700, y: 40, width: 788, height: 420)
        let left = try #require(PlayerLayout.queueFrame(besides: atEdge, height: 440, in: screen))
        #expect(left.maxX < atEdge.midX, "no room on the right: the left side")
        #expect(screen.contains(left))
        let list = CGRect(x: 90, y: 100, width: 328, height: 528)
        #expect(PlayerLayout.queueFrame(besides: atEdge, height: 440, in: screen, avoiding: [list]) == nil,
                "never over another widget: the queue becomes a page")
        let marginsOnly = CGRect(x: left.minX - list.width + 2 * PlayerLayout.margin - 1, y: 100, width: list.width, height: 528)
        #expect(PlayerLayout.queueFrame(besides: atEdge, height: 440, in: screen, avoiding: [marginsOnly]) != nil,
                "clear margins may overlap")
        #expect(PlayerLayout.queueFrame(besides: player, height: 2_000, in: screen) == nil, "too tall for the screen")
    }
}

@Suite("Progress schedule")
struct ProgressScheduleTests {
    @Test("About one pixel per step, between four steps a second and one")
    func interval() {
        #expect(ProgressSchedule.interval(duration: 200, pixels: 400) == 0.5)
        #expect(ProgressSchedule.interval(duration: 30, pixels: 600) == ProgressSchedule.fastest, "short songs on wide lines")
        #expect(ProgressSchedule.interval(duration: 3_600, pixels: 300) == ProgressSchedule.slowest, "long songs on short lines")
        #expect(ProgressSchedule.interval(duration: 200, pixels: 400, rate: 2) == 0.25)
        #expect(ProgressSchedule.interval(duration: 0, pixels: 400) == ProgressSchedule.slowest)
        #expect(ProgressSchedule.interval(duration: .nan, pixels: 400) == ProgressSchedule.slowest)
        #expect(ProgressSchedule.interval(duration: 200, pixels: 0) == ProgressSchedule.slowest)
    }

    @Test("The played part follows the anchor and the rate, clamped to the song")
    func fraction() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = anchor.addingTimeInterval(10)
        #expect(ProgressSchedule.fraction(elapsed: 50, anchor: anchor, rate: 1, duration: 200, at: later) == 0.3)
        #expect(ProgressSchedule.fraction(elapsed: 50, anchor: anchor, rate: 0, duration: 200, at: later) == 0.25, "paused")
        #expect(ProgressSchedule.fraction(elapsed: 195, anchor: anchor, rate: 1, duration: 200, at: later) == 1)
        #expect(ProgressSchedule.fraction(elapsed: -5, anchor: anchor, rate: 0, duration: 200, at: later) == 0)
        #expect(ProgressSchedule.fraction(elapsed: 50, anchor: anchor, rate: 1, duration: 0, at: later) == 0)
    }
}

@Suite("Listening source")
struct ListeningSourceChoiceTests {
    @Test("The chosen source, else the playing one, else the first that can play")
    func resolve() {
        let all: (MusicSource) -> Bool = { _ in true }
        #expect(ListeningSourceChoice.resolve(chosen: .spotify, playing: .appleMusic, isAvailable: all) == .spotify)
        #expect(ListeningSourceChoice.resolve(chosen: nil, playing: .youtubeMusic, isAvailable: all) == .youtubeMusic)
        #expect(ListeningSourceChoice.resolve(chosen: nil, playing: .otherApp, isAvailable: all) == .appleMusic, "a source that cannot play picks")
        let noSpotify: (MusicSource) -> Bool = { $0 != .spotify }
        #expect(ListeningSourceChoice.resolve(chosen: .spotify, playing: .soundCloud, isAvailable: noSpotify) == .soundCloud)
        #expect(ListeningSourceChoice.resolve(chosen: .demo, playing: nil, isAvailable: all) == .appleMusic, "never the demo or other apps")
        #expect(ListeningSourceChoice.resolve(chosen: nil, playing: nil, isAvailable: { _ in false }) == nil)
    }

    @Test("A song the source only shows may wait longer for the user")
    func userStart() {
        var queue = PlayQueue()
        let song = CatalogSong(id: "itunes:song:1", title: "Harbor Bells", artistName: "Juniper Coast", duration: 180)
        queue.start([song], at: 0, context: .search)
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        let attempt = PlaybackAttempt(
            entryID: queue.current!.id, song: song, source: .appleMusic, requestedAt: start,
            startTimeout: QueueConductorPolicy.userStartTimeout
        )
        let other = NowPlayingSnapshot(
            track: Track(id: "x", source: .appleMusic, title: "Something Else", artist: "Someone"),
            elapsedTime: 10, playbackRate: 1, timestamp: start
        )
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: other, lastOwn: nil, now: start.addingTimeInterval(30)) == .none)
        #expect(QueueConductorPolicy.decide(attempt: attempt, queue: queue, snapshot: other, lastOwn: nil, now: start.addingTimeInterval(91)) == .startFailed)
    }
}
