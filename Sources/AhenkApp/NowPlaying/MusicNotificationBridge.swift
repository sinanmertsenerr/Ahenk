import AhenkKit
import Foundation

/// Listens to the notifications Music and Spotify broadcast on every play,
/// pause and song change (no permission needed) and hands them to their
/// providers. Delivered immediately even while Ahenk is in the background:
/// AppKit holds back distributed notifications for inactive apps otherwise.
@MainActor
final class MusicNotificationBridge: NSObject {
    private let appleMusic: AppleMusicProvider?
    private let spotify: SpotifyProvider?
    private let center = DistributedNotificationCenter.default()

    static let musicNotification = Notification.Name("com.apple.Music.playerInfo")
    static let spotifyNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    init(appleMusic: AppleMusicProvider?, spotify: SpotifyProvider?) {
        self.appleMusic = appleMusic
        self.spotify = spotify
        super.init()
    }

    func start() {
        if appleMusic != nil {
            center.addObserver(self, selector: #selector(musicChanged(_:)), name: Self.musicNotification, object: nil, suspensionBehavior: .deliverImmediately)
        }
        if spotify != nil {
            center.addObserver(self, selector: #selector(spotifyChanged(_:)), name: Self.spotifyNotification, object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        center.removeObserver(self)
    }

    @objc private func musicChanged(_ notification: Notification) {
        guard let info = AppleMusicPlayerInfo(userInfo: notification.userInfo) else { return }
        appleMusic?.ingest(info)
    }

    @objc private func spotifyChanged(_ notification: Notification) {
        guard let event = SpotifyPlaybackEvent(userInfo: notification.userInfo) else { return }
        spotify?.ingest(event)
    }
}
