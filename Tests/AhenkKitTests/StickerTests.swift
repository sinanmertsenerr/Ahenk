import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

/// Two invented displays side by side: a 1512 × 982 main one with a menu
/// bar and Dock, and a 1920 × 1080 one to its right.
private let main = StickerDisplay(id: "main-uuid", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 70, width: 1512, height: 878))
private let side = StickerDisplay(id: "side-uuid", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
private let displays = [main, side]

@Suite("Stickers")
struct StickerTests {
    let widgets: [DesktopWidget: CGRect] = [
        .clock: CGRect(x: 90, y: 700, width: 300, height: 220),
        .player: CGRect(x: 500, y: 110, width: 640, height: 400),
    ]

    @Test("A desktop sticker's centre is relative to its display and stays reachable")
    func desktopPlacement() throws {
        let placement = StickerPlacement.desktop(display: "side-uuid", center: NormalizedPoint(x: 0.5, y: 0.5))
        let center = try #require(StickerGeometry.center(of: placement, displays: displays, widgets: [:]))
        #expect(center == CGPoint(x: 1512 + 960, y: 527.5))
        // Its display is gone: the first display, same relative place.
        let orphan = StickerGeometry.center(of: placement, displays: [main], widgets: [:])
        #expect(orphan == CGPoint(x: 756, y: 70 + 439))
        // A corner position is pulled in so the sticker can still be grabbed.
        let corner = StickerGeometry.center(of: .desktop(display: "main-uuid", center: NormalizedPoint(x: 1, y: 0)), displays: displays, widgets: [:])
        #expect(corner == CGPoint(x: 1512 - StickerGeometry.edgeInset, y: 70 + StickerGeometry.edgeInset))
        #expect(StickerGeometry.center(of: placement, displays: [], widgets: [:]) == nil)
    }

    @Test("A sticker on a widget keeps its offset from the widget's anchor and hides with it")
    func attachedPlacement() throws {
        // Dropped on the player near its bar: offset from the bottom centre.
        let placement = StickerGeometry.attached(to: .player, frame: widgets[.player]!, center: CGPoint(x: 900, y: 150))
        #expect(placement == .widget(.player, dx: 80, dy: 40))
        // The player grows upwards and gets wider: the sticker stays by the bar.
        let grown = CGRect(x: 460, y: 110, width: 720, height: 560)
        let center = try #require(StickerGeometry.center(of: placement, displays: displays, widgets: [.player: grown]))
        #expect(center == CGPoint(x: 900, y: 150))
        // The clock moves: a sticker on it moves along.
        let onClock = StickerGeometry.attached(to: .clock, frame: widgets[.clock]!, center: CGPoint(x: 120, y: 900))
        let moved = StickerGeometry.center(of: onClock, displays: displays, widgets: [.clock: widgets[.clock]!.offsetBy(dx: 300, dy: -200)])
        #expect(moved == CGPoint(x: 420, y: 700))
        #expect(StickerGeometry.center(of: onClock, displays: displays, widgets: [:]) == nil, "the clock is hidden: so is the sticker")
        // Dragged near the screen's edge with its widget: kept on screen.
        let edge = StickerGeometry.center(of: .widget(.clock, dx: -500, dy: 0), displays: displays, widgets: widgets)
        #expect(edge.map { Double($0.x) } == StickerGeometry.edgeInset)
    }

    @Test("Dragging keeps a sticker's kind: a desktop one changes display, a stuck one its offset")
    func moving() {
        let free = StickerPlacement.desktop(display: "main-uuid", center: NormalizedPoint(x: 0.5, y: 0.5))
        let onSide = StickerGeometry.placement(movedTo: CGPoint(x: 2000, y: 500), from: free, displays: displays, widgets: widgets)
        guard case .desktop(let display, let center) = onSide else {
            Issue.record("not on the desktop")
            return
        }
        #expect(display == "side-uuid")
        #expect(abs(center.x - (2000 - 1512) / 1920.0) < 1e-9)
        let stuck = StickerPlacement.widget(.player, dx: 0, dy: 0)
        let moved = StickerGeometry.placement(movedTo: CGPoint(x: 700, y: 300), from: stuck, displays: displays, widgets: widgets)
        #expect(moved == .widget(.player, dx: -120, dy: 190))
        // Off every screen: the nearest display, pulled onto it.
        let lost = StickerGeometry.placement(movedTo: CGPoint(x: -400, y: 500), from: free, displays: displays, widgets: widgets)
        #expect(lost == .desktop(display: "main-uuid", center: NormalizedPoint(x: StickerGeometry.edgeInset / 1512, y: (500 - 70) / 878)))
    }

    @Test("New stickers: on the widget they were dropped on, else spread over the main display")
    func newPlacement() {
        let dropped = StickerGeometry.newPlacement(at: CGPoint(x: 200, y: 800), onto: .clock, widgets: widgets, displays: displays, existing: 0)
        #expect(dropped == .widget(.clock, dx: 110, dy: -120))
        let first = StickerGeometry.newPlacement(at: nil, onto: nil, widgets: widgets, displays: displays, existing: 0)
        let second = StickerGeometry.newPlacement(at: nil, onto: nil, widgets: widgets, displays: displays, existing: 1)
        #expect(first != second, "new stickers do not land on each other")
        if case .desktop(let id, _) = first { #expect(id == "main-uuid") } else { Issue.record("not on the desktop") }
        #expect(StickerGeometry.newPlacement(at: nil, onto: .lyrics, widgets: widgets, displays: [], existing: 0)
            == .desktop(display: StickerGeometry.mainDisplayKey, center: NormalizedPoint(x: 0.5, y: 0.5)))
    }

    @Test("Size, rotation and the window that holds them")
    func sizeAndRotation() {
        #expect(StickerGeometry.normalizedRotation(3 * .pi) == .pi)
        #expect(abs(StickerGeometry.normalizedRotation(-3 * .pi / 2) - .pi / 2) < 1e-12)
        #expect(StickerGeometry.normalizedRotation(.nan) == 0)
        #expect(StickerGeometry.snappedRotation(.pi / 2 + 0.03) == .pi / 2)
        #expect(StickerGeometry.snappedRotation(0.2) == 0.2)
        #expect(StickerGeometry.snappedRotation(-0.02) == 0)
        // A tall picture: the longer side is the default length.
        #expect(StickerGeometry.defaultWidth(pixelWidth: 500, pixelHeight: 1000) == 100)
        #expect(StickerGeometry.defaultWidth(pixelWidth: 1000, pixelHeight: 500) == 200)
        #expect(StickerGeometry.defaultWidth(pixelWidth: 1000, pixelHeight: 1000, screen: CGSize(width: 300, height: 240)) == 80)
        // Resizing stays in range and on screen.
        #expect(StickerGeometry.clampedWidth(5, aspect: 1, screen: nil) == Sticker.widthRange.lowerBound)
        #expect(StickerGeometry.clampedWidth(5_000, aspect: 1, screen: nil) == Sticker.widthRange.upperBound)
        #expect(StickerGeometry.clampedWidth(600, aspect: 2, screen: CGSize(width: 1512, height: 982)) == 982 * 0.9 / 2)
        let sticker = Sticker(name: "Mug", pixelWidth: 360, pixelHeight: 300, placement: .widget(.player, dx: 0, dy: 0), width: 9_999, rotation: 7)
        #expect(sticker.width == Sticker.widthRange.upperBound && sticker.rotation <= .pi && sticker.rotation > -.pi)
        // The window is square and holds the sticker at any turn.
        let frame = StickerGeometry.windowFrame(center: CGPoint(x: 400, y: 300), size: CGSize(width: 300, height: 400))
        #expect(frame.width == frame.height && frame.width >= 500 + 2 * StickerGeometry.windowMargin)
        #expect(abs(frame.midX - 400) <= 1 && abs(frame.midY - 300) <= 1)
    }

    @Test("Placements and stickers survive encoding; a damaged placement falls back to the main display")
    func coding() throws {
        let stickers = [
            Sticker(name: "Mug", pixelWidth: 360, pixelHeight: 300, placement: .widget(.continuePlaying, dx: 12, dy: -30), width: 150, rotation: 0.3),
            Sticker(name: "Ball", pixelWidth: 320, pixelHeight: 322, placement: .desktop(display: "side-uuid", center: NormalizedPoint(x: 0.2, y: 0.9)), width: 200),
        ]
        let data = try JSONEncoder().encode(stickers)
        #expect(try JSONDecoder().decode([Sticker].self, from: data) == stickers)
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Odd","pixelWidth":10,"pixelHeight":20,"placement":{"kind":"widget","widget":"sidebar","dx":1,"dy":2},"width":"wide"}"#
        let damaged = try JSONDecoder().decode(Sticker.self, from: Data(json.utf8))
        #expect(damaged.placement == .desktop(display: StickerGeometry.mainDisplayKey, center: NormalizedPoint(x: 0.5, y: 0.5)))
        #expect(damaged.width == 180 && damaged.aspect == 2)
    }

    @Test("The store keeps the list and the pictures, in stacking order, and drops what lost its picture")
    func store() async throws {
        let scratch = ScratchDirectory()
        let store = StickerStore(directory: scratch.url)
        let png = TestImages.png(TestImages.solid(SRGBColor("#3388FF")))
        let mug = try store.add(Sticker(name: "Mug", pixelWidth: 64, pixelHeight: 64, placement: .widget(.player, dx: 0, dy: 0), width: 120), png: png)
        let ball = try store.add(Sticker(name: "Ball", pixelWidth: 64, pixelHeight: 64, placement: .desktop(display: "main-uuid", center: NormalizedPoint(x: 0.3, y: 0.3)), width: 90), png: png)
        store.update(id: mug.id) { $0.rotation = 0.5; $0.placement = .widget(.clock, dx: 4, dy: 5) }
        store.bringToFront(id: mug.id)
        store.flush()
        #expect(store.imageData(for: ball.id) == png)

        let reloaded = StickerStore(directory: scratch.url)
        #expect(reloaded.stickers.map(\.name) == ["Ball", "Mug"], "the last one is in front")
        #expect(reloaded.sticker(id: mug.id)?.placement == .widget(.clock, dx: 4, dy: 5))
        #expect(reloaded.sticker(id: mug.id)?.rotation == 0.5)

        // A picture deleted behind Ahenk's back: that sticker is dropped.
        try FileManager.default.removeItem(at: scratch.url.appendingPathComponent(ball.imageFileName))
        #expect(StickerStore(directory: scratch.url).stickers.map(\.name) == ["Mug"])

        reloaded.remove(id: mug.id)
        reloaded.flush()
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent(mug.imageFileName).path))
        #expect(StickerStore(directory: scratch.url).stickers.isEmpty)

        // In memory (the demo): pictures kept without touching the disk.
        let memory = StickerStore(directory: nil)
        let kept = try memory.add(Sticker(name: "Demo", pixelWidth: 64, pixelHeight: 64, placement: .widget(.player, dx: 0, dy: 0), width: 100), png: png)
        #expect(memory.imageData(for: kept.id) == png)
        let updates = await collect(memory.changes(), count: 1)
        #expect(updates.first?.map(\.name) == ["Demo"])
    }

    @Test("The store refuses more than its capacity")
    func capacity() throws {
        let store = StickerStore(directory: nil)
        let png = Data([0x89, 0x50])
        for index in 0..<StickerStore.capacity {
            try store.add(Sticker(name: "S\(index)", pixelWidth: 10, pixelHeight: 10, placement: .widget(.player, dx: 0, dy: 0), width: 60), png: png)
        }
        #expect(throws: StickerStore.StoreError.full) {
            try store.add(Sticker(name: "One more", pixelWidth: 10, pixelHeight: 10, placement: .widget(.player, dx: 0, dy: 0), width: 60), png: png)
        }
    }
}
