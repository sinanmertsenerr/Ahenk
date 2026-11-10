import AhenkKit
import AppKit
import QuartzCore

/// The lyrics part of `--smoke`: every style drawn offscreen with the demo
/// song's invented lines at a few moments, each moment's scene checked
/// against the timeline, and the fonts checked for the Turkish letters.
@MainActor
enum LyricsCheck {
    /// The moments drawn for a song, from its own timeline: the intro, a
    /// line gliding in, the same line being sung, an instrumental part.
    struct Moment {
        var name: String
        var time: TimeInterval
        var line: Int?
        var gap: LyricsTimeline.Gap.Kind?
    }

    static func moments(of timeline: LyricsTimeline, lead: TimeInterval) -> [Moment] {
        var moments: [Moment] = []
        if let intro = timeline.gaps.first(where: { $0.kind == .intro }), let end = intro.end {
            moments.append(Moment(name: "intro", time: end - 2.5, line: nil, gap: .intro))
        }
        if timeline.lines.count > 1 {
            let start = timeline.lines[1].start
            moments.append(Moment(name: "entering", time: start - lead + 0.12, line: 1, gap: nil))
            moments.append(Moment(name: "singing", time: start + 2.4, line: 1, gap: nil))
        }
        if let interlude = timeline.gaps.first(where: { $0.kind == .interlude }) {
            moments.append(Moment(name: "instrumental", time: interlude.start + 4.4, line: nil, gap: .interlude))
        }
        return moments
    }

    struct Result {
        var frames = 0
        var styles = 0
    }

    /// Draws every style; throws on a wrong scene or an empty frame.
    static func renderStyles(song: DemoSong, cover: CGImage?, language: AppLanguage, directory: URL?) throws -> Result {
        let timeline = LyricsTimeline(song.lyrics, duration: song.track.duration)
        let (view, window) = makeStage()
        defer {
            window.contentView = nil
            window.close()
        }
        view.features = DemoBeatFeatures()
        view.cover = cover
        var result = Result()
        for style in LyricStyle.allCases {
            view.content = content(song: song, timeline: timeline, style: style, phase: .lyrics)
            view.layoutSubtreeIfNeeded()
            view.layout()
            let renderer = style.makeRenderer()
            let moments = moments(of: timeline, lead: renderer.lead)
            guard moments.count == 4 else { throw SmokeFailure("\(song.track.title) lacks an intro, lines or a break") }
            for moment in moments {
                // The frame before, so leaving lines and beats are realistic.
                view.draw(lyricTime: moment.time - 0.05, hostTime: moment.time - 0.05, isPlaying: true, position: nil)
                view.draw(lyricTime: moment.time, hostTime: moment.time, isPlaying: true, position: nil)
                let expected = timeline.scene(at: moment.time, glide: renderer.glide, lead: renderer.lead)
                guard let scene = view.currentScene, scene == expected else {
                    throw SmokeFailure("\(style.rawValue) at \(moment.time) s drew another scene than the timeline's")
                }
                guard scene.current?.index == moment.line, scene.gap?.kind == moment.gap else {
                    throw SmokeFailure("\(style.rawValue) at \(moment.time) s shows line \(scene.current?.index ?? -1), expected \(moment.line ?? -1)")
                }
                if let gap = scene.gap, let end = timeline.gaps.first(where: { $0.kind == gap.kind })?.end {
                    let expectedCount = Int((end - moment.time).rounded(.up))
                    guard gap.countdown == expectedCount else {
                        throw SmokeFailure("\(style.rawValue) counts \(gap.countdown ?? -1) at \(moment.time) s, expected \(expectedCount)")
                    }
                }
                let bitmap = try bitmap(of: view)
                guard litPixels(bitmap, in: textArea(of: view)) > 40 else {
                    throw SmokeFailure("\(style.rawValue) drew nothing at \(moment.time) s")
                }
                try save(bitmap, name: "lyrics-\(style.rawValue)-\(moment.name)", language: language, in: directory)
                result.frames += 1
            }
            result.styles += 1
        }
        return result
    }

    /// Loading, no lyrics, instrumental, could not load and words without
    /// timing, each drawn in two styles.
    static func renderStates(song: DemoSong, cover: CGImage?, language: AppLanguage, directory: URL?) throws -> Int {
        let (view, window) = makeStage()
        defer {
            window.contentView = nil
            window.close()
        }
        view.cover = cover
        let plain = song.lyrics.lines.map(\.text).filter { !$0.isEmpty }
        let states: [(String, LyricsStagePhase)] = [
            ("loading", .loading),
            ("none", .message("No lyrics for this song".l10n, symbol: "text.badge.xmark")),
            ("instrumental", .message("Instrumental".l10n, symbol: "music.note")),
            ("failed", .message("The lyrics could not be loaded".l10n, symbol: "wifi.exclamationmark")),
            ("plain", .plain(plain)),
        ]
        var drawn = 0
        for style in [LyricStyle.plain, .cinema] {
            for (name, phase) in states {
                view.content = content(song: song, timeline: nil, style: style, phase: phase)
                view.layoutSubtreeIfNeeded()
                view.layout()
                view.draw(lyricTime: 0, hostTime: 0, isPlaying: true, position: (song.track.duration * 0.3, song.track.duration))
                let bitmap = try bitmap(of: view)
                guard litPixels(bitmap, in: textArea(of: view)) > 20 else { throw SmokeFailure("the \(name) state drew nothing") }
                try save(bitmap, name: "lyrics-state-\(name)-\(style.rawValue)", language: language, in: directory)
                drawn += 1
            }
        }
        return drawn
    }

    private static func makeStage() -> (LyricsStageView, NSWindow) {
        let size = LyricsLayout.widgetSize(textScale: 1, showsCover: true)
        let view = LyricsStageView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentView = view
        return (view, window)
    }

    private static func content(song: DemoSong, timeline: LyricsTimeline?, style: LyricStyle, phase: LyricsStagePhase) -> LyricsStageContent {
        LyricsStageContent(
            phase: phase, timeline: timeline, songID: song.track.id, title: song.track.title, artist: song.track.artist,
            style: style, palette: song.palette, useAlbumColors: true, textScale: 1, showsCover: true, countdown: true
        )
    }

    /// Right of the cover.
    private static func textArea(of view: NSView) -> CGRect {
        let size = view.bounds.size
        return CGRect(x: size.width * 0.3, y: 0, width: size.width * 0.7, height: size.height)
    }

    static func save(_ bitmap: NSBitmapImageRep, name: String, language: AppLanguage, in directory: URL?) throws {
        guard let directory, let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: directory.appendingPathComponent("\(name)-\(language.rawValue).png"))
    }

    /// Every style's font exists and has the Turkish letters.
    static func checkFonts() throws -> [String] {
        var names: [String] = []
        for style in LyricStyle.allCases {
            let face = LyricsFonts.face(for: style)
            let font = LyricsFonts.font(for: style, scale: 1)
            guard LyricsFonts.coversRequiredCharacters(font) else {
                throw SmokeFailure("\(face.name) (\(style.rawValue)) lacks Turkish letters")
            }
            names.append("\(style.rawValue): \(font.fontName)")
        }
        let families = Set(LyricStyle.allCases.map { LyricsFonts.font(for: $0, scale: 1).familyName ?? "" })
        guard families.count == LyricStyle.allCases.count else {
            throw SmokeFailure("two styles share a typeface (\(families.sorted().joined(separator: ", ")))")
        }
        return names
    }

    /// The view's layers drawn into a bitmap over a dark backdrop.
    static func bitmap(of view: NSView) throws -> NSBitmapImageRep {
        let size = view.bounds.size
        let scale: CGFloat = 2
        guard let layer = view.layer,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext
        else { throw SmokeFailure("Could not allocate a bitmap for the lyrics") }
        bitmap.size = size
        context.scaleBy(x: scale, y: scale)
        let colors = [CGColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.33, green: 0.20, blue: 0.36, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        layer.render(in: context)
        return bitmap
    }

    /// Bright pixels in `rect` (points, y up), sampled every 3 points.
    static func litPixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / max(1, bitmap.size.width)
        var lit = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 3) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 3) {
                let px = Int(x * scale)
                let py = bitmap.pixelsHigh - 1 - Int(y * scale)
                guard px >= 0, px < bitmap.pixelsWide, py >= 0, py < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: px, y: py) else { continue }
                if color.brightnessComponent > 0.45 { lit += 1 }
            }
        }
        return lit
    }
}

/// The demo beat as the lines' audio (offscreen checks).
final class DemoBeatFeatures: AudioFeatureSource {
    func currentFeatures() -> AudioFeatures { DemoBeat.features(at: CACurrentMediaTime()) }
    func features(at time: Double) -> AudioFeatures { DemoBeat.features(at: time) }
}
