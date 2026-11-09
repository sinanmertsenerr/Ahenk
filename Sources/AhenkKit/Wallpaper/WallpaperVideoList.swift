import Foundation

/// What the user can add to the live wallpaper's list: a YouTube link (or a
/// bare video ID), the web address of a video, or a video file on this Mac.
public enum WallpaperVideoInput {
    /// File types AVPlayer plays that the list accepts.
    public static let fileExtensions: Set<String> = ["mov", "mp4", "m4v", "mpg", "mpeg", "3gp", "m2ts", "mts"]

    /// The list entry for `text` (pasted or typed), `nil` when it is none of
    /// the above. `title` names it; without one, the file name or the
    /// address's last part does (YouTube videos are named by the caller,
    /// from YouTube's answer).
    public static func savedVideo(from text: String, title: String? = nil, now: Date = Date()) -> SavedVideo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let given = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let id = BrowserSite.youtubeVideoID(trimmed) {
            return SavedVideo(title: given ?? id, kind: .youtube, reference: id, addedAt: now)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.lowercased().hasPrefix("file://") {
            let path: String
            if let url = URL(string: trimmed), url.isFileURL {
                path = url.standardizedFileURL.path
            } else {
                path = ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
            }
            return fileVideo(path: path, title: given, now: now)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding?.nilIfEmpty
        return SavedVideo(title: given ?? (name == "/" ? nil : name) ?? host, kind: .url, reference: url.absoluteString, addedAt: now)
    }

    /// A file the user picked; `nil` for a type the list does not play.
    public static func fileVideo(path: String, title: String? = nil, now: Date = Date()) -> SavedVideo? {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), fileExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return SavedVideo(title: title ?? name, kind: .file, reference: url.path, addedAt: now)
    }
}

extension WallpaperSettings {
    /// The list keeps at most this many videos.
    public static let maximumSavedVideos = 40

    /// Adds `video` unless the same one is listed already; returns the
    /// entry that is in the list now.
    @discardableResult
    public mutating func addVideo(_ video: SavedVideo) -> SavedVideo {
        if let existing = savedVideos.first(where: { $0.kind == video.kind && $0.reference == video.reference }) {
            return existing
        }
        savedVideos.append(video)
        if savedVideos.count > Self.maximumSavedVideos {
            let dropped = savedVideos.removeFirst()
            if selectedVideoID == dropped.id { selectedVideoID = nil }
        }
        return video
    }

    /// Takes a video off the list (and off the wallpaper, if it showed).
    public mutating func removeVideo(id: String) {
        savedVideos.removeAll { $0.id == id }
        if selectedVideoID == id { selectedVideoID = nil }
    }

    /// Shows a video from the list as the wallpaper; `nil` follows the song
    /// again. An unknown ID changes nothing.
    public mutating func selectVideo(id: String?) {
        guard let id else {
            selectedVideoID = nil
            return
        }
        if savedVideos.contains(where: { $0.id == id }) { selectedVideoID = id }
    }

    /// Renames a video (YouTube's title arrives after the video was added).
    public mutating func renameVideo(id: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = savedVideos.firstIndex(where: { $0.id == id }) else { return }
        savedVideos[index].title = clean
    }

    /// The pinned video, if it is still in the list.
    public var selectedVideo: SavedVideo? {
        selectedVideoID.flatMap { id in savedVideos.first { $0.id == id } }
    }
}
