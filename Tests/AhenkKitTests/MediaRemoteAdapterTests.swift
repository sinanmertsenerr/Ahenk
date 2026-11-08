import Foundation
import Testing
@testable import AhenkKit

/// Runs the adapter plumbing against small `/bin/sh` scripts that stand in
/// for the perl adapter (same arguments, invented output). Nothing here
/// touches MediaRemote or any real player.
@Suite("MediaRemote adapter process", .serialized)
struct MediaRemoteAdapterTests {
    /// `sh -c <script> adapter <command…>`: the command arrives as $1, $2, …
    private func adapter(_ script: String) -> MediaRemoteAdapter {
        MediaRemoteAdapter(invocation: .init(executable: URL(fileURLWithPath: "/bin/sh"), baseArguments: ["-c", script, "adapter"]))
    }

    private static let musicLine = #"{"type":"data","diff":false,"payload":{"processIdentifier":321,"bundleIdentifier":"com.apple.Music","title":"Glass Harbor","artist":"Nova Atlas","album":"Low Tide Lights","durationMicros":92000000,"elapsedTimeMicros":5000000,"timestampEpochMicros":1782323000000000,"playing":true}}"#
    private static let pauseLine = #"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0}}"#

    @Test("The stream decodes every line and ends with the process")
    func stream() async {
        let script = "[ \"$1\" = stream ] || exit 9; printf '%s\\n' '\(Self.musicLine)' '\(Self.pauseLine)'"
        let payloads = await collect(adapter(script).stream(), count: 5, timeout: .seconds(5))
        #expect(payloads.count == 2)
        #expect(payloads.first?.title == "Glass Harbor")
        #expect(payloads.first?.isPlaying == true)
        #expect(payloads.last?.isPlaying == false)
        #expect(payloads.last?.title == "Glass Harbor", "the diff kept the title")
    }

    @Test("Commands report the adapter's exit status")
    func commands() async {
        let reader = adapter("[ \"$1\" = send ] && [ \"$2\" = 2 ] && exit 0; [ \"$1\" = seek ] && [ \"$2\" = 15000000 ] && exit 0; exit 3")
        #expect(await reader.run(.send(.togglePlayPause)))
        #expect(await reader.run(MediaRemoteRequest(.seek(to: 15))!))
        #expect(!(await reader.run(.send(.nextTrack))))
        #expect(reader.runningProcessCount == 0)
    }

    @Test("A hung command is stopped after its timeout")
    func commandTimeout() async {
        let started = Date()
        let ok = await adapter("exec sleep 30").run(.send(.play), timeout: 0.3)
        #expect(!ok)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("get returns the payload, or an empty one when nothing plays")
    func current() async throws {
        let playing = adapter("[ \"$1\" = get ] || exit 9; printf '%s\\n' '{\"title\":\"Glass Harbor\",\"artist\":\"Nova Atlas\",\"playing\":true,\"artworkData\":\"AQID\"}'")
        let payload = try #require(await playing.current())
        #expect(payload.title == "Glass Harbor")
        #expect(payload.artworkData == Data([1, 2, 3]))
        let idle = try #require(await adapter("printf 'null\\n'").current())
        #expect(idle.isEmpty)
        #expect(await adapter("exit 1").current() == nil)
    }

    @Test("terminateAll stops a running stream")
    func terminateAll() async {
        let reader = adapter("printf '%s\\n' '\(Self.musicLine)'; exec sleep 30")
        let stream = reader.stream()
        let first = await collect(stream, count: 1)
        #expect(first.first?.title == "Glass Harbor")
        #expect(reader.runningProcessCount == 1)
        reader.terminateAll()
        #expect(reader.runningProcessCount == 0)
    }

    @Test("A missing executable ends the stream at once")
    func missingExecutable() async {
        let reader = MediaRemoteAdapter(invocation: .init(executable: URL(fileURLWithPath: "/nonexistent/perl"), baseArguments: []))
        let items = await collect(reader.stream(), count: 1, timeout: .seconds(2))
        #expect(items.isEmpty)
        #expect(await reader.current() == nil)
    }

    @Test("The provider maps payloads to snapshots and restarts a dead adapter")
    func providerRestarts() async throws {
        let scratch = ScratchDirectory()
        let counter = scratch.url.appendingPathComponent("runs").path
        let reader = adapter("echo run >> '\(counter)'; printf '%s\\n' '\(Self.musicLine)'")
        let provider = MediaRemoteProvider(adapter: reader)
        let snapshots = provider.snapshots()
        provider.start()
        let received = await collect(snapshots, count: 2, timeout: .seconds(5))
        #expect(received.first == .some(nil), "nothing until the adapter speaks")
        let snapshot = try #require(received.last ?? nil)
        #expect(snapshot.track.title == "Glass Harbor")
        #expect(snapshot.track.source == .appleMusic)
        #expect(snapshot.processIdentifier == 321)
        // The script exits right away; the provider starts it again.
        let deadline = Date().addingTimeInterval(5)
        var runs = 0
        while Date() < deadline {
            runs = ((try? String(contentsOfFile: counter, encoding: .utf8)) ?? "").split(separator: "\n").count
            if runs >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(runs >= 2)
        provider.stop()
        #expect(provider.health == .stopped)
        #expect(reader.runningProcessCount == 0)
    }

    @Test("Provider commands need a song that supports them")
    func providerCommands() async {
        let scratch = ScratchDirectory()
        let log = scratch.url.appendingPathComponent("commands").path
        let script = """
        if [ "$1" = stream ]; then printf '%s\\n' '\(Self.musicLine)'; exec sleep 30; fi
        echo "$1 $2" >> '\(log)'
        """
        let reader = adapter(script)
        let provider = MediaRemoteProvider(adapter: reader)
        #expect(!(await provider.perform(.pause)), "nothing plays yet")
        let snapshots = provider.snapshots()
        provider.start()
        _ = await collect(snapshots, count: 2)
        #expect(await provider.perform(.pause))
        #expect(await provider.perform(.seek(to: 30)))
        #expect(!(await provider.perform(.setShuffle(true))), "the player published no shuffle mode")
        #expect(!(await provider.perform(.setLiked(false))))
        let commands = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(commands == ["send 1", "seek 30000000"])
        provider.stop()
    }
}
