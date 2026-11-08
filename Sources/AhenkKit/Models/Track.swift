import Foundation

/// One song, independent of whether or where it is playing. Used by now
/// playing, Continue Playing, search results, albums and the queue.
public struct Track: Hashable, Sendable, Codable, Identifiable {
    /// Stable within `source`: a persistent ID, URI, URL or file path.
    public var id: String
    public var source: MusicSource
    public var title: String
    public var artist: String
    public var album: String
    /// Length in seconds; 0 when unknown.
    public var duration: TimeInterval
    /// Remote artwork, when the source exposes a URL instead of image data.
    public var artworkURL: URL?

    public init(
        id: String,
        source: MusicSource,
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 0,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = max(0, duration)
        self.artworkURL = artworkURL
    }
}
