import Foundation
import Testing
@testable import AhenkKit

@Suite("Music app scripts")
struct PlayerScriptTests {
    @Test("Play scripts check their IDs and quote text")
    func playScripts() throws {
        let library = try #require(MusicAppScripts.playLibraryTrack(persistentID: "0A1B2C3D4E5F6071"))
        #expect(library.contains(#"whose persistent ID is "0A1B2C3D4E5F6071""#))
        #expect(library.hasPrefix(#"if application id "com.apple.Music" is running then"#))
        #expect(MusicAppScripts.playLibraryTrack(persistentID: "not hex") == nil)
        let inPlaylist = try #require(MusicAppScripts.playLibraryTrack(persistentID: "ABC", playlistID: "DEF"))
        #expect(inPlaylist.contains(#"first user playlist whose persistent ID is "DEF""#))
        let match = MusicAppScripts.playLibraryMatch(title: #"Say "Hi" (feat. Mira Sol)"#, artist: "Juniper\\Coast", album: "Paper Lighthouse - Single")
        #expect(match.contains(#"for "Say \"Hi\"" only songs"#))
        #expect(match.contains(#""Juniper\\Coast""#))
        #expect(match.contains(#"starts with "Paper Lighthouse""#))
        #expect(MusicAppScripts.quoted("a\nb\tc") == "\"a b c\"")
        let spotify = try #require(SpotifyAppScripts.playTrack(id: "0AbCdEfGhIjKlMnOpQrStU", context: "spotify:album:1AbCdEfGhIjKlMnOpQrStU"))
        #expect(spotify.contains(#"play track "spotify:track:0AbCdEfGhIjKlMnOpQrStU" in context "spotify:album:1AbCdEfGhIjKlMnOpQrStU""#))
        #expect(spotify.hasPrefix(#"if application id "com.spotify.client" is running then"#))
        #expect(SpotifyAppScripts.playTrack(id: "short") == nil)
        #expect(SpotifyAppScripts.playTrack(id: "0AbCdEfGhIjKlMnOpQrStU", context: "spotify:album:\" & quit") == nil)
        #expect(SpotifyAppScripts.trackID(in: "spotify:track:0AbCdEfGhIjKlMnOpQrStU") == "0AbCdEfGhIjKlMnOpQrStU")
        #expect(MusicAppScripts.setVolumeScript(0.456).contains("set sound volume to 46"))
        #expect(SpotifyAppScripts.setVolumeScript(7).contains("set sound volume to 100"))
    }

    @Test("Answers: play results, playlists, their songs and the volume")
    func parsing() {
        #expect(ScriptPlayResult.parse(.list([.text("played"), .text("0A1B")])) == .played(id: "0A1B"))
        #expect(ScriptPlayResult.parse(.list([.text("notfound")])) == .notFound)
        #expect(ScriptPlayResult.parse(.list([.text("notrunning")])) == .notRunning)
        #expect(ScriptPlayResult.parse(.missing) == .unreadable)
        let playlists = MusicAppScripts.parsePlaylists(.list([
            .list([.text("Morning Coffee"), .text("1a2b3c4d5e6f7081"), .number(24)]),
            .list([.text(""), .text("1111"), .number(1)]),
            .list([.text("Broken"), .text("zz-top"), .number(3)]),
        ]))
        #expect(playlists == [CatalogPlaylist(id: "music:playlist:1A2B3C4D5E6F7081", name: "Morning Coffee", songCount: 24)])
        let songs = MusicAppScripts.parsePlaylistSongs(.list([
            .list([.text("Third Window"), .text("Harbor Bells")]),
            .list([.text("Juniper Coast"), .text("Juniper Coast")]),
            .list([.text("Paper Lighthouse"), .text("Paper Lighthouse")]),
            .list([.number(201.5), .number(187)]),
            .list([.text("00000000000000AA"), .text("not an id")]),
        ]))
        #expect(songs.count == 1)
        #expect(songs[0].origin == Track(id: "music:00000000000000AA", source: .appleMusic, title: "Third Window", artist: "Juniper Coast", album: "Paper Lighthouse", duration: 201.5))
        #expect(songs[0].originID(in: .appleMusic) == "music:00000000000000AA")
        #expect(MusicAppScripts.persistentID(in: songs[0].origin!.id) == "00000000000000AA")
        #expect(MusicAppScripts.persistentID(in: "music:playlist:1A2B") == "1A2B")
        #expect(MusicAppScripts.parseVolume(.number(65)) == 0.65)
        #expect(MusicAppScripts.parseVolume(.missing) == nil)
    }

    @Test("Links for songs Music or Spotify cannot be told to play")
    func links() throws {
        let song = CatalogSong(
            id: "itunes:song:9990001", title: "Harbor Bells (feat. Mira Sol)", artistName: "Juniper Coast", albumTitle: "Paper Lighthouse",
            url: URL(string: "https://music.apple.com/us/album/harbor-bells/7770003?i=9990001")
        )
        #expect(MusicAppScripts.catalogPageURL(for: song)?.absoluteString == "music://music.apple.com/us/album/harbor-bells/7770003?i=9990001")
        #expect(SpotifyAppScripts.searchURI(for: song)?.absoluteString == "spotify:search:Juniper%20Coast%20Harbor%20Bells")
        var elsewhere = song
        elsewhere.url = URL(string: "https://example.com/x")
        #expect(MusicAppScripts.catalogPageURL(for: elsewhere) == nil)
    }
}
