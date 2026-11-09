import Foundation

/// The live wallpaper in demo mode: no external media at all. Each demo
/// song gets generated motion in several looks drawn from its palette: one
/// stands in for the song's own video (as long as the song, so it follows
/// the song's position), two for other videos by the artist, then the
/// cover. The picker dots and every crossfade can be seen without music,
/// network or permissions.
public enum WallpaperDemo {
    /// Invented names for the generated looks.
    public static let lookTitles = ["Tide Lines", "Night Bloom", "Copper Haze", "Glass Rain"]

    public static var lookCount: Int { lookTitles.count }

    public static func candidates(for song: DemoSong) -> [WallpaperCandidate] {
        let first = Int(song.artworkSeed % UInt64(lookCount))
        let looks = (0..<3).map { (first + $0) % lookCount }
        return [
            .generated(look: looks[0], kind: .songVideo, title: song.track.title, duration: song.track.duration),
            .generated(look: looks[1], kind: .artistVideo, title: lookTitles[looks[1]]),
            .generated(look: looks[2], kind: .artistVideo, title: lookTitles[looks[2]]),
            .artwork,
        ]
    }

    /// The colours of one look: the song's palette turned and lifted so
    /// each look reads differently.
    public static func colors(look: Int, palette: Palette) -> [SRGBColor] {
        let base = palette.colors.isEmpty ? Palette.neutral.colors : palette.colors
        let shift = ((look % max(1, base.count)) + base.count) % max(1, base.count)
        let turned = Array(base[shift...] + base[..<shift])
        let accents: [SRGBColor] = [SRGBColor("#101626"), SRGBColor("#2A1838"), SRGBColor("#0D2B2E"), SRGBColor("#2E1A12")]
        return turned + [accents[((look % accents.count) + accents.count) % accents.count]]
    }
}
