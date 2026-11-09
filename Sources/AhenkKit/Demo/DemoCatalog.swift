import Foundation

/// One invented song for `--demo`: metadata, palette, cover seed and lyrics.
///
/// Everything here was written for Ahenk. Titles, artists, albums and lyric
/// lines are invented and the covers are generated, so the demo is safe to
/// screenshot and publish.
public struct DemoSong: Sendable, Equatable {
    public let track: Track
    public let year: Int
    public let palette: Palette
    /// Seed for `DemoArtwork`; the same seed always draws the same cover.
    public let artworkSeed: UInt64
    public let lyrics: SyncedLyrics
}

public enum DemoCatalog {
    /// The demo playlist, played in a loop. Every song runs at 120 BPM with
    /// lines on a two-bar (4 s) grid and at least one instrumental break.
    public static let songs: [DemoSong] = [
        song(
            id: "glass-harbor", title: "Glass Harbor", artist: "Nova Atlas", album: "Low Tide Lights",
            year: 2025, duration: 92, seed: 0x5EA_0001,
            colors: ["#0E5E6F", "#FF7A6B", "#FFD9A0"],
            lines: [
                (4, "Lanterns drifting over the bay"),
                (8, "Every wave is keeping time"),
                (12, "I count the colors on the water"),
                (16, "Glass and light along the line"),
                (20, "Hold the night a little longer"),
                (24, "Let the harbor hum along"),
                (28, "We were made of neon weather"),
                (32, "Bright enough to sing this song"),
                // Instrumental break: 36 s → 52 s.
                (52, "Lanterns drifting over the bay"),
                (56, "Every wave is keeping time"),
                (60, "Hold the night a little longer"),
                (64, "Glass and light along the line"),
                (68, "Oh, the tide is turning slowly"),
                (72, "Oh, the city learns our name"),
                (76, "Every light along the harbor"),
                (80, "Blinks the rhythm back again"),
            ]
        ),
        song(
            id: "paper-satellites", title: "Paper Satellites", artist: "The Quiet Ferns", album: "Signal & Bloom",
            year: 2024, duration: 84, seed: 0x5EA_0002,
            colors: ["#5B3CC4", "#FF8FB8", "#9FE7FF"],
            lines: [
                (4, "Folded stars above the rooftop"),
                (8, "Paper satellites in flight"),
                (12, "Sending postcards to the static"),
                (16, "Waiting for a sign tonight"),
                (20, "Turn the dial until it glows"),
                (24, "Find the frequency of you"),
                (28, "All the noise becomes a chorus"),
                (32, "Every signal coming through"),
                (36, "Folded stars above the rooftop"),
                (40, "Paper satellites in flight"),
                (44, "If the sky forgets to answer"),
                (48, "We will draw our own new light"),
                // Instrumental break: 52 s → 64 s.
                (64, "Turn the dial until it glows"),
                (68, "Find the frequency of you"),
                (72, "Every signal coming through"),
            ]
        ),
        song(
            id: "copper-moon-drive", title: "Copper Moon Drive", artist: "Lumen Vale", album: "Night Shift Radio",
            year: 2023, duration: 88, seed: 0x5EA_0003,
            colors: ["#E07A2E", "#7A1F3D", "#1C2A4A"],
            lines: [
                (4, "Headlights painting copper lines"),
                (8, "Highway humming under me"),
                (12, "Moon is rising like a coin"),
                (16, "Spinning slow above the sea"),
                (20, "Keep the windows rolled down low"),
                (24, "Let the engine find the beat"),
                (28, "Every mile a little louder"),
                (32, "Every heartbeat in the street"),
                (36, "Drive, drive, under copper skies"),
                (40, "Shine, shine, till the morning tries"),
                // Instrumental break: 44 s → 56 s.
                (56, "Radio is singing softly"),
                (60, "Static turning into gold"),
                (64, "Hold the wheel and hold the moment"),
                (68, "Some nights never do get old"),
                (72, "Drive, drive, under copper skies"),
                (76, "Shine, shine, till the morning tries"),
            ]
        ),
        song(
            id: "sahilde-neon", title: "Sahilde Neon", artist: "Kıyı Sinyali", album: "Gece Yarısı Frekansı",
            year: 2026, duration: 76, seed: 0x5EA_0004,
            colors: ["#2F6BFF", "#FF2E88", "#FFC53D"],
            lines: [
                (4, "Sahilde neon yanıyor"),
                (8, "Dalgalar ritmi tutuyor"),
                (12, "Şehir uykuya dalarken"),
                (16, "Kalbim usulca atıyor"),
                (20, "Işıklar suya düşüyor"),
                (24, "Renkler yüzüme vuruyor"),
                (28, "Bu gece biraz uzasın"),
                (32, "Şarkı biraz daha sürsün"),
                // Instrumental break: 36 s → 48 s.
                (48, "Sahilde neon yanıyor"),
                (52, "Dalgalar ritmi tutuyor"),
                (56, "Rüzgâr adımı fısıldıyor"),
                (60, "Gece bizimle dönüyor"),
                (64, "Işıklar suya düşüyor"),
                (68, "Şarkı biraz daha sürsün"),
            ]
        ),
    ]

    /// Length of one lyric slot: two bars at 120 BPM.
    public static let lineLength: TimeInterval = 4

    /// The style previews' loop: three invented lines and a pause with its
    /// countdown, `previewCycle` seconds long, repeated four times so a
    /// preview can loop over the second cycle without a seam.
    public static func previewLyrics(turkish: Bool) -> SyncedLyrics {
        let words = turkish
            ? ["Sahilde neon yanıyor", "Dalgalar ritmi tutuyor", "Bu gece biraz uzasın"]
            : ["Lanterns drifting over the bay", "Every wave is keeping time", "Hold the night a little longer"]
        var lines: [LyricLine] = []
        for cycle in 0..<4 {
            let base = Double(cycle) * previewCycle
            lines.append(LyricLine(start: base + 1, text: words[0]))
            lines.append(LyricLine(start: base + 4, text: words[1]))
            lines.append(LyricLine(start: base + 7, text: words[2]))
            // The singing stops here; the pause counts down to the next cycle.
            lines.append(LyricLine(start: base + 9.6, text: ""))
        }
        return SyncedLyrics(lines: lines)
    }

    /// Seconds of one preview loop.
    public static let previewCycle: TimeInterval = 13
    /// Previews treat pauses this long as instrumental (shorter than songs do).
    public static let previewMinimumGap: TimeInterval = 3

    /// The lyric time a preview shows `elapsed` seconds after it started.
    public static func previewTime(elapsed: TimeInterval) -> TimeInterval {
        let cycle = previewCycle
        let wrapped = elapsed.truncatingRemainder(dividingBy: cycle)
        return cycle + (wrapped < 0 ? wrapped + cycle : wrapped)
    }

    private static func song(
        id: String, title: String, artist: String, album: String, year: Int,
        duration: TimeInterval, seed: UInt64, colors: [String], lines: [(TimeInterval, String)]
    ) -> DemoSong {
        let timed = lines.enumerated().map { index, entry in
            let next = index + 1 < lines.count ? lines[index + 1].0 : duration
            return LyricLine(start: entry.0, end: min(next, entry.0 + lineLength), text: entry.1)
        }
        return DemoSong(
            track: Track(
                id: "demo:\(id)", source: .demo, title: title, artist: artist,
                album: album, duration: duration
            ),
            year: year,
            palette: Palette(colors: colors.compactMap(SRGBColor.init(hex:))),
            artworkSeed: seed,
            lyrics: SyncedLyrics(lines: timed)
        )
    }
}
