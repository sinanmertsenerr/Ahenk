import Foundation

/// What is known about a song when asking a provider for lyrics.
public struct LyricsQuery: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    public init(track: Track) {
        self.init(
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            duration: track.duration > 0 ? track.duration : nil
        )
    }
}

/// Outcome of one provider's lookup.
public enum LyricsResult: Sendable, Equatable, Codable {
    case synced(SyncedLyrics)
    case plain(String)
    case instrumental
    case notFound

    /// True when this carries lyrics to show (synced or plain).
    public var hasLyrics: Bool {
        switch self {
        case .synced, .plain: true
        case .instrumental, .notFound: false
        }
    }
}

/// A lyrics source (LRCLIB, the other online providers, local alignment, the
/// demo). Implementations must be safe to call concurrently.
///
/// Step 6 ports the provider chain (consensus, cache, offsets) on top of this
/// protocol and may extend it with provenance-aware requirements that have
/// default implementations.
public protocol LyricsProvider: Sendable {
    /// Stable identifier for logs and for labelling which source answered.
    var name: String { get }
    func fetch(_ query: LyricsQuery) async throws -> LyricsResult
}
