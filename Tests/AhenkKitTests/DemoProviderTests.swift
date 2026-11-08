import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("DemoProvider")
struct DemoProviderTests {
    let clock = ManualClock()
    var songs: [DemoSong] { DemoCatalog.songs }

    private func makeProvider(playing: Bool = true) -> DemoProvider {
        DemoProvider(startPlaying: playing, clock: clock.function)
    }

    @Test("Starts with the first song at 0:00")
    func startsAtTheTop() {
        let provider = makeProvider()
        let snapshot = provider.snapshot()
        #expect(snapshot.track == songs[0].track)
        #expect(snapshot.elapsedTime == 0)
        #expect(snapshot.isPlaying)
        #expect(snapshot.track.source == .demo)
    }

    @Test("Position follows the clock and moves on to the next song")
    func advances() {
        let provider = makeProvider()
        clock.advance(10)
        #expect(provider.snapshot().elapsedTime == 10)
        clock.advance(songs[0].track.duration - 10 + 5)
        let snapshot = provider.snapshot()
        #expect(snapshot.track == songs[1].track)
        #expect(abs(snapshot.elapsedTime - 5) < 1e-9)
    }

    @Test("The playlist loops")
    func loops() {
        let provider = makeProvider()
        let total = songs.reduce(0) { $0 + $1.track.duration }
        clock.advance(total * 3 + 7)
        let snapshot = provider.snapshot()
        #expect(snapshot.track == songs[0].track)
        #expect(abs(snapshot.elapsedTime - 7) < 1e-6)
    }

    @Test("Pause freezes the position and silences the beat")
    func pause() async {
        let provider = makeProvider()
        clock.advance(12)
        await provider.perform(.pause)
        clock.advance(30)
        let snapshot = provider.snapshot()
        #expect(!snapshot.isPlaying)
        #expect(snapshot.elapsedTime == 12)
        #expect(provider.currentFeatures().isSilent)
        await provider.perform(.togglePlayPause)
        clock.advance(1)
        #expect(provider.snapshot().elapsedTime == 13)
        #expect(!provider.currentFeatures().isSilent)
    }

    @Test("Next, previous and seek")
    func transport() async {
        let provider = makeProvider()
        await provider.perform(.next)
        #expect(provider.snapshot().track == songs[1].track)
        clock.advance(10)
        await provider.perform(.previous)
        #expect(provider.snapshot().track == songs[1].track, "previous after 3 s restarts the song")
        #expect(provider.snapshot().elapsedTime == 0)
        await provider.perform(.previous)
        #expect(provider.snapshot().track == songs[0].track)
        await provider.perform(.previous)
        #expect(provider.snapshot().track == songs[songs.count - 1].track, "wraps backwards")
        await provider.perform(.seek(to: 30))
        #expect(provider.snapshot().elapsedTime == 30)
        await provider.perform(.seek(to: 10_000))
        #expect(provider.snapshot().elapsedTime < provider.snapshot().track.duration)
    }

    @Test("Repeat one loops the same song")
    func repeatOne() async {
        let provider = makeProvider()
        await provider.perform(.setRepeat(.one))
        clock.advance(songs[0].track.duration + 4)
        let snapshot = provider.snapshot()
        #expect(snapshot.track == songs[0].track)
        #expect(abs(snapshot.elapsedTime - 4) < 1e-9)
        #expect(snapshot.repeatMode == .one)
    }

    @Test("Shuffle keeps the current song and visits every song once per loop")
    func shuffle() async {
        let provider = makeProvider()
        await provider.perform(.next)
        await provider.perform(.setShuffle(true))
        #expect(provider.snapshot().track == songs[1].track)
        #expect(provider.snapshot().isShuffled == true)
        var seen: [String] = []
        for _ in songs {
            seen.append(provider.snapshot().track.id)
            await provider.perform(.next)
        }
        #expect(Set(seen).count == songs.count)
        await provider.perform(.setShuffle(false))
        #expect(provider.snapshot().isShuffled == false)
    }

    @Test("Liking marks the current song")
    func like() async {
        let provider = makeProvider()
        await provider.perform(.setLiked(true))
        #expect(provider.snapshot().isLiked == true)
        await provider.perform(.next)
        #expect(provider.snapshot().isLiked == false)
        await provider.perform(.previous)
        #expect(provider.snapshot().isLiked == true)
    }

    @Test("Streams yield the current song, then every command")
    func stream() async {
        let provider = makeProvider()
        var iterator = provider.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first??.track == songs[0].track)
        await provider.perform(.next)
        let second = await iterator.next()
        #expect(second??.track == songs[1].track)
        await provider.perform(.pause)
        let third = await iterator.next()
        #expect(third??.isPlaying == false)
    }

    @Test("Streams announce a natural song change when the song ends")
    func streamBoundary() async throws {
        // Real clock: the first song is sought to its last 0.2 s.
        let provider = DemoProvider()
        await provider.perform(.seek(to: DemoCatalog.songs[0].track.duration - 0.2))
        var iterator = provider.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first??.track == songs[0].track)
        let next = await iterator.next()
        #expect(next??.track == songs[1].track)
    }

    @Test("Lyrics match by title and artist")
    func lyrics() async throws {
        let provider = makeProvider()
        let song = songs[2]
        let result = try await provider.fetch(LyricsQuery(track: song.track))
        #expect(result == .synced(song.lyrics))
        let upper = try await provider.fetch(LyricsQuery(title: song.track.title.uppercased(), artist: song.track.artist))
        #expect(upper.hasLyrics)
        #expect(try await provider.fetch(LyricsQuery(title: "Unknown", artist: "Nobody")) == .notFound)
    }

    @Test("Artwork is generated once per size and carries the palette")
    func artwork() async throws {
        let provider = makeProvider()
        let track = songs[0].track
        let first = try #require(await provider.artwork(for: track, pixelSize: 128))
        let again = try #require(await provider.artwork(for: track, pixelSize: 128))
        #expect(first.pixelWidth == 128 && first.pixelHeight == 128)
        #expect(first.image === again.image, "cached")
        #expect(first.palette == songs[0].palette)
        let other = Track(id: "x", source: .spotify, title: "x", artist: "y")
        #expect(await provider.artwork(for: other, pixelSize: 128) == nil)
    }

    @Test("Features follow the song position at 120 BPM")
    func features() {
        let provider = makeProvider()
        clock.advance(10.25)
        let features = provider.currentFeatures()
        #expect(features == DemoBeat.features(at: 10.25))
        #expect(features.bpm == 120)
        #expect(features.beatIndex == 20)
    }
}

@Suite("Demo content")
struct DemoContentTests {
    @Test("Songs are well formed")
    func catalog() {
        let songs = DemoCatalog.songs
        #expect(songs.count >= 4)
        #expect(Set(songs.map(\.track.id)).count == songs.count)
        for song in songs {
            #expect(song.track.source == .demo)
            #expect(song.track.duration >= 60)
            #expect(song.palette.colors.count == 3, "\(song.track.title) has three colours")
            let lines = song.lyrics.lines
            #expect(!lines.isEmpty)
            #expect(lines.map(\.start) == lines.map(\.start).sorted())
            #expect(lines.allSatisfy { $0.start > 0 && ($0.end ?? 0) <= song.track.duration })
            #expect(lines.allSatisfy { !$0.text.isEmpty })
            // Every song has an instrumental break of at least 8 s for the countdown.
            let gaps = zip(lines, lines.dropFirst()).map { $1.start - ($0.end ?? $0.start) }
            #expect(gaps.contains { $0 >= 8 }, "\(song.track.title) has an instrumental break")
        }
    }

    @Test("Beat lands every half second")
    func beatGrid() {
        for beat in 0..<16 {
            let onBeat = DemoBeat.features(at: Double(beat) * 0.5)
            #expect(onBeat.beatIndex == beat)
            #expect(onBeat.beatPhase < 1e-9)
            #expect(onBeat.beat > 0.8, "the pulse peaks on the beat")
            let later = DemoBeat.features(at: Double(beat) * 0.5 + 0.4)
            #expect(later.beat < onBeat.beat, "and decays before the next one")
            #expect(later.beatIndex == beat)
        }
    }

    @Test("Levels stay in range")
    func ranges() {
        for step in 0..<400 {
            let f = DemoBeat.features(at: Double(step) * 0.137)
            #expect(!f.isSilent && f.bpm == 120)
            for value in [f.level, f.bass, f.mid, f.treble, f.onset, f.beat, f.beatPhase] {
                #expect(value >= 0 && value <= 1)
            }
            for band in 0..<AudioFeatures.bandCount {
                #expect(f.bands[band] >= 0 && f.bands[band] <= 1)
            }
        }
    }

    @Test("Bass leads on the beat, treble on the off-beat")
    func bandShape() {
        let onBeat = DemoBeat.features(at: 8.0)
        let offBeat = DemoBeat.features(at: 8.25)
        #expect(onBeat.bass > offBeat.bass)
        #expect(offBeat.treble > onBeat.treble)
        #expect(onBeat.bands[0] > onBeat.bands[15])
    }

    @Test("Artwork is deterministic per seed")
    func artworkDeterminism() throws {
        let palette = DemoCatalog.songs[0].palette
        let a = try #require(DemoArtwork.makeImage(palette: palette, seed: 1, pixelSize: 64))
        let b = try #require(DemoArtwork.makeImage(palette: palette, seed: 1, pixelSize: 64))
        let c = try #require(DemoArtwork.makeImage(palette: palette, seed: 2, pixelSize: 64))
        #expect(pixels(a) == pixels(b))
        #expect(pixels(a) != pixels(c))
        let tiny = try #require(DemoArtwork.makeImage(palette: palette, seed: 1, pixelSize: 1))
        #expect(tiny.width == DemoArtwork.pixelSizeRange.lowerBound)
    }

    @Test("Artwork is not a flat colour")
    func artworkHasDetail() throws {
        let image = try #require(DemoArtwork.makeImage(palette: DemoCatalog.songs[1].palette, seed: 9, pixelSize: 64))
        let bytes = pixels(image)
        #expect(Set(bytes).count > 50)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }
}
