import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Lyrics settings and placement")
struct LyricsSettingsTests {
    @Test("The position decodes leniently and defaults to above the player")
    func position() throws {
        #expect(LyricsSettings().position == .abovePlayer)
        let data = Data(#"{"position": "top", "style": "neon"}"#.utf8)
        let decoded = try JSONDecoder().decode(LyricsSettings.self, from: data)
        #expect(decoded.position == .top && decoded.style == .neon)
        let unknown = try JSONDecoder().decode(LyricsSettings.self, from: Data(#"{"position": "sideways"}"#.utf8))
        #expect(unknown.position == .abovePlayer)
    }

    @Test("Each position puts the lyrics where it says, clear of the list")
    func placement() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let size = CGSize(width: 810, height: 300)
        let player = CGRect(x: 400, y: 40, width: 760, height: 380)
        let list = CGRect(x: 90, y: 200, width: 330, height: 520)
        let above = WidgetPlacement.lyricsFrame(size: size, position: .abovePlayer, player: player, list: list, in: screen)
        #expect(above.minY >= player.maxY && !above.intersects(list) && screen.contains(above))
        let middle = WidgetPlacement.lyricsFrame(size: size, position: .middle, player: nil, list: nil, in: screen)
        #expect(abs(middle.midX - screen.midX) < 1)
        let top = WidgetPlacement.lyricsFrame(size: size, position: .top, player: player, list: nil, in: screen)
        #expect(top.maxY > screen.height * 0.9 && screen.contains(top))
        // No room above a tall player: right of the middle instead.
        let tall = CGRect(x: 400, y: 40, width: 760, height: 800)
        let fallback = WidgetPlacement.lyricsFrame(size: size, position: .abovePlayer, player: tall, list: nil, in: screen)
        #expect(screen.contains(fallback) && fallback.midX > screen.midX)
        let frames = WidgetPlacement.defaultFrames(sizes: [.lyrics: size, .player: player.size], in: screen, lyrics: .top)
        #expect(try #require(frames[.lyrics]).maxY > screen.height * 0.9)
    }
}
