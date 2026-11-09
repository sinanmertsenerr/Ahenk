import AhenkKit
import AppKit

/// Plays a pick from the catalog in the chosen source, and reads what each
/// source shares (playlists, volume).
///
/// - Demo: the demo provider plays the invented song.
/// - Apple Music: a library song plays through AppleScript (by its ID when
///   it came from Music, else by title and artist). Music's scripting has no
///   access to the Apple Music catalog, so a song that is not in the library
///   is opened on its catalog page in Music, where one click plays it.
/// - Spotify: `play track "spotify:track:…"`, with the track ID from the
///   song's own ID (Continue Playing) or from `SpotifyTrackFinding`; an
///   unmatched song opens Spotify's search instead.
/// - Music sites: through `BrowserPlaybackRouting` (Step 7's extension);
///   until then the player says the extension is needed.
///
/// Playing a pick is something the user asked for, so the source's app is
/// launched if needed (in the background) and macOS may ask once for the
/// Automation permission. When Ahenk's queue moves on by itself
/// (`interactive: false`), nothing is brought to the front: a song that
/// would need the user's click is skipped instead. Reading playlists and
/// the volume never launches an app and never asks.
@MainActor
final class PlaybackRouter {
    enum Outcome: Equatable {
        case started
        /// The source's app shows the song; the user starts it there.
        case shown(String)
        /// Only the user can start this song (it would need a click in the
        /// source's app); returned when the queue moves on by itself.
        case needsUser
        case unavailable(String)
        case failed(String)
    }

    enum PlaylistsAnswer: Equatable {
        case playlists([CatalogPlaylist])
        case unavailable(String)
    }

    /// The sources the picker offers, in order.
    static let listenable = ListeningSourceChoice.offered

    private let services: NowPlayingServices
    private let demo: DemoProvider?
    private let log = AhenkLogger(category: "player")

    init(services: NowPlayingServices, demo: DemoProvider?) {
        self.services = services
        self.demo = demo
    }

    var isDemo: Bool { demo != nil }

    /// Why a source cannot be picked right now (`nil`: it can).
    func unavailableReason(for source: MusicSource) -> String? {
        if isDemo { return source == .demo ? nil : "Not in demo mode".l10n }
        switch source {
        case .appleMusic: return services.apps.isInstalled(KnownApps.appleMusic) ? nil : "Not installed".l10n
        case .spotify: return services.apps.isInstalled(KnownApps.spotify) ? nil : "Not installed".l10n
        case .demo, .otherApp, .local: return "Not available".l10n
        default: return nil
        }
    }

    // MARK: Playing

    func play(
        _ song: CatalogSong, in source: MusicSource, context: QueueContext?, startDelay: TimeInterval, interactive: Bool = true
    ) async -> Outcome {
        if isDemo {
            guard source == .demo else { return .unavailable("In demo mode, songs play in the demo player.".l10n) }
            return playDemo(song, startDelay: startDelay)
        }
        log.info("Playing \u{201C}\(song.title)\u{201D} in \(source.rawValue)\(interactive ? "" : " (queue)")")
        switch source {
        case .appleMusic: return await playInMusic(song, context: context, interactive: interactive)
        case .spotify: return await playInSpotify(song, interactive: interactive)
        case .demo: return playDemo(song, startDelay: startDelay)
        case .otherApp, .local: return .unavailable("This source cannot play songs from the catalog.".l10n)
        case .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube:
            return await playInBrowser(song, site: source)
        }
    }

    private func playDemo(_ song: CatalogSong, startDelay: TimeInterval) -> Outcome {
        guard let demo, let demoSong = demo.library.demoSong(id: song.originID(in: .demo) ?? song.id) else {
            return .failed("This song is not part of the demo.".l10n)
        }
        demo.play(demoSong, startDelay: startDelay)
        return .started
    }

    private func playInMusic(_ song: CatalogSong, context: QueueContext?, interactive: Bool) async -> Outcome {
        guard let scripts = services.scripts else { return .unavailable("Not available".l10n) }
        guard services.apps.isInstalled(KnownApps.appleMusic) else { return .unavailable("Music is not installed.".l10n) }
        guard await ensureRunning(KnownApps.appleMusic) else { return .failed("Music did not open.".l10n) }
        guard await scripts.automationPermission(for: KnownApps.appleMusic, askIfNeeded: interactive) == .granted else {
            return .failed("Allow Ahenk to control Music in System Settings › Privacy & Security › Automation.".l10n)
        }
        var playlistID: String?
        if case .playlist(let id, _) = context, id.hasPrefix("music:playlist:") {
            playlistID = MusicAppScripts.persistentID(in: id)
        }
        if let id = song.originID(in: .appleMusic).flatMap(MusicAppScripts.persistentID(in:)),
           let script = MusicAppScripts.playLibraryTrack(persistentID: id, playlistID: playlistID),
           case .success(let value) = await scripts.run(script), case .played = ScriptPlayResult.parse(value) {
            return .started
        }
        let byName = MusicAppScripts.playLibraryMatch(title: song.title, artist: song.artistName, album: song.albumTitle)
        if case .success(let value) = await scripts.run(byName), case .played = ScriptPlayResult.parse(value) {
            return .started
        }
        guard interactive else { return .needsUser }
        if let page = await catalogPage(for: song) {
            NSWorkspace.shared.open(page)
            return .shown("This song is not in your Music library. Music shows it now: press Play there.".l10n)
        }
        return .failed("This song is not in your Music library.".l10n)
    }

    /// The song's page in Music: its own catalog link, or (for a song that
    /// played elsewhere) the catalog's match for it.
    private func catalogPage(for song: CatalogSong) async -> URL? {
        if let page = MusicAppScripts.catalogPageURL(for: song) { return page }
        guard let origin = song.origin, let match = try? await services.catalog.artist(for: origin),
              let found = match.song
        else { return nil }
        return MusicAppScripts.catalogPageURL(for: found)
    }

    private func playInSpotify(_ song: CatalogSong, interactive: Bool) async -> Outcome {
        guard let scripts = services.scripts else { return .unavailable("Not available".l10n) }
        guard services.apps.isInstalled(KnownApps.spotify) else { return .unavailable("Spotify is not installed.".l10n) }
        var trackID = song.originID(in: .spotify).flatMap(SpotifyAppScripts.trackID(in:))
        if trackID == nil, let finder = services.spotifyFinder {
            let query = SongQuery(song: song)
            trackID = await finder.spotifyTrackIDs(for: [query])[query]
        }
        guard let trackID, let script = SpotifyAppScripts.playTrack(id: trackID) else {
            guard interactive else { return .needsUser }
            if let search = SpotifyAppScripts.searchURI(for: song) { NSWorkspace.shared.open(search) }
            return .shown("This song could not be found on Spotify. Spotify shows its search results instead.".l10n)
        }
        guard await ensureRunning(KnownApps.spotify) else { return .failed("Spotify did not open.".l10n) }
        guard await scripts.automationPermission(for: KnownApps.spotify, askIfNeeded: interactive) == .granted else {
            return .failed("Allow Ahenk to control Spotify in System Settings › Privacy & Security › Automation.".l10n)
        }
        if case .success(let value) = await scripts.run(script), case .played = ScriptPlayResult.parse(value) {
            return .started
        }
        return .failed("Spotify did not start the song.".l10n)
    }

    private func playInBrowser(_ song: CatalogSong, site: MusicSource) async -> Outcome {
        guard let bridge = services.browserPlayback else {
            return .unavailable("Playing in the browser needs the Ahenk browser extension.".l10n)
        }
        var spotifyID: String?
        if site == .spotifyWeb, let finder = services.spotifyFinder {
            let query = SongQuery(song: song)
            spotifyID = await finder.spotifyTrackIDs(for: [query])[query]
        }
        switch await bridge.play(BrowserPlayRequest(site: site, song: song, spotifyTrackID: spotifyID)) {
        case .started: return .started
        case .notFound: return .failed("The site did not find this song.".l10n)
        case .noTab: return .failed("Open the site in your browser first.".l10n)
        case .failed(let reason):
            log.notice("Browser playback failed: \(reason)")
            return .failed("The browser did not start the song.".l10n)
        }
    }

    /// Launches the app in the background when it is not running and waits
    /// until it answers.
    private func ensureRunning(_ bundleIdentifier: String) async -> Bool {
        let presence = services.presence
        if presence?.isRunning(bundleIdentifier) == true { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        log.notice("Opening \(bundleIdentifier) to play a song")
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<60 {
            if presence?.isRunning(bundleIdentifier) ?? true {
                // Scripting answers a moment after the app appears.
                try? await Task.sleep(for: .seconds(1.5))
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: Reading

    /// The playlists a source shares. Never launches an app or asks.
    func playlists(of source: MusicSource) async -> PlaylistsAnswer {
        if isDemo, let demo, source == .demo { return .playlists(demo.library.playlists) }
        switch source {
        case .appleMusic:
            guard let status = services.statuses[.appleMusic], status.isRunning else {
                return .unavailable("Open Music to see its playlists.".l10n)
            }
            guard status.permission == .granted, let scripts = services.scripts else {
                return .unavailable("Allow access to Music in Settings › Sources to see its playlists.".l10n)
            }
            if case .success(let value) = await scripts.run(MusicAppScripts.playlistsScript) {
                return .playlists(MusicAppScripts.parsePlaylists(value))
            }
            return .unavailable("Music did not answer.".l10n)
        case .spotify:
            return .unavailable("The Spotify app does not share its playlists with other apps.".l10n)
        case .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube:
            guard let bridge = services.browserPlayback, let lists = await bridge.playlists(on: source) else {
                return .unavailable("Playlists from music sites need the Ahenk browser extension.".l10n)
            }
            return .playlists(lists)
        case .demo, .otherApp, .local:
            return .unavailable("Not available".l10n)
        }
    }

    func songs(of playlist: CatalogPlaylist, in source: MusicSource) async -> [CatalogSong] {
        if let demo, playlist.id.hasPrefix("demo:") { return demo.library.songs(ofPlaylist: playlist.id) }
        switch source {
        case .appleMusic:
            guard services.statuses[.appleMusic]?.hasFullAccess == true, let scripts = services.scripts,
                  let id = MusicAppScripts.persistentID(in: playlist.id),
                  let script = MusicAppScripts.playlistSongsScript(playlistID: id),
                  case .success(let value) = await scripts.run(script)
            else { return [] }
            return MusicAppScripts.parsePlaylistSongs(value)
        default:
            return await services.browserPlayback?.songs(ofPlaylist: playlist.id, on: source) ?? []
        }
    }

    /// The volume of the player that plays (`nil`: it has none Ahenk can
    /// read without asking).
    func volume(of source: MusicSource) async -> Double? {
        switch source {
        case .demo:
            return demo?.volume
        case .appleMusic, .spotify:
            guard services.statuses[source]?.hasFullAccess == true, let scripts = services.scripts else { return nil }
            let script = source == .appleMusic ? MusicAppScripts.volumeScript : SpotifyAppScripts.volumeScript
            guard case .success(let value) = await scripts.run(script) else { return nil }
            return MusicAppScripts.parseVolume(value)
        case .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube:
            return await services.browserPlayback?.volume(on: source)
        case .otherApp, .local:
            return nil
        }
    }

    func setVolume(_ volume: Double, of source: MusicSource) async {
        switch source {
        case .demo:
            demo?.setVolume(volume)
        case .appleMusic, .spotify:
            guard services.statuses[source]?.hasFullAccess == true, let scripts = services.scripts else { return }
            let script = source == .appleMusic ? MusicAppScripts.setVolumeScript(volume) : SpotifyAppScripts.setVolumeScript(volume)
            _ = await scripts.run(script)
        case .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube:
            await services.browserPlayback?.setVolume(volume, on: source)
        case .otherApp, .local:
            break
        }
    }

    /// Whether the volume control should show for the playing source.
    func hasVolume(_ source: MusicSource) -> Bool {
        switch source {
        case .demo: demo != nil
        case .appleMusic, .spotify: services.statuses[source]?.hasFullAccess == true
        case .youtubeMusic, .soundCloud, .amazonMusic, .deezer, .tidal, .spotifyWeb, .youtube: services.browserPlayback != nil
        case .otherApp, .local: false
        }
    }
}
