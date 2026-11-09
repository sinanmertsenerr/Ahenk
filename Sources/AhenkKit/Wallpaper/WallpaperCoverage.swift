import CoreGraphics
import Foundation

/// How much of a display's desktop other apps' windows cover. The system's
/// occlusion state cannot tell: a window at the desktop picture's level
/// always shows a little through the translucent menu bar and Dock, so it
/// never counts as hidden. A wallpaper only the menu bar's blur reveals is
/// not worth decoding a video for.
public enum WallpaperCoverage {
    /// Covered at least this much, the wallpaper counts as hidden.
    public static let hiddenShare = 0.97
    static let columns = 32
    static let rows = 20

    /// The share (0…1) of `area` that `windows` cover, sampled on a grid
    /// (all rectangles in the same coordinates).
    public static func coveredShare(of area: CGRect, by windows: [CGRect]) -> Double {
        guard area.width > 0, area.height > 0 else { return 0 }
        let relevant = windows.filter { $0.intersects(area) }
        guard !relevant.isEmpty else { return 0 }
        var covered = 0
        for row in 0..<rows {
            let y = area.minY + (Double(row) + 0.5) * area.height / Double(rows)
            for column in 0..<columns {
                let x = area.minX + (Double(column) + 0.5) * area.width / Double(columns)
                let point = CGPoint(x: x, y: y)
                if relevant.contains(where: { $0.contains(point) }) { covered += 1 }
            }
        }
        return Double(covered) / Double(rows * columns)
    }

    public static func isHidden(_ area: CGRect, by windows: [CGRect]) -> Bool {
        coveredShare(of: area, by: windows) >= hiddenShare
    }
}
