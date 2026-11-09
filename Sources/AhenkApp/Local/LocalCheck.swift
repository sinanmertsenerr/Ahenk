import AhenkKit
import AppKit

/// Smoke check `localPlayback`: a folder of generated tones (two tagged
/// M4A files and an untagged WAV at another rate) is scanned, played muted
/// through the local player and the Local source, and Ahenk's own audio
/// reaches the analysis (features, beats) without any process tap or
/// permission; next, seek and pause are carried out. The folder lives in a
/// temporary directory and is deleted; nothing is heard.
@MainActor
enum LocalCheck {
    static func run() async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-smoke-songs-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Smoke Tones", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let tone = GeneratedSongFiles.tone(seconds: 6, sampleRate: 44_100, bpm: 120, frequency: 330)
        try await GeneratedSongFiles.writeM4A(tone, sampleRate: 44_100, to: folder.appendingPathComponent("first.m4a"),
                                              title: "Generated One", artist: "Ahenk Tones", album: "Smoke Tones", trackNumber: 1)
        try await GeneratedSongFiles.writeM4A(GeneratedSongFiles.tone(seconds: 6, sampleRate: 44_100, frequency: 392), sampleRate: 44_100,
                                              to: folder.appendingPathComponent("second.m4a"),
                                              title: "Generated Two", artist: "Ahenk Tones", album: "Smoke Tones", trackNumber: 2)
        try GeneratedSongFiles.writeWAV(GeneratedSongFiles.tone(seconds: 4, sampleRate: 48_000, frequency: 440), sampleRate: 48_000,
                                        to: folder.appendingPathComponent("03 - Ahenk Tones - Generated Three.wav"))

        let songs = await LocalLibraryScanner.songs(in: folder)
        guard songs.map(\.title) == ["Generated One", "Generated Two", "Generated Three"], songs.allSatisfy({ $0.artist == "Ahenk Tones" }) else {
            throw SmokeFailure("the scan found \(songs.map(\.title))")
        }

        // The player (silent), the Local source in a hub of its own, and
        // the analysis as the app runs it.
        let tap = OwnAudioTap()
        let player = LocalPlayer(tap: tap, publishesNowPlaying: false, muted: true)
        defer { player.shutdown() }
        let hub = NowPlayingHub(inputs: [.provider(LocalPlaybackProvider(engine: player.engine), priority: HubInput.dedicatedPriority)])
        hub.start()
        defer { hub.stop() }
        let store = AudioFeatureStore()
        let capture = AudioCaptureController(store: store, demo: nil, ownAudio: tap)
        defer { capture.stop() }
        let follow = Task.detached {
            for await snapshot in hub.snapshots() { capture.update(snapshot: snapshot) }
        }
        defer { follow.cancel() }

        func wait(_ what: String, seconds: Double = 4, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("\(what) within \(Int(seconds)) s") }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let started = Date()
        player.play(songs.map(\.catalogSong), at: 0, context: .folder(path: folder.path, name: folder.lastPathComponent))
        try await wait("the first song did not start") {
            let snapshot = hub.currentState.activeSnapshot
            return snapshot?.isPlaying == true && snapshot?.track.title == "Generated One" && snapshot?.track.source == .local
        }
        let startup = Date().timeIntervalSince(started)
        let firstBeat = store.currentFeatures().beatIndex
        try await wait("Ahenk's own audio did not reach the analysis", seconds: 5) {
            let features = store.currentFeatures()
            return !features.isSilent && features.energy > 0.05 && features.beatIndex > firstBeat
        }
        let heard = store.currentFeatures()
        guard tap.sampleRate == 44_100, tap.buffersSeen > 0 else { throw SmokeFailure("the tap saw no audio") }

        // Next, a seek, a pause.
        _ = await hub.perform(.next)
        try await wait("Next did not play the second song") { hub.currentState.activeSnapshot?.track.title == "Generated Two" }
        _ = await hub.perform(.seek(to: 3))
        try await wait("the seek did not land") {
            guard let snapshot = hub.currentState.activeSnapshot else { return false }
            return abs(snapshot.elapsed(at: Date()) - 3) < 0.6
        }
        _ = await hub.perform(.pause)
        try await wait("the pause did not take") { hub.currentState.activeSnapshot?.isPlaying == false }
        try await wait("the analysis did not fall silent after the pause", seconds: 2) { store.currentFeatures().isSilent }

        return "3 generated songs scanned (tags and a file name); the first played muted through the Local source in "
            + "\(Int(startup * 1000)) ms; Ahenk's own audio reached the analysis (\(Int(tap.sampleRate)) Hz, energy "
            + "\(String(format: "%.2f", heard.energy)), beats counted) with no process tap; next, seek and pause carried out"
    }
}
