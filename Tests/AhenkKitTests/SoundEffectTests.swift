import Foundation
import Testing
@testable import AhenkKit

@Suite("Sound effects")
struct SoundEffectTests {
    private func song(
        _ bundle: String? = KnownApps.spotify, source: MusicSource = .spotify, kind: ContentKind = .music, pid: Int32? = 501
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: Track(id: "t", source: source, title: "Paper Lanterns", artist: "Mira Solen"),
            bundleIdentifier: bundle, processIdentifier: pid, elapsedTime: 0, playbackRate: 1,
            timestamp: Date(timeIntervalSinceReferenceDate: 0), contentKind: kind
        )
    }

    private func route(
        _ snapshot: NowPlayingSnapshot?, enabled: Bool = true, permission: AudioCapturePermission = .authorized,
        demo: Bool = false, taps: Bool = true, everything: Bool = false
    ) -> SoundEffectRoute {
        SoundEffectRouter.route(
            enabled: enabled, snapshot: snapshot, permission: permission, isDemo: demo, tapsSupported: taps, hearsEverything: everything
        )
    }

    // MARK: Presets and the chain

    @Test("Switched off, the chain does nothing whatever the sliders say")
    func offIsNeutral() {
        var settings = SoundEffectSettings()
        settings.select(.slowedReverb)
        #expect(!settings.enabled)
        #expect(SoundEffectChain(settings) == .neutral)
        #expect(SoundEffectChain(settings).isNeutral)
        settings.enabled = true
        #expect(!SoundEffectChain(settings).isNeutral)
        settings.reset()
        #expect(settings.enabled && SoundEffectChain(settings).isNeutral)
    }

    @Test("Choosing a preset puts its values into the sliders")
    func presetsFillTheSliders() {
        var settings = SoundEffectSettings()
        settings.enabled = true
        settings.select(.nightcore)
        #expect(settings.preset == .nightcore && settings.speed == 1.25 && settings.pitch == 4 && settings.reverb == 0)
        #expect(settings.equalizerEnabled && settings.matchesPreset)
        var chain = SoundEffectChain(settings)
        #expect(chain.speed == 1.25 && chain.pitchCents == 400 && chain.changesSpeed && chain.shiftsPitch && !chain.reverberates)

        settings.select(.slowedReverb)
        chain = SoundEffectChain(settings)
        #expect(chain.speed == 0.85 && chain.pitchCents == -300 && chain.reverbMix == 0.45 && chain.space == .largeHall)

        settings.select(.bassBoost)
        chain = SoundEffectChain(settings)
        #expect(chain.speed == 1 && chain.pitchCents == 0 && chain.equalizerGains[0] == 8 && chain.equalizerGains[9] == 0)
        #expect(chain.headroom < 0, "boosted bands get headroom")

        settings.select(.eightD)
        chain = SoundEffectChain(settings)
        #expect(chain.orbits && chain.orbit?.period == 8 && !settings.equalizerEnabled && !chain.equalizes)

        settings.select(.echo)
        chain = SoundEffectChain(settings)
        #expect(chain.echoes && chain.echo?.delay == 0.32 && !chain.orbits)
    }

    @Test("Sliders moved after a preset keep its echo and orbit; Custom drops them and keeps the sliders")
    func editingAPreset() {
        var settings = SoundEffectSettings()
        settings.enabled = true
        settings.select(.eightD)
        settings.reverb = 0.6
        #expect(!settings.matchesPreset)
        #expect(SoundEffectChain(settings).orbits && SoundEffectChain(settings).reverbMix == 0.6)
        settings.select(.custom)
        #expect(settings.reverb == 0.6 && settings.matchesPreset)
        #expect(!SoundEffectChain(settings).orbits)
    }

    @Test("Every preset but Custom changes something, stays inside the sliders' ranges and has ten bands")
    func presetsAreSane() {
        for preset in SoundPreset.allCases {
            let recipe = preset.recipe
            #expect(SoundEffectSettings.speedRange.contains(recipe.speed), "\(preset)")
            #expect(SoundEffectSettings.pitchRange.contains(recipe.pitch), "\(preset)")
            #expect(SoundEffectSettings.reverbRange.contains(recipe.reverb), "\(preset)")
            #expect(recipe.bands.count == 10 && recipe.bands.allSatisfy { SoundEffectSettings.gainRange.contains($0) }, "\(preset)")
            var settings = SoundEffectSettings()
            settings.enabled = true
            settings.select(preset)
            #expect(SoundEffectChain(settings).isNeutral == (preset == .custom), "\(preset)")
            #expect(preset.changesSpeed == (recipe.speed != 1))
        }
        #expect(SoundPreset.allCases.filter(\.changesSpeed) == [.nightcore, .slowedReverb, .vaporwave])
        #expect(SoundPreset.allCases.count >= 9)
    }

    @Test("A player without a speed keeps its own; the pitch still shifts")
    func speedNeedsAPlayerThatTakesIt() {
        var settings = SoundEffectSettings()
        settings.enabled = true
        settings.select(.nightcore)
        let chain = SoundEffectChain(settings)
        #expect(chain.adapted(to: .ownPlayer).speed == 1.25)
        #expect(chain.adapted(to: .browserTab).speed == 1.25)
        let fixed = chain.adapted(to: .none)
        #expect(fixed.speed == 1 && fixed.pitchCents == 400 && !fixed.changesSpeed && fixed.processesSound)
    }

    @Test("Values outside the ranges are clamped on the way into the chain")
    func chainClamps() {
        var settings = SoundEffectSettings()
        settings.enabled = true
        settings.speed = 9
        settings.pitch = -40
        settings.reverb = 3
        settings.equalizerEnabled = true
        settings.equalizerBands = [40, -40, 1]
        let chain = SoundEffectChain(settings)
        #expect(chain.speed == 2 && chain.pitchCents == -1200 && chain.reverbMix == 1)
        #expect(chain.equalizerGains == [12, -12, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(SoundEcho(delay: 9, feedback: 2, mix: -1) == SoundEcho(delay: 2, feedback: 0.9, mix: 0))
    }

    // MARK: The orbit

    @Test("The orbit moves the sound from ear to ear at even loudness")
    func orbit() {
        let rate = 8_000.0
        let frames = Int(rate * 8)
        var left = [Float](repeating: 0.5, count: frames)
        var right = [Float](repeating: 0.5, count: frames)
        var orbiter = SoundOrbiter(orbit: SoundOrbit(period: 8, depth: 1))
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                orbiter.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames, sampleRate: rate)
            }
        }
        // A quarter of the way round: all the way right; three quarters: left.
        let quarter = Int(rate * 2)
        #expect(right[quarter] > 0.69 && abs(left[quarter]) < 0.02)
        #expect(left[quarter * 3] > 0.69 && abs(right[quarter * 3]) < 0.02)
        // In the middle both ears hear the same.
        #expect(abs(left[0] - right[0]) < 0.01 && abs(left[0] - 0.5) < 0.01)
        // Equal power all the way.
        for index in stride(from: 0, to: frames, by: 997) {
            let power = left[index] * left[index] + right[index] * right[index]
            #expect(abs(power - 0.5) < 0.01)
        }
        #expect(abs(orbiter.phase - 0) < 0.001 || abs(orbiter.phase - 1) < 0.001, "one full trip")
    }

    @Test("A shallow orbit keeps some of each side; none at all leaves the sound alone")
    func shallowOrbit() {
        var left: [Float] = [1, 1, 1, 1]
        var right: [Float] = [0, 0, 0, 0]
        var still = SoundOrbiter(orbit: SoundOrbit(period: 8, depth: 0))
        still.process(left: &left, right: &right, frames: 4, sampleRate: 48_000)
        #expect(left == [1, 1, 1, 1] && right == [0, 0, 0, 0])
        var shallow = SoundOrbiter(orbit: SoundOrbit(period: 8, depth: 0.5))
        shallow.process(left: &left, right: &right, frames: 4, sampleRate: 48_000)
        #expect(left[0] > right[0] && right[0] > 0, "the left channel stays more on the left")
    }

    // MARK: Routing

    @Test("Song files go through Ahenk's own chain, with or without the permission")
    func ownPlayer() {
        let local = song(KnownApps.ahenk, source: .local, pid: 77)
        for permission in AudioCapturePermission.allCases {
            #expect(route(local, permission: permission) == .ownPlayer)
        }
        #expect(route(local, demo: true) == .ownPlayer)
        #expect(SoundEffectRouter.speedControl(for: local, tabTakesRate: false) == .ownPlayer)
    }

    @Test("Another app goes through a muting tap, only with the permission")
    func otherApps() {
        let spotify = song()
        #expect(route(spotify) == .tap(AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: 501)))
        #expect(route(spotify, permission: .unknown).isAvailable)
        #expect(route(spotify, permission: .denied) == .unavailable(.permissionDenied))
        #expect(route(spotify, permission: .notDetermined) == .unavailable(.needsPermission))
        #expect(route(spotify, taps: false) == .unavailable(.needsNewerSystem))
        #expect(route(spotify, everything: true) == .unavailable(.notHeardSeparately))
        #expect(route(song(nil, pid: nil)) == .unavailable(.unknownPlayer))
        #expect(route(song(kind: .video)) == .unavailable(.notMusic))
        #expect(route(spotify, enabled: false) == .off)
        #expect(route(nil) == .off)
        #expect(route(spotify, demo: true) == .demo)
        #expect(SoundEffectRouter.speedControl(for: spotify, tabTakesRate: false) == .none)
        #expect(SoundEffectRouter.speedControl(for: song("com.google.Chrome", source: .youtubeMusic), tabTakesRate: true) == .browserTab)
        #expect(SoundEffectRouter.speedControl(for: nil, tabTakesRate: true) == .none)
    }

    @Test("Effects are switched off when another player is followed, not between songs or tabs")
    func playerChanges() {
        let spotify = SoundEffectRouter.playerKey(song())
        let sameAppNextSong = SoundEffectRouter.playerKey(song(pid: 909))
        let music = SoundEffectRouter.playerKey(song(KnownApps.appleMusic, source: .appleMusic))
        #expect(!SoundEffectRouter.mustSwitchOff(enabledFor: spotify, now: sameAppNextSong))
        #expect(SoundEffectRouter.mustSwitchOff(enabledFor: spotify, now: music))
        #expect(!SoundEffectRouter.mustSwitchOff(enabledFor: spotify, now: nil), "nothing followed for a while")
        #expect(!SoundEffectRouter.mustSwitchOff(enabledFor: nil, now: music))
        #expect(SoundEffectRouter.playerKey(nil) == nil)
    }

    // MARK: What a tap may silence

    @Test("A tap mutes only the app the effects were asked for, and only while Ahenk plays the sound")
    func tapRule() {
        let spotify = AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: 501)
        let restarted = AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: 777)
        let music = AudioTapTarget(source: .appleMusic, bundleIdentifier: KnownApps.appleMusic, processIdentifier: 12)
        #expect(SoundEffectTapRule.mutes(request: .app(spotify), tapsProcesses: true, effectsFor: spotify, outputRuns: true))
        #expect(SoundEffectTapRule.mutes(request: .app(restarted), tapsProcesses: true, effectsFor: spotify, outputRuns: true))
        #expect(!SoundEffectTapRule.mutes(request: .app(spotify), tapsProcesses: true, effectsFor: spotify, outputRuns: false))
        #expect(!SoundEffectTapRule.mutes(request: .app(spotify), tapsProcesses: true, effectsFor: nil, outputRuns: true))
        #expect(!SoundEffectTapRule.mutes(request: .app(music), tapsProcesses: true, effectsFor: spotify, outputRuns: true))
        #expect(!SoundEffectTapRule.mutes(request: .app(spotify), tapsProcesses: false, effectsFor: spotify, outputRuns: true))
    }

    @Test("The tap on every app, the demo and Ahenk's own player are never muted")
    func neverMuted() {
        let spotify = AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: 501)
        for tapsProcesses in [true, false] {
            #expect(!SoundEffectTapRule.mutes(request: .everything(spotify), tapsProcesses: tapsProcesses, effectsFor: spotify, outputRuns: true))
            #expect(!SoundEffectTapRule.mutes(request: .demo, tapsProcesses: tapsProcesses, effectsFor: spotify, outputRuns: true))
            #expect(!SoundEffectTapRule.mutes(request: .own(spotify), tapsProcesses: tapsProcesses, effectsFor: spotify, outputRuns: true))
            #expect(!SoundEffectTapRule.wantsMute(request: .everything(spotify), tapsProcesses: tapsProcesses, effectsFor: spotify))
        }
        #expect(SoundEffectTapRule.wantsMute(request: .app(spotify), tapsProcesses: true, effectsFor: spotify))
    }
}
