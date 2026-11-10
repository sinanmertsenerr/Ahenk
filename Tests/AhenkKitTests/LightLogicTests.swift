import CoreGraphics
import Foundation
import Testing
@testable import AhenkKit

@Suite("Edge light fade")
struct LightFadeTests {
    @Test("Fades in, holds, fades out and goes idle")
    func fullCycle() {
        var fade = LightFade.music()
        #expect(fade.isIdle && fade.value == 0)
        fade.set(on: true)
        fade.advance(to: 10)
        #expect(fade.phase == .fadingIn && fade.value == 0)
        fade.advance(to: 10.4)
        #expect(fade.phase == .fadingIn && fade.value > 0.3 && fade.value < 0.7)
        fade.advance(to: 11)
        #expect(fade.phase == .on && fade.value == 1)
        fade.set(on: false)
        fade.advance(to: 11.8)
        #expect(fade.phase == .fadingOut && fade.value > 0 && fade.value < 1)
        fade.advance(to: 12.7)
        #expect(fade.isIdle && fade.value == 0)
    }

    @Test("Turning around in the middle continues from where the fade is")
    func reversesWithoutJumping() {
        var fade = LightFade(fadeIn: 1, fadeOut: 1)
        fade.set(on: true)
        fade.advance(to: 0)
        fade.advance(to: 0.5)
        let before = fade.value
        fade.set(on: false)
        fade.advance(to: 0.5)
        #expect(fade.value == before)
        fade.advance(to: 0.6)
        #expect(fade.value < before && fade.value > before - 0.25)
    }

    @Test("Time going backwards or a reset clock changes nothing")
    func clockSafety() {
        var fade = LightFade(fadeIn: 1, fadeOut: 1)
        fade.set(on: true)
        fade.advance(to: 5)
        fade.advance(to: 4)
        #expect(fade.progress == 0)
        fade.advance(to: 5.5)
        let progress = fade.progress
        fade.resetClock()
        fade.advance(to: 100)
        #expect(fade.progress == progress)
        let instant = { () -> LightFade in
            var f = LightFade(fadeIn: 0, fadeOut: 0)
            f.set(on: true)
            f.advance(to: 1)
            f.advance(to: 1.001)
            return f
        }()
        #expect(instant.value == 1)
    }

    @Test("Stepping aside is quicker than the music fading out")
    func durations() {
        #expect(LightFade.presence().fadeOut < LightFade.music().fadeOut)
        #expect(LightFade.music().fadeOut >= 1 && LightFade.music().fadeOut <= 2)
        #expect(LightFade.music(isOn: true).value == 1)
    }
}

@Suite("Edge light frame policy")
struct LightFramePolicyTests {
    @Test("Visible and on power: 60 fps, full quality")
    func normal() {
        let plan = LightFramePolicy.plan(LightFrameInputs(maximumFramesPerSecond: 120))
        #expect(plan.framesPerSecond == 60 && plan.quality == .full && plan.resolutionScale == 1 && plan.reason == .normal)
        #expect(LightFramePolicy.plan(LightFrameInputs(maximumFramesPerSecond: 50)).framesPerSecond == 50)
    }

    @Test("Hidden screens get no frames at all")
    func hidden() {
        let plan = LightFramePolicy.plan(LightFrameInputs(isOnBattery: true, isVisible: false))
        #expect(plan.isPaused && plan.reason == .hidden)
    }

    @Test("Battery, Low Power Mode and heat run lighter")
    func lighter() {
        let cases: [(LightFrameInputs, LightFramePlan.Reason)] = [
            (LightFrameInputs(isOnBattery: true), .battery),
            (LightFrameInputs(isLowPowerMode: true), .lowPowerMode),
            (LightFrameInputs(isThermallyConstrained: true), .thermal),
            (LightFrameInputs(lighterOnBattery: false, isThermallyConstrained: true), .thermal),
        ]
        for (inputs, reason) in cases {
            let plan = LightFramePolicy.plan(inputs)
            #expect(plan.framesPerSecond == 30 && plan.quality == .light && plan.resolutionScale == 0.5 && plan.reason == reason)
        }
    }

    @Test("Without “run lighter on battery”, battery and Low Power Mode keep full quality")
    func batteryOptOut() {
        let plan = LightFramePolicy.plan(LightFrameInputs(lighterOnBattery: false, isOnBattery: true, isLowPowerMode: true))
        #expect(plan.framesPerSecond == 60 && plan.quality == .full)
        #expect(LightQuality.full.shaderValue == 1 && LightQuality.light.shaderValue == 0)
    }
}

@Suite("Edge light colours")
struct LightColorTests {
    @Test("Colours fill four slots without a flat stretch")
    func slots() {
        let a = SRGBColor("#FF0000"), b = SRGBColor("#00FF00"), c = SRGBColor("#0000FF"), d = SRGBColor("#FFFFFF")
        #expect(LightColors(colors: [a]).slots == [a, a, a, a])
        #expect(LightColors(colors: [a, b]).slots == [a, b, a, b])
        #expect(LightColors(colors: [a, b, c]).slots == [a, b, c, b])
        #expect(LightColors(colors: [a, b, c, d, a]).slots == [a, b, c, d])
        #expect(LightColors(colors: []).slots.count == 4)
    }

    @Test("Sources: the album's vivid palette, the user's colours, the rainbow")
    func sources() {
        let palette = Palette(colors: [SRGBColor("#0E5E6F"), SRGBColor("#FF7A6B"), SRGBColor("#FFD9A0")])
        let album = LightColors.resolve(source: .album, album: palette, custom: [])
        #expect(album.slots == LightColors(colors: palette.vivid).slots && !album.isRainbow)
        let fallback = LightColors.resolve(source: .album, album: nil, custom: [])
        #expect(fallback.slots == LightColors(colors: Palette.neutral.vivid).slots)
        let custom = LightColors.resolve(source: .custom, album: palette, custom: [SRGBColor("#112233")])
        #expect(custom.slots == Array(repeating: SRGBColor("#112233"), count: 4))
        #expect(LightColors.resolve(source: .custom, album: nil, custom: []).slots == LightColors(colors: LightSettings().customColors).slots)
        #expect(LightColors.resolve(source: .rainbow, album: palette, custom: []).isRainbow)
    }

    @Test("A new palette blends in over the crossfade, then holds")
    func crossfade() {
        let from = LightColors(colors: [SRGBColor("#FF0000")])
        let to = LightColors(colors: [SRGBColor("#0000FF")])
        var fade = PaletteCrossfade(from, duration: 1)
        #expect(fade.colors(at: 0) == from.slots)
        fade.set(to, at: 10)
        // The blend starts where it was (through OKLab: equal to 8 bits).
        #expect(fade.colors(at: 10).map(\.hex) == from.slots.map(\.hex))
        let middle = fade.colors(at: 10.5)[0]
        #expect(middle != from.slots[0] && middle != to.slots[0])
        #expect(middle.red < 1 && middle.blue > 0)
        #expect(fade.colors(at: 11) == to.slots && fade.isSettled(at: 11))
        #expect(!fade.isSettled(at: 10.99))
    }

    @Test("Changing palette mid-blend starts from the colours on screen")
    func retarget() {
        let red = LightColors(colors: [SRGBColor("#FF0000")])
        let blue = LightColors(colors: [SRGBColor("#0000FF")])
        let green = LightColors(colors: [SRGBColor("#00FF00")])
        var fade = PaletteCrossfade(red, duration: 1)
        fade.set(blue, at: 0)
        let onScreen = fade.colors(at: 0.5)[0]
        fade.set(green, at: 0.5)
        let after = fade.colors(at: 0.5)[0]
        #expect(abs(after.red - onScreen.red) < 0.01 && abs(after.blue - onScreen.blue) < 0.01)
        #expect(fade.target == green)
        // Setting the same colours again changes nothing.
        fade.set(green, at: 0.7)
        #expect(fade.colors(at: 1.5) == green.slots)
    }
}

@Suite("Edge light motion")
struct LightMotionTests {
    static func run(_ motion: inout LightMotion, from start: Double, seconds: Double, speed: Double = 1, features: (Double) -> AudioFeatures) {
        var t = 0.0
        while t <= seconds {
            motion.advance(to: start + t, features: features(t), speed: speed)
            t += 1.0 / 60
        }
    }

    @Test("Kicks push the light forward; silence only drifts")
    func kicksPush() {
        var music = LightMotion()
        Self.run(&music, from: 100, seconds: 8) { DemoBeat.features(at: $0) }
        var quiet = LightMotion()
        Self.run(&quiet, from: 100, seconds: 8) { _ in .silence }
        // Travel wraps at one lap; 8 s of silence at the base pace is 0.24 laps.
        #expect(abs(quiet.travel - LightMotion.travelBase * 8) < 0.01)
        let musicTravel = music.travel + (music.travel < quiet.travel ? 1 : 0)
        #expect(musicTravel > quiet.travel + 0.05)
        #expect(music.drift > quiet.drift)
        // The demo beat's loudness averages about 0.2.
        #expect(quiet.swell == 0 && music.swell > 0.1)
    }

    @Test("Every beat is remembered, newest first, with its age")
    func beatHistory() {
        var motion = LightMotion()
        Self.run(&motion, from: 50, seconds: 2.1) { DemoBeat.features(at: $0) }
        #expect(motion.beats.count == 4)
        let ages = motion.beatAges(at: 52.1)
        #expect(ages[0] < ages[1] && ages[1] < ages[2] && ages[2] < ages[3])
        // 120 BPM: half a second apart.
        #expect(abs((ages[1] - ages[0]) - 0.5) < 0.05)
        #expect(motion.beatStrengths[0] >= 0.4)
        #expect(motion.beatSeeds[0] != motion.beatSeeds[1])
    }

    @Test("Without beats, soft ones are made up at a calm pace")
    func madeUpBeats() {
        var motion = LightMotion()
        Self.run(&motion, from: 0, seconds: 6) { _ in .silence }
        #expect(motion.beats.count >= 2 && motion.beats.count <= 4)
        #expect(motion.beats.allSatisfy { $0.strength == 0.45 })
        let ages = motion.beatAges(at: 6)
        #expect(ages[1] - ages[0] >= Float(LightMotion.idleBeatInterval) - 0.05)
        #expect(LightMotion().beatAges(at: 0) == SIMD4(repeating: LightMotion.noBeatAge))
    }

    @Test("A long sleep counts as a quarter second; the first frame only starts the clock")
    func sleeps() {
        var motion = LightMotion()
        motion.advance(to: 10, features: .silence, speed: 1)
        #expect(motion.drift == 0 && motion.travel == 0)
        motion.advance(to: 1000, features: .silence, speed: 1)
        #expect(abs(motion.drift - 0.25) < 1e-9)
        motion.advance(to: 999, features: .silence, speed: 1)
        #expect(abs(motion.drift - 0.25) < 1e-9)
    }
}
