import Foundation
import Testing
@testable import AhenkKit

@Suite("Audio capture policy")
struct AudioCapturePolicyTests {
    private func song(
        _ bundle: String? = KnownApps.spotify, source: MusicSource = .spotify, playing: Bool = true,
        kind: ContentKind = .music, pid: Int32? = 501
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: Track(id: "t", source: source, title: "Glass Harbor", artist: "Nova Atlas"),
            bundleIdentifier: bundle, processIdentifier: pid, elapsedTime: 0, playbackRate: playing ? 1 : 0,
            timestamp: Date(timeIntervalSinceReferenceDate: 0), contentKind: kind
        )
    }

    private func authorized() -> AudioCapturePolicy {
        var policy = AudioCapturePolicy()
        policy.update(permission: .authorized, now: 0)
        return policy
    }

    private var spotify: AudioTapTarget { AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: 501) }

    @Test("Ahenk's own player is heard from inside, with or without the permission")
    func ownPlayback() {
        let local = AudioTapTarget(source: .local, bundleIdentifier: KnownApps.ahenk, processIdentifier: 77)
        for permission in [AudioCapturePermission.notDetermined, .denied, .unknown, .authorized] {
            var policy = AudioCapturePolicy()
            policy.update(permission: permission, now: 0)
            policy.update(snapshot: song(KnownApps.ahenk, source: .local, pid: 77), now: 1)
            #expect(policy.request == .own(local), "permission \(permission)")
            #expect(policy.isGateOpen && policy.state == .listening(.own(local)))
            // A pause closes the gate; the grace period works as for a tap.
            policy.update(snapshot: song(KnownApps.ahenk, source: .local, playing: false, pid: 77), now: 2)
            #expect(!policy.isGateOpen && policy.request == .own(local))
            policy.tick(now: 2 + policy.configuration.idleGrace)
            #expect(policy.request == nil)
        }
        // Spotify starts while the permission is missing: nothing to hear.
        var policy = AudioCapturePolicy()
        policy.update(permission: .notDetermined, now: 0)
        policy.update(snapshot: song(KnownApps.ahenk, source: .local, pid: 77), now: 1)
        policy.update(snapshot: song(), now: 2)
        #expect(policy.request == nil && policy.state == .needsPermission)
        // Digital silence never sends Ahenk's own audio elsewhere.
        var own = authorized()
        own.update(snapshot: song(KnownApps.ahenk, source: .local, pid: 77), now: 1)
        own.noteDigitalSilence(10, now: 5)
        #expect(own.request == .own(local))
    }

    @Test("Playing music opens the gate and asks for the player's app")
    func playing() {
        var policy = authorized()
        #expect(policy.request == nil && policy.state == .idle)
        policy.update(snapshot: song(), now: 1)
        #expect(policy.request == .app(spotify))
        #expect(policy.isGateOpen)
        #expect(policy.state == .listening(.app(spotify)))
    }

    @Test("A pause closes the gate at once and releases the tap after the grace period")
    func pause() {
        var policy = authorized()
        policy.update(snapshot: song(), now: 1)
        policy.update(snapshot: song(playing: false), now: 10)
        #expect(!policy.isGateOpen)
        #expect(policy.request == .app(spotify), "the tap stays for a moment")
        #expect(policy.nextDeadline == 10 + policy.configuration.idleGrace)
        policy.tick(now: 10 + policy.configuration.idleGrace - 0.1)
        #expect(policy.request != nil)
        policy.tick(now: 10 + policy.configuration.idleGrace)
        #expect(policy.request == nil)
        #expect(policy.state == .idle)
        #expect(policy.nextDeadline == nil, "nothing runs while idle")
    }

    @Test("Playing again within the grace period keeps the same tap")
    func resume() {
        var policy = authorized()
        policy.update(snapshot: song(), now: 1)
        policy.update(snapshot: song(playing: false), now: 2)
        policy.update(snapshot: song(), now: 5)
        #expect(policy.request == .app(spotify) && policy.isGateOpen)
        #expect(policy.nextDeadline == nil)
    }

    @Test("Videos, podcasts and adverts never open the gate", arguments: [ContentKind.video, .podcast, .advertisement])
    func notMusic(kind: ContentKind) {
        var policy = authorized()
        policy.update(snapshot: song(KnownApps.search, source: .otherApp, kind: kind), now: 1)
        #expect(policy.request == nil && !policy.isGateOpen)
        #expect(policy.state == .notMusic)
        // Music, then a video in the same app: gate closes, tap released later.
        policy.update(snapshot: song(), now: 2)
        #expect(policy.isGateOpen)
        policy.update(snapshot: song(kind: kind), now: 3)
        #expect(!policy.isGateOpen)
        #expect(policy.state == .notMusic)
    }

    @Test("Unlabelled players count as music, except on YouTube")
    func unknownContent() {
        #expect(AudioCapturePolicy.reactsTo(song(KnownApps.search, source: .otherApp, kind: .unknown)))
        #expect(!AudioCapturePolicy.reactsTo(song(KnownApps.search, source: .youtube, kind: .unknown)))
        #expect(AudioCapturePolicy.reactsTo(song(KnownApps.search, source: .youtubeMusic, kind: .unknown)))
    }

    @Test("Another player starting retargets the tap")
    func retarget() {
        var policy = authorized()
        policy.update(snapshot: song(), now: 1)
        policy.update(snapshot: song(KnownApps.search, source: .youtubeMusic, pid: 900), now: 2)
        let browser = AudioTapTarget(source: .youtubeMusic, bundleIdentifier: KnownApps.search, processIdentifier: 900)
        #expect(policy.request == .app(browser) && policy.isGateOpen)
        // A paused new player does not take the tap over during the grace.
        policy.update(snapshot: song(playing: false), now: 3)
        #expect(policy.request == .app(browser))
        #expect(!policy.isGateOpen)
    }

    @Test("Without permission nothing is tapped", arguments: [AudioCapturePermission.notDetermined, .denied])
    func noPermission(permission: AudioCapturePermission) {
        var policy = AudioCapturePolicy()
        policy.update(permission: permission, now: 0)
        policy.update(snapshot: song(), now: 1)
        #expect(policy.request == nil && !policy.isGateOpen)
        #expect(policy.state == (permission == .denied ? .denied : .needsPermission))
        policy.update(permission: .authorized, now: 2)
        #expect(policy.request == .app(spotify) && policy.isGateOpen)
    }

    @Test("An unreadable permission listens only after the user allows it")
    func unknownPermission() {
        var policy = AudioCapturePolicy()
        policy.update(snapshot: song(), now: 1)
        #expect(policy.request == nil && policy.state == .needsPermission)
        policy.allowListening(now: 2)
        #expect(policy.request == .app(spotify))
    }

    @Test("An app whose audio cannot be found falls back to everything but Ahenk")
    func unresolved() {
        var policy = authorized()
        policy.update(snapshot: song(), now: 1)
        policy.noteUnresolved(now: 1)
        #expect(policy.request == .app(spotify), "a helper may still be starting")
        #expect(policy.nextDeadline == 1 + policy.configuration.unresolvedFallback)
        policy.tick(now: 1 + policy.configuration.unresolvedFallback)
        #expect(policy.request == .everything(spotify))
        #expect(policy.isGateOpen)
        // A new player starts over with its own app.
        policy.update(snapshot: song(KnownApps.appleMusic, source: .appleMusic, pid: 600), now: 10)
        #expect(policy.request == .app(AudioTapTarget(source: .appleMusic, bundleIdentifier: KnownApps.appleMusic, processIdentifier: 600)))
    }

    @Test("A player without an app name goes straight to everything")
    func anonymous() {
        var policy = authorized()
        policy.update(snapshot: song(nil, source: .otherApp, pid: nil), now: 1)
        #expect(policy.request == .everything(AudioTapTarget(source: .otherApp, bundleIdentifier: nil, processIdentifier: nil)))
    }

    @Test("A silent tap is resolved again once, then falls back to everything")
    func silentTap() {
        var policy = authorized()
        policy.update(snapshot: song(), now: 1)
        let generation = policy.resolveGeneration
        policy.noteDigitalSilence(1, now: 2)
        #expect(policy.resolveGeneration == generation)
        policy.noteDigitalSilence(policy.configuration.silenceRetarget, now: 4)
        #expect(policy.resolveGeneration == generation + 1)
        #expect(policy.request == .app(spotify))
        policy.noteDigitalSilence(policy.configuration.silenceRetarget + 1, now: 5)
        #expect(policy.resolveGeneration == generation + 1, "only once")
        policy.noteDigitalSilence(policy.configuration.silenceFallback, now: 7)
        #expect(policy.request == .everything(spotify))
        // While paused, silence is expected and changes nothing.
        var paused = authorized()
        paused.update(snapshot: song(), now: 1)
        paused.update(snapshot: song(playing: false), now: 2)
        paused.noteDigitalSilence(30, now: 3)
        #expect(paused.request == .app(spotify))
    }

    @Test("Failing to build the tap backs off before trying again")
    func failures() {
        var policy = authorized()
        policy.update(snapshot: song(), now: 0)
        policy.noteTapFailed(now: 0)
        #expect(policy.request == nil && policy.state == .retrying)
        #expect(policy.nextDeadline == 2)
        policy.tick(now: 2)
        #expect(policy.request == .app(spotify))
        policy.noteTapFailed(now: 2)
        #expect(policy.nextDeadline == 7)
        policy.tick(now: 7)
        policy.noteTapStarted(now: 7)
        #expect(policy.request == .app(spotify) && policy.nextDeadline == nil)
    }

    @Test("The demo plays its synthesizer without any permission")
    func demo() {
        var policy = AudioCapturePolicy(requiresPermission: false)
        policy.update(snapshot: song(nil, source: .demo, pid: nil), now: 0)
        #expect(policy.request == .demo && policy.isGateOpen)
    }
}

@Suite("Audio process matching")
struct AudioProcessMatcherTests {
    static let own: Int32 = 4_000

    private func ids(_ target: AudioTapTarget, appPIDs: Set<Int32>, _ processes: [AudioProcess]) -> [UInt32] {
        AudioProcessMatcher.processes(for: target, appPIDs: appPIDs, in: processes, ownPID: Self.own).map(\.objectID)
    }

    @Test("The app itself, by PID or bundle identifier")
    func exact() {
        let processes = [
            AudioProcess(objectID: 1, pid: 501, bundleIdentifier: KnownApps.spotify, responsiblePID: 501, ancestors: [1]),
            AudioProcess(objectID: 2, pid: 777, bundleIdentifier: "com.apple.Music", responsiblePID: 777, ancestors: [1]),
        ]
        let target = AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: nil)
        #expect(ids(target, appPIDs: [501], processes) == [1])
        #expect(ids(target, appPIDs: [], processes) == [1], "the bundle identifier alone")
    }

    @Test("Chromium helpers belong to their browser by ancestry")
    func chromiumHelpers() {
        let chrome: Int32 = 300
        let processes = [
            AudioProcess(objectID: 10, pid: chrome, bundleIdentifier: "com.google.Chrome", responsiblePID: chrome, ancestors: [1]),
            AudioProcess(objectID: 11, pid: 310, bundleIdentifier: "com.google.Chrome.helper", responsiblePID: chrome, ancestors: [chrome, 1], isRunningOutput: true),
            AudioProcess(objectID: 12, pid: 320, bundleIdentifier: "com.google.Chrome.helper", responsiblePID: nil, ancestors: [chrome, 1]),
            // Another Chrome profile's helper with a similar name but no tie.
            AudioProcess(objectID: 13, pid: 330, bundleIdentifier: "com.google.Chrome.helper", responsiblePID: 900, ancestors: [900, 1]),
        ]
        let target = AudioTapTarget(source: .youtubeMusic, bundleIdentifier: "com.google.Chrome", processIdentifier: chrome)
        #expect(ids(target, appPIDs: [chrome], processes) == [10, 11, 12])
    }

    @Test("WebKit's GPU process belongs to the browser responsible for it")
    func webKit() {
        let search: Int32 = 90_522
        let processes = [
            AudioProcess(objectID: 103, pid: 90_528, bundleIdentifier: AudioProcessMatcher.webKitAudioProcess, responsiblePID: search, ancestors: [1], isRunningOutput: true),
            AudioProcess(objectID: 104, pid: search, bundleIdentifier: KnownApps.search, responsiblePID: search, ancestors: [1]),
            // Mail's own GPU process.
            AudioProcess(objectID: 105, pid: 91_000, bundleIdentifier: AudioProcessMatcher.webKitAudioProcess, responsiblePID: 600, ancestors: [1]),
        ]
        let target = AudioTapTarget(source: .otherApp, bundleIdentifier: KnownApps.search, processIdentifier: search)
        #expect(ids(target, appPIDs: [search], processes) == [103, 104])
    }

    @Test("Without responsibility, Safari still gets WebKit's GPU process")
    func webKitFallback() {
        let safari: Int32 = 700
        let processes = [
            AudioProcess(objectID: 1, pid: safari, bundleIdentifier: KnownApps.safari, ancestors: [1]),
            AudioProcess(objectID: 2, pid: 710, bundleIdentifier: AudioProcessMatcher.webKitAudioProcess, ancestors: [1]),
        ]
        let target = AudioTapTarget(source: .youtubeMusic, bundleIdentifier: KnownApps.safari, processIdentifier: nil)
        #expect(ids(target, appPIDs: [safari], processes) == [1, 2])
        // Other apps do not get it by name alone.
        let other = AudioTapTarget(source: .otherApp, bundleIdentifier: "com.example.player", processIdentifier: nil)
        #expect(ids(other, appPIDs: [800], processes).isEmpty)
    }

    @Test("The publishing process counts even when it is a helper")
    func publisher() {
        let processes = [AudioProcess(objectID: 5, pid: 1_234, bundleIdentifier: AudioProcessMatcher.webKitAudioProcess, responsiblePID: 1_234, ancestors: [1])]
        let target = AudioTapTarget(source: .otherApp, bundleIdentifier: KnownApps.safari, processIdentifier: 1_234)
        #expect(ids(target, appPIDs: [], processes) == [5])
    }

    @Test("Ahenk's own processes are never tapped and are left out of the global tap")
    func ahenk() {
        let processes = [
            AudioProcess(objectID: 1, pid: Self.own, bundleIdentifier: "com.sinanmertsener.Ahenk", responsiblePID: Self.own, ancestors: [1]),
            AudioProcess(objectID: 2, pid: 4_010, bundleIdentifier: AudioProcessMatcher.webKitAudioProcess, responsiblePID: Self.own, ancestors: [1]),
            AudioProcess(objectID: 3, pid: 4_020, bundleIdentifier: nil, responsiblePID: nil, ancestors: [Self.own, 1]),
            AudioProcess(objectID: 4, pid: 501, bundleIdentifier: KnownApps.spotify, responsiblePID: 501, ancestors: [1]),
        ]
        let target = AudioTapTarget(source: .otherApp, bundleIdentifier: "com.sinanmertsener.Ahenk", processIdentifier: Self.own)
        #expect(ids(target, appPIDs: [Self.own], processes).isEmpty)
        #expect(AudioProcessMatcher.ahenkProcesses(in: processes, ownPID: Self.own).map(\.objectID) == [1, 2, 3])
    }
}

@Suite("Audio capture permission")
struct AudioCapturePermissionTests {
    @Test("TCC preflight answers map to permission states")
    func preflight() {
        #expect(AudioCapturePermission(preflightResult: 0) == .authorized)
        #expect(AudioCapturePermission(preflightResult: 1) == .denied)
        #expect(AudioCapturePermission(preflightResult: 2) == .notDetermined)
        #expect(AudioCapturePermission(preflightResult: -1) == .unknown)
        #expect(AudioCapturePermission(preflightResult: 7) == .unknown)
    }
}
