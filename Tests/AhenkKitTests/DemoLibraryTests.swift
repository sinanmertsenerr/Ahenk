import Foundation
import Testing
@testable import AhenkKit

@Suite("Demo library")
struct DemoLibraryTests {
    let library = DemoLibrary.standard

    @Test("Every artist has releases with songs; the starting songs are part of it")
    func wellFormed() {
        #expect(library.artists.count >= 6)
        #expect(Set(library.songs.map(\.track.id)).count == library.songs.count)
        for original in DemoCatalog.songs {
            #expect(library.demoSong(id: original.track.id) == original)
        }
        for artist in library.artists {
            let albums = library.albums(ofArtist: artist.id)
            #expect(albums.count >= 2, "\(artist.name)")
            for album in albums {
                let songs = library.songs(ofAlbum: album.id)
                #expect(!songs.isEmpty && songs.count == album.trackCount)
                #expect(songs.allSatisfy { $0.artistName == artist.name && $0.albumID == album.id && $0.artwork == album.artwork })
                #expect(songs.map(\.trackNumber) == Array(1...songs.count).map { Optional($0) })
                #expect(album.year != nil)
            }
        }
        for song in library.songs {
            #expect(song.track.duration >= 60)
            #expect(song.lyrics.lines.allSatisfy { ($0.end ?? 0) <= song.track.duration && !$0.text.isEmpty })
        }
        for playlist in library.playlists {
            #expect(library.songs(ofPlaylist: playlist.id).count == playlist.songCount)
            #expect((playlist.songCount ?? 0) >= 6)
        }
    }

    @Test("Search ignores case, accents and the Turkish dotless i")
    func search() async throws {
        let catalog = DemoMusicCatalog()
        let artists = try await catalog.search("kiyi", limit: 10).artists
        #expect(artists.first?.name == "Kıyı Sinyali")
        let songs = try await catalog.search("AY ISIGI", limit: 10).songs
        #expect(songs.first?.title == "Ay Işığı Hattı")
        let harbor = try await catalog.search("harbor", limit: 20)
        #expect(harbor.songs.first?.title.lowercased().hasPrefix("harbor") == true || harbor.albums.first?.title == "Harbor Static")
        #expect(try await catalog.search("   ", limit: 5).isEmpty)
        #expect(try await catalog.search("zzqq nothing", limit: 5).isEmpty)
    }

    @Test("The playing demo song finds its artist, album and the artist's albums")
    func artistOfSong() async throws {
        let catalog = DemoMusicCatalog()
        let track = DemoCatalog.songs[0].track
        let match = try #require(try await catalog.artist(for: track))
        #expect(match.artist.name == track.artist)
        #expect(match.albumID == "demo:album:low-tide-lights")
        #expect(match.song?.id == track.id)
        let albums = try await catalog.albums(of: match.artist)
        #expect(albums.count >= 5)
        #expect(albums.map(\.year) == albums.map(\.year).sorted { ($0 ?? 0) < ($1 ?? 0) })
        let top = try await catalog.topSongs(of: match.artist, limit: 8)
        #expect(top.count == 8 && Set(top.map(\.id)).count == 8)
    }

    @Test("The demo plays a library song alone and stops at its end")
    func playsOneSong() async throws {
        let clock = ManualClock()
        let provider = DemoProvider(clock: clock.function)
        let song = try #require(library.demoSong(id: "demo:orbitals"))
        provider.play(song)
        #expect(provider.snapshot().track == song.track)
        #expect(provider.snapshot().isPlaying)
        clock.advance(song.track.duration - 1)
        #expect(provider.snapshot().isPlaying)
        clock.advance(5)
        let ended = provider.snapshot()
        #expect(!ended.isPlaying && ended.track == song.track && ended.elapsedTime == song.track.duration)
        #expect(provider.currentFeatures().isSilent)
        await provider.perform(.play)
        #expect(provider.snapshot().isPlaying && provider.snapshot().elapsedTime == 0, "Play at the end starts again")
        let artwork = await provider.artwork(for: song.track, pixelSize: 64)
        #expect(artwork?.palette == song.palette)
        #expect(try await provider.fetch(LyricsQuery(track: song.track)) == .synced(song.lyrics))
        provider.setVolume(1.7)
        #expect(provider.volume == 1)
    }

    @Test("A start delay keeps the old song until the new one starts")
    func startDelay() async throws {
        let provider = DemoProvider()
        let song = try #require(library.demoSong(id: "demo:cedar-smoke"))
        let before = provider.snapshot().track
        provider.play(song, startDelay: 0.15)
        #expect(provider.snapshot().track == before)
        #expect(await eventually { provider.snapshot().track == song.track })
    }
}
