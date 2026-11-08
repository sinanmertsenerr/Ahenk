import Foundation

/// One way of learning what plays and of controlling it: the MediaRemote
/// adapter, Apple Music, the Spotify app, the browser bridge, local files or
/// the demo. Step 2's `NowPlayingHub` merges several providers into the one
/// active song.
public protocol NowPlayingProvider: AnyObject, Sendable {
    /// Stable identifier for logs and for routing commands ("demo",
    /// "mediaremote", "apple-music", ...).
    var id: String { get }

    /// Starts observing. Yields the provider's current snapshot immediately,
    /// then every time something other than the interpolated position changes
    /// (song, play state, seek, shuffle, repeat, like). `nil` means nothing
    /// is playing. Every call returns an independent stream; cancelling the
    /// consuming task ends that stream.
    func snapshots() -> AsyncStream<NowPlayingSnapshot?>

    /// Runs a transport command on this provider's player. Returns `false`
    /// when the provider cannot perform it.
    @discardableResult
    func perform(_ command: PlaybackCommand) async -> Bool
}
