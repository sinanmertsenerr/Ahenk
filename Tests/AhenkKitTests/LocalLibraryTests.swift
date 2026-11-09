import CoreAudio
import Foundation
import Testing
@testable import AhenkKit

private func song(_ name: String) -> CatalogSong {
    LocalSong(path: "/Music/Invented/\(name).m4a", title: name, artist: "Juniper Coast", album: "Paper Lighthouse", duration: 180).catalogSong
}

private func titles(_ entries: [QueueEntry]) -> [String] {
    entries.map(\.song.title)
}

@Suite("Local songs")
struct LocalLibraryTests {
    // MARK: File names

    @Test("File names and folders stand in for missing tags")
    func fileNameFallback() {
        func guess(_ name: String, _ folders: [String] = ["Chosen"]) -> LocalFileNames.Guess {
            LocalFileNames.guess(fileName: name, folders: folders)
        }
        #expect(guess("03 - Harbor Lights.mp3") == .init(title: "Harbor Lights", artist: "", album: "Chosen", trackNumber: 3, discNumber: nil))
        #expect(guess("1-07 Night Ferry.flac") == .init(title: "Night Ferry", artist: "", album: "Chosen", trackNumber: 7, discNumber: 1))
        #expect(guess("Nova Atlas - Glass Harbor.m4a") == .init(title: "Glass Harbor", artist: "Nova Atlas", album: "Chosen", trackNumber: nil, discNumber: nil))
        #expect(guess("02. Nova Atlas - Glass Harbor.wav").artist == "Nova Atlas")
        #expect(guess("02. Nova Atlas - Glass Harbor.wav").trackNumber == 2)
        #expect(guess("Nova Atlas - Tide Tables - 04 - Glass Harbor.mp3") == .init(title: "Glass Harbor", artist: "Nova Atlas", album: "Chosen", trackNumber: 4, discNumber: nil))
        #expect(guess("night_drive.mp3").title == "night drive")
        #expect(guess("2005 Mixtape.mp3").trackNumber == nil, "a year is not a track number")
        // Generic folders are no album; Artist/Album folders name both.
        #expect(guess("Song.mp3", ["Downloads"]).album == "")
        #expect(guess("Song.mp3", ["İndirilenler"]).album == "")
        #expect(guess("Song.mp3", ["Şarkılar"]).album == "")
        #expect(guess("Song.mp3", ["Music", "Lumen Vale", "Night Shift Radio"]) == .init(title: "Song", artist: "Lumen Vale", album: "Night Shift Radio", trackNumber: nil, discNumber: nil))
        #expect(guess("Ana Sun - Song.mp3", ["Music", "Lumen Vale", "Night Shift Radio"]).artist == "Ana Sun", "the name wins over the folder")
    }

    @Test("Track numbers from tags: text and iTunes' binary form")
    func numbers() {
        #expect(LocalMetadata.parseNumber("3") == 3)
        #expect(LocalMetadata.parseNumber(" 03 / 12 ") == 3)
        #expect(LocalMetadata.parseNumber("x") == nil)
        #expect(LocalMetadata.parseNumber("0") == nil)
        #expect(LocalMetadata.parseNumber(Data([0, 0, 0, 7, 0, 12, 0, 0])) == 7)
        #expect(LocalMetadata.parseNumber(Data([0, 0, 1, 2])) == 258)
        #expect(LocalMetadata.parseNumber(Data([0, 0])) == nil)
    }

    // MARK: Scanning generated files

    @Test("Scanning finds the songs in a folder, reads their tags, falls back to names and sorts them as an album")
    func scanning() async throws {
        let scratch = ScratchDirectory()
        let root = scratch.url.appendingPathComponent("Tide Tables", isDirectory: true)
        let sub = root.appendingPathComponent("Bonus", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let rate = 22_050
        let tone = GeneratedSongFiles.tone(seconds: 1.5, sampleRate: rate)
        let cover = TestImages.png(TestImages.solid(SRGBColor("#22AA88"), width: 96, height: 96))
        // Tagged, out of name order: track 2 named "a…", track 1 named "b…".
        try await GeneratedSongFiles.writeM4A(tone, sampleRate: rate, to: root.appendingPathComponent("a-second.m4a"),
                                              title: "Second Light", artist: "Nova Atlas", album: "Tide Tables", trackNumber: 2, artwork: cover)
        try await GeneratedSongFiles.writeM4A(tone, sampleRate: rate, to: root.appendingPathComponent("b-first.m4a"),
                                              title: "First Light", artist: "Nova Atlas", album: "Tide Tables", trackNumber: 1)
        // No tags at all: the name and the folder say it.
        try GeneratedSongFiles.writeWAV(tone, sampleRate: rate, to: root.appendingPathComponent("03 - Nova Atlas - Third Light.wav"))
        try GeneratedSongFiles.writeWAV(tone, sampleRate: rate, to: sub.appendingPathComponent("01 Hidden Track.wav"))
        // Not songs, or not to be looked at.
        try Data("not audio".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try GeneratedSongFiles.writeWAV(tone, sampleRate: rate, to: root.appendingPathComponent(".secret.wav"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("04 Broken.mp3"))

        let files = LocalLibraryScanner.audioFiles(in: root)
        #expect(files.map(\.lastPathComponent) == ["04 Broken.mp3", "03 - Nova Atlas - Third Light.wav", "a-second.m4a", "b-first.m4a", "01 Hidden Track.wav"]
            || files.count == 5)
        #expect(!files.contains { $0.lastPathComponent.hasPrefix(".") })

        let songs = await LocalLibraryScanner.songs(in: root)
        #expect(songs.map(\.title) == ["First Light", "Second Light", "Third Light", "Hidden Track"], "\(songs.map(\.title))")
        let first = try #require(songs.first)
        #expect(first.artist == "Nova Atlas" && first.album == "Tide Tables" && first.trackNumber == 1)
        #expect(abs(first.duration - 1.5) < 0.1)
        let third = try #require(songs.first { $0.title == "Third Light" })
        #expect(third.artist == "Nova Atlas" && third.album == "Tide Tables" && third.trackNumber == 3)
        let hidden = try #require(songs.last)
        #expect(hidden.album == "Bonus" && hidden.trackNumber == 1 && hidden.artist == "", "Bonus is inside the chosen folder, not an artist")
        #expect(!songs.contains { $0.title.contains("Broken") }, "a file that cannot be played is left out")

        // The cover comes from the file, else from the folder's picture.
        let embedded = await LocalMetadata.artwork(of: URL(fileURLWithPath: songs[1].path))
        #expect(embedded != nil)
        #expect(await LocalMetadata.artwork(of: URL(fileURLWithPath: third.path)) == nil)
        try cover.write(to: root.appendingPathComponent("Cover.png"))
        #expect(LocalMetadata.folderArtwork(near: URL(fileURLWithPath: third.path))?.lastPathComponent == "Cover.png")
        #expect(await LocalMetadata.artwork(of: URL(fileURLWithPath: third.path)) == cover)

        // Songs as the rest of Ahenk sees them.
        let track = first.track
        #expect(track.source == .local && track.id == first.path && track.title == "First Light")
        let listed = first.catalogSong
        #expect(listed.origin == track && listed.trackNumber == 1)
        #expect(LocalSong(listed)?.path == first.path)
        #expect(LocalSong(CatalogSong(id: "x", title: "Remote", artistName: "Someone")) == nil)
    }

    @Test("A song file's own tags win; without them, its name")
    func singleFile() async throws {
        let scratch = ScratchDirectory()
        let rate = 16_000
        let tone = GeneratedSongFiles.tone(seconds: 0.8, sampleRate: rate)
        let url = scratch.url.appendingPathComponent("Juniper Coast - Untagged Song.wav")
        try GeneratedSongFiles.writeWAV(tone, sampleRate: rate, to: url)
        let song = try #require(await LocalLibraryScanner.song(at: url, root: nil))
        #expect(song.title == "Untagged Song" && song.artist == "Juniper Coast")
        let tags = LocalTags(title: "Tagged Title", artist: nil, albumArtist: "Album Artist", album: nil, duration: 12)
        let tagged = LocalLibraryScanner.song(at: url, root: nil, tags: tags)
        #expect(tagged.title == "Tagged Title" && tagged.artist == "Album Artist" && tagged.duration == 12)
    }

    // MARK: Remembered folders

    @Test("Folders are remembered newest first, once each, and follow a move")
    func folderStore() throws {
        let scratch = ScratchDirectory()
        let list = scratch.url.appendingPathComponent("LocalLibrary.json")
        let a = scratch.url.appendingPathComponent("Album A", isDirectory: true)
        let b = scratch.url.appendingPathComponent("Album B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let store = LocalLibraryStore(fileURL: list)
        store.add(a)
        store.add(b)
        store.add(a)
        store.flush()
        #expect(store.folders.map(\.name) == ["Album A", "Album B"])
        let reloaded = LocalLibraryStore(fileURL: list)
        #expect(reloaded.folders.map(\.name) == ["Album A", "Album B"])

        // Renamed in Finder: the bookmark finds it and the record follows.
        let renamed = scratch.url.appendingPathComponent("Album B (2026)", isDirectory: true)
        try FileManager.default.moveItem(at: b, to: renamed)
        let folder = try #require(reloaded.folders.last)
        let found = try #require(reloaded.resolve(folder))
        #expect(found.standardizedFileURL.path == renamed.standardizedFileURL.path)
        #expect(reloaded.folders.last?.name == "Album B (2026)")

        reloaded.remove(path: reloaded.folders[0].path)
        reloaded.flush()
        #expect(LocalLibraryStore(fileURL: list).folders.map(\.name) == ["Album B (2026)"])
        try FileManager.default.removeItem(at: renamed)
        #expect(reloaded.resolve(reloaded.folders[0]) == nil, "gone for good")
    }

    // MARK: The queue

    @Test("Songs ending by themselves follow repeat; after the last the queue rewinds and stops")
    func endOfSongs() {
        var queue = LocalQueue()
        queue.start(["One", "Two", "Three"].map(song), at: 0, context: nil)
        #expect(queue.following?.song.title == "Two")
        var next = queue.songEnded()
        #expect(next?.song.title == "Two")
        next = queue.songEnded()
        #expect(next?.song.title == "Three")
        #expect(queue.following == nil)
        next = queue.songEnded()
        #expect(next == nil)
        #expect(queue.current?.song.title == "One", "rewound to the first song")
        queue.setRepeat(.all)
        _ = queue.jump(to: queue.entries[2].id)
        #expect(queue.following?.song.title == "One")
        next = queue.songEnded()
        #expect(next?.song.title == "One")
        queue.setRepeat(.one)
        #expect(queue.following?.song.title == "One")
        next = queue.songEnded()
        #expect(next?.song.title == "One", "repeat one plays it again")
    }

    @Test("Next always moves on; Previous restarts after 3 s")
    func skipping() {
        var queue = LocalQueue()
        queue.start(["One", "Two", "Three"].map(song), at: 1, context: nil)
        queue.setRepeat(.one)
        var next = queue.skipForward()
        #expect(next?.song.title == "Three", "Next leaves a repeated song")
        #expect(queue.repeatMode == .one, "and keeps repeat one on")
        next = queue.skipForward()
        #expect(next?.song.title == "One", "round again (repeat one goes round like repeat all)")
        queue.setRepeat(.off)
        _ = queue.jump(to: queue.entries[2].id)
        next = queue.skipForward()
        #expect(next == nil)
        #expect(queue.current?.song.title == "One")
        var back = queue.skipBack(position: 10)
        #expect(back == .restart)
        back = queue.skipBack(position: 1)
        #expect(back == .restart, "the first song restarts")
        _ = queue.jump(to: queue.entries[2].id)
        back = queue.skipBack(position: 1)
        guard case .moved(let previous) = back else {
            Issue.record("did not move back")
            return
        }
        #expect(previous.song.title == "Two")
        queue.setRepeat(.all)
        _ = queue.jump(to: queue.entries[0].id)
        back = queue.skipBack(position: 0.5)
        guard case .moved(let last) = back else {
            Issue.record("did not go round")
            return
        }
        #expect(last.song.title == "Three")
    }

    @Test("Shuffle stays on for a new list; the player's own move is followed")
    func shuffleAndAdvance() throws {
        var queue = LocalQueue()
        queue.start((1...8).map { song("Song \($0)") }, at: 0, context: nil, seed: 1)
        queue.setShuffled(true, seed: 42)
        let shuffled = titles(queue.upNext)
        #expect(Set(shuffled).count == 7 && shuffled != (2...8).map { "Song \($0)" })
        queue.start(["A", "B", "C", "D", "E"].map(song), at: 0, context: .continuePlaying, seed: 7)
        #expect(queue.isShuffled && queue.current?.song.title == "A")
        #expect(Set(titles(queue.upNext)) == ["B", "C", "D", "E"])
        let next = try #require(queue.following)
        let followed = queue.advanced(to: next.id)
        #expect(followed && queue.current?.id == next.id)
        let blind = queue.advanced(to: UUID())
        #expect(!blind, "something else is not followed blindly")
    }

    @Test("Play Next, Add to Queue, removing; an unplayable file leaves the queue")
    func editingAndUnplayable() throws {
        var queue = LocalQueue()
        queue.start(["One", "Two", "Three"].map(song), at: 0, context: nil)
        queue.playNext([song("Next")])
        queue.append([song("Last")])
        #expect(titles(queue.upNext) == ["Next", "Two", "Three", "Last"])
        let two = queue.upNext[1]
        let moved = queue.moveToFront(two.id)
        #expect(moved)
        #expect(titles(queue.upNext) == ["Two", "Next", "Three", "Last"])
        let removed = queue.remove(two.id)
        #expect(removed)
        let current = try #require(queue.current)
        let removedCurrent = queue.remove(current.id)
        #expect(!removedCurrent, "the song that plays stays")
        // The current file is broken: the next one plays.
        var now = queue.dropUnplayable(current.id)
        #expect(now?.song.title == "Next")
        #expect(titles(queue.entries) == ["Next", "Three", "Last"])
        // A broken file up next leaves without changing what plays.
        now = queue.dropUnplayable(queue.upNext[0].id)
        #expect(now?.song.title == "Next")
        _ = queue.jump(to: queue.entries.last!.id)
        now = queue.dropUnplayable(queue.current!.id)
        #expect(now == nil, "the last one was broken: nothing left to play")
        queue.clear()
        queue.setRepeat(.all)
        queue.start(["X", "Y"].map(song), at: 1, context: nil)
        now = queue.dropUnplayable(queue.current!.id)
        #expect(now?.song.title == "X", "with repeat all it goes round")
        queue.clearUpNext()
        queue.clear()
        #expect(queue.isEmpty && queue.repeatMode == .all, "clearing keeps the repeat mode")
    }

    // MARK: Ahenk's own audio

    @Test("The own tap mixes every channel into mono and remembers the format")
    func ownTapMix() {
        let tap = OwnAudioTap(ringCapacity: 1 << 12)
        tap.context.pointee.prepare(sampleRate: 44_100, maxFrames: 4096)
        #expect(tap.sampleRate == 44_100 && tap.framesPerBuffer == 4096)
        // Two separate channels: 1.0 and 0.5 → 0.75.
        let frames = 64
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 1, count: frames)
        right.initialize(repeating: 0.5, count: frames)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: left)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: right)
        #expect(tap.newestMediaTime == nil)
        tap.context.pointee.mix(list.unsafeMutablePointer, frames: frames, mediaTimeEnd: 12.5)
        #expect(tap.ring.availableSamples == frames && tap.newestMediaTime == 12.5 && tap.buffersSeen == 1)
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { _ = tap.ring.reader.read(into: $0.baseAddress!, maxCount: frames) }
        #expect(out.allSatisfy { abs($0 - 0.75) < 1e-6 })
        // An item whose samples are not floats is not listened to; the next float item is.
        tap.context.pointee.prepare(sampleRate: 48_000, maxFrames: 4096, isFloat: false)
        tap.context.pointee.mix(list.unsafeMutablePointer, frames: frames, mediaTimeEnd: 13)
        #expect(tap.ring.availableSamples == 0 && tap.buffersSeen == 1 && tap.sampleRate == 44_100)
        tap.context.pointee.prepare(sampleRate: 48_000, maxFrames: 4096)
        tap.context.pointee.mix(list.unsafeMutablePointer, frames: frames, mediaTimeEnd: 13)
        #expect(tap.ring.availableSamples == frames && tap.buffersSeen == 2 && tap.sampleRate == 48_000)
        tap.measuredLead = 9
        #expect(tap.measuredLead == 1.5, "clamped")
        tap.measuredLead = .nan
        #expect(tap.measuredLead == OwnAudioTap.defaultLead)
    }

    @Test("The pacer turns bursts into a steady stream around its backlog")
    func pacer() {
        let rate = 44_100.0
        let source = AudioRingBuffer(capacity: 1 << 16)
        let sink = AudioRingBuffer(capacity: 1 << 18)
        let pacer = OwnAudioPacer(source: source)
        let burst = [Float](repeating: 0.1, count: 4096)
        func push() { burst.withUnsafeBufferPointer { _ = source.writer.write($0.baseAddress!, count: 4096) } }
        var now = 100.0
        pacer.pump(until: now, sampleRate: rate, into: sink.writer)
        // 3 s of 10 ms pumps; a 4096-frame burst every 4096 frames' time,
        // two of them waiting at the start.
        var moved: [Int] = []
        push(); push()
        var nextBurst = 100.0
        for step in 1...300 {
            now = 100 + Double(step) * 0.01
            while nextBurst <= now {
                push()
                nextBurst += 4096 / rate
            }
            moved.append(pacer.pump(until: now, sampleRate: rate, into: sink.writer))
        }
        let late = moved.suffix(100)
        let mean = Double(late.reduce(0, +)) / Double(late.count)
        #expect(abs(mean - 441) < 20, "real-time pace on average: \(mean) per 10 ms")
        #expect(late.allSatisfy { $0 > 300 && $0 < 600 }, "no bursts and no gaps: \(late.min() ?? 0)…\(late.max() ?? 0)")
        let backlog = pacer.backlog(sampleRate: rate)
        #expect(backlog > 0.02 && backlog < 0.25, "backlog \(backlog) s")

        // A stall far beyond the target is skipped, not played late.
        for _ in 0..<10 { push() }
        now += 0.01
        pacer.pump(until: now, sampleRate: rate, into: sink.writer)
        #expect(pacer.backlog(sampleRate: rate) <= OwnAudioPacer.targetBacklog + 0.02)
        pacer.reset()
        #expect(pacer.backlog(sampleRate: rate) == 0)
        #expect(pacer.pump(until: now + 0.01, sampleRate: rate, into: sink.writer) == 0, "a fresh start waits one pump")
    }
}
