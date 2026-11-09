import CoreGraphics
import Foundation

/// What the player window shows; its size follows from it.
public struct PlayerLayoutState: Hashable, Sendable {
    public var size: PlayerSize
    /// The artist's albums (large player only).
    public var showsAlbums: Bool
    /// The search field (always in the large player; on request in the small one).
    public var showsSearch: Bool
    public var showsBar: Bool
    /// An album, an artist or search results are open above the field.
    public var showsPage: Bool
    /// The small player's search field was opened.
    public var isSearchOpen: Bool
    /// The live wallpaper's picker dots on top.
    public var showsWallpaperPicker: Bool

    public init(
        size: PlayerSize, showsAlbums: Bool = true, showsSearch: Bool = true, showsBar: Bool = true,
        showsPage: Bool = false, isSearchOpen: Bool = false, showsWallpaperPicker: Bool = false
    ) {
        self.size = size
        self.showsAlbums = showsAlbums
        self.showsSearch = showsSearch
        self.showsBar = showsBar
        self.showsPage = showsPage
        self.isSearchOpen = isSearchOpen
        self.showsWallpaperPicker = showsWallpaperPicker
    }

    /// The small player always shows its bar: it is all there is of it.
    public var hasBar: Bool { size == .small || showsBar }

    public var hasSearch: Bool {
        switch size {
        case .large: showsSearch
        case .small: showsSearch && isSearchOpen
        }
    }

    /// Something is drawn at all (the dots alone are not a player).
    public var isEmpty: Bool {
        size == .large && !showsAlbums && !showsSearch && !showsBar && !showsPage
    }
}

/// The player window's parts, stacked from the bottom: the bar, the search
/// field, then the albums or an open page, and on top the live wallpaper's
/// picker dots when they are on. The window is anchored at its
/// bottom centre (`DesktopWidget.player.anchor`), so the bar stays where
/// the user put it while the window grows or shrinks above it.
public enum PlayerLayout {
    public static let largeWidth: Double = 760
    public static let smallWidth: Double = 660
    public static let barHeight: Double = 58
    public static let searchHeight: Double = 40
    /// The cover flow with the centre album's title under it.
    public static let albumsHeight: Double = 268
    /// An album, an artist or search results.
    public static let pageHeight: Double = 404
    /// The small player's round buttons, or the row a message appears in
    /// when nothing else is above the field.
    public static let accessoryHeight: Double = 34
    /// The live wallpaper's picker dots (or the artist's name field).
    public static let pickerHeight: Double = 26
    public static let spacing: Double = 10
    /// Clear room around the glass for its shadow.
    public static let margin: Double = 14
    /// The queue panel beside the player.
    public static let queueWidth: Double = 330

    /// Heights of the parts from the top down (without margins).
    public static func rows(_ state: PlayerLayoutState) -> [Double] {
        var rows: [Double] = []
        if state.showsWallpaperPicker, !state.isEmpty { rows.append(pickerHeight) }
        switch state.size {
        case .large:
            if state.showsPage {
                rows.append(pageHeight)
            } else if state.showsAlbums {
                rows.append(albumsHeight)
            } else {
                rows.append(accessoryHeight)
            }
        case .small:
            if state.showsPage { rows.append(pageHeight) }
            rows.append(accessoryHeight)
        }
        if state.hasSearch { rows.append(searchHeight) }
        if state.hasBar { rows.append(barHeight) }
        return rows
    }

    public static func width(_ state: PlayerLayoutState) -> Double {
        state.size == .large ? largeWidth : smallWidth
    }

    /// The window's size, margins included.
    public static func size(_ state: PlayerLayoutState) -> CGSize {
        let rows = rows(state)
        let content = rows.reduce(0, +) + spacing * Double(max(0, rows.count - 1))
        return CGSize(width: width(state) + 2 * margin, height: content + 2 * margin)
    }

    /// Where the queue panel goes beside the player: right of it, else left
    /// of it, its bottom level with the player's, wholly on screen and off
    /// the other widgets (`avoiding`, their frames). `nil` when neither side
    /// has room; the queue then opens as a page above the search field.
    public static func queueFrame(
        besides player: CGRect, height: Double, in visible: CGRect, avoiding others: [CGRect] = []
    ) -> CGRect? {
        let width = queueWidth + 2 * margin
        // The panel's margin overlaps the player's so the gap between the two
        // glass surfaces equals the usual spacing.
        let overlap = 2 * margin - spacing
        let right = CGRect(x: player.maxX - overlap, y: player.minY, width: width, height: height)
        let left = CGRect(x: player.minX - width + overlap, y: player.minY, width: width, height: height)
        return [right, left].first { frame in
            visible.contains(frame) && !others.contains { other in
                // Margins may overlap; glass may not.
                frame.insetBy(dx: margin, dy: margin).intersects(other.insetBy(dx: margin, dy: margin))
            }
        }
    }
}

/// How often the progress line moves: about one pixel per step, never more
/// than four times a second and at least once a second, so a playing song
/// costs a handful of tiny redraws per second instead of one per frame.
public enum ProgressSchedule {
    public static let fastest: TimeInterval = 0.25
    public static let slowest: TimeInterval = 1

    /// Seconds between steps for a song of `duration` seconds drawn
    /// `pixels` wide, at `rate` (1 = normal speed).
    public static func interval(duration: TimeInterval, pixels: Double, rate: Double = 1) -> TimeInterval {
        guard duration.isFinite, duration > 0, pixels.isFinite, pixels >= 1 else { return slowest }
        let speed = rate.isFinite && rate > 0 ? rate : 1
        return min(slowest, max(fastest, duration / pixels / speed))
    }

    /// The played part (0…1) of a song at `date`, from its position at
    /// `anchor` and the playback rate.
    public static func fraction(
        elapsed: TimeInterval, anchor: Date, rate: Double, duration: TimeInterval, at date: Date
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let moving = rate.isFinite && rate > 0 ? date.timeIntervalSince(anchor) * rate : 0
        let position = elapsed + moving
        guard position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
}

/// Where picks from search, albums and lists play: the source the user
/// chose, else the one that plays (when it can play picks), else the first
/// that can.
public enum ListeningSourceChoice {
    /// The sources the picker offers, in order: the apps, then the sites.
    public static let offered: [MusicSource] = [
        .appleMusic, .spotify, .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube,
    ]

    public static func resolve(
        chosen: MusicSource?, playing: MusicSource?, isAvailable: (MusicSource) -> Bool
    ) -> MusicSource? {
        if let chosen, offered.contains(chosen), isAvailable(chosen) { return chosen }
        if let playing, offered.contains(playing), isAvailable(playing) { return playing }
        return offered.first(where: isAvailable)
    }
}
