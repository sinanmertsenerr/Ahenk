import AhenkKit
import AVFoundation

/// Smoke check `soundEffects`: the effects chain run on generated tones
/// through the very processor Ahenk's own player calls, buffer by buffer,
/// with the result measured, never played: the untouched chain returns the
/// input, the equalizer lifts the band it should, the pitch moves a tone an
/// octave, the echo and the reverb leave sound after a burst ended, the
/// orbit carries a tone from ear to ear, and every preset renders. Also the
/// rules that keep a tap from muting anything it must not, and that this
/// run cannot mute or play at all.
@MainActor
enum EffectsCheck {
    static let rate = 44_100.0

    static func run(environment: AppEnvironment) async throws -> String {
        // 1. Nothing to do: the sound passes untouched.
        let tone = sine(440, seconds: 1)
        let untouched = try render(.neutral, left: tone, right: tone)
        let difference = zip(untouched.left, tone).map { abs($0 - $1) }.max() ?? 1
        guard difference < 1e-4 else {
            throw SmokeFailure("the neutral chain changed the sound by \(difference)")
        }

        // 2. Bass Boost lifts 64 Hz over 4 kHz.
        let mixed = zip(sine(64, seconds: 2, amplitude: 0.2), sine(4_000, seconds: 2, amplitude: 0.2)).map { $0 + $1 }
        let boosted = try render(chain(.bassBoost), left: mixed, right: mixed).left
        let before = level(mixed, at: 64) / level(mixed, at: 4_000)
        let after = level(boosted, at: 64) / level(boosted, at: 4_000)
        let lift = 20 * log10(after / before)
        guard lift > 5, lift < 12 else { throw SmokeFailure("Bass Boost moved 64 Hz by \(lift) dB against 4 kHz, expected about 7") }
        guard (boosted.map { abs($0) }.max() ?? 9) < 1 else { throw SmokeFailure("Bass Boost clips") }

        // 3. Twelve semitones up: 440 Hz becomes 880 Hz.
        var octave = SoundEffectChain()
        octave.pitchCents = 1200
        let shifted = Array(try render(octave, left: sine(440, seconds: 2), right: sine(440, seconds: 2)).left.suffix(Int(rate)))
        let moved = level(shifted, at: 880) / max(1e-9, level(shifted, at: 440))
        guard moved > 4 else { throw SmokeFailure("the pitch shift left the tone where it was (880 Hz at \(moved)× of 440 Hz)") }
        // The pitch stage holds the sound back, by as much as the light is
        // told to wait: wired in but idle, and shifting a burst.
        let held = try render(.neutral, left: tone, right: tone, includesPitch: true).left
        let delay = (held.firstIndex { abs($0) > 1e-4 } ?? -1) - 1
        guard delay == EffectsGraph.pitchDelayFrames else { throw SmokeFailure("the pitch stage delays the sound by \(delay) frames") }
        var nudge = SoundEffectChain()
        nudge.pitchCents = 300
        let click = [Float](repeating: 0, count: Int(rate * 0.2)) + sine(440, seconds: 0.5)
        let late = try render(nudge, left: click, right: click).left
        let onset = Double((late.firstIndex { abs($0) > 0.05 } ?? 0) - Int(rate * 0.2)) / rate
        guard onset > 0.03, onset < 0.2 else { throw SmokeFailure("a shifted burst starts \(onset) s late") }

        // 4. Echo: a burst comes back 0.32 s later, with silence in between.
        let burst = sine(440, seconds: 0.1) + [Float](repeating: 0, count: Int(rate * 1.2))
        let echoed = try render(chain(.echo, reverb: 0), left: burst, right: burst).left
        let gap = rms(echoed, from: 0.16, to: 0.3)
        let repeatLevel = rms(echoed, from: 0.33, to: 0.41)
        guard gap < 0.002, repeatLevel > 0.05 else {
            throw SmokeFailure("the echo: \(repeatLevel) at the repeat, \(gap) before it")
        }

        // 5. Reverb: the burst rings on.
        let rung = try render(chain(.concertHall), left: burst, right: burst).left
        let tail = rms(rung, from: 0.2, to: 0.7)
        let dryTail = rms(burst, from: 0.2, to: 0.7)
        guard tail > 0.003, dryTail == 0 else { throw SmokeFailure("the reverb left no tail (\(tail))") }

        // 6. 8D: the tone is on the right after a quarter of the trip, on
        //    the left after three quarters.
        var orbit = SoundEffectChain()
        orbit.orbit = SoundOrbit(period: 4, depth: 0.9)
        let steady = sine(330, seconds: 4)
        let travelled = try render(orbit, left: steady, right: steady)
        let right = rms(travelled.right, from: 0.9, to: 1.1) / max(1e-9, rms(travelled.left, from: 0.9, to: 1.1))
        let left = rms(travelled.left, from: 2.9, to: 3.1) / max(1e-9, rms(travelled.right, from: 2.9, to: 3.1))
        guard right > 4, left > 4 else { throw SmokeFailure("the orbit did not reach the ears (right \(right)×, left \(left)×)") }

        // 7. Every preset renders: finite, not silent, not clipping badly.
        var slowest = 0.0
        for preset in SoundPreset.allCases where preset != .custom {
            let started = CACurrentMediaTime()
            let output = try render(chain(preset), left: mixed, right: mixed)
            slowest = max(slowest, (CACurrentMediaTime() - started) / 2)
            let peak = (output.left + output.right).map { abs($0) }.max() ?? 0
            guard peak.isFinite, peak > 0.01, peak < 1.5 else { throw SmokeFailure("\(preset.rawValue) rendered a peak of \(peak)") }
        }

        // A mono file and a player that hands left and right over in turns
        // get the same treatment as two separate channels.
        let boostedMono = try render(chain(.bassBoost), mono: mixed)
        let monoLift = 20 * log10(level(boostedMono, at: 64) / level(boostedMono, at: 4_000) / before)
        guard abs(monoLift - lift) < 0.5 else { throw SmokeFailure("a mono buffer was boosted by \(monoLift) dB, two channels by \(lift)") }
        let turns = try render(chain(.bassBoost), interleaved: mixed, steady)
        guard zip(turns.left, boosted).allSatisfy({ abs($0 - $1) < 1e-5 }), turns.right != turns.left else {
            throw SmokeFailure("interleaved buffers do not come out like separate ones")
        }

        // 8. What may be muted, and that this run can neither mute nor play.
        let app = AudioTapTarget(source: .spotify, bundleIdentifier: KnownApps.spotify, processIdentifier: 1)
        guard !SoundEffectTapRule.mutes(request: .everything(app), tapsProcesses: false, effectsFor: app, outputRuns: true),
              !SoundEffectTapRule.mutes(request: .app(app), tapsProcesses: true, effectsFor: app, outputRuns: false)
        else { throw SmokeFailure("the tap rule would mute what it must not") }
        let external = try checkTapToOutput()
        guard !EffectsOutput.isAllowed else { throw SmokeFailure("this run could play processed sound and mute an app") }
        if #available(macOS 14.2, *) {
            guard !ProcessTapSession.mutingAllowed else { throw SmokeFailure("this run could mute an app") }
            do {
                _ = try ProcessTapSession(scope: .processes([]), ring: AudioRingBuffer(capacity: 64), effects: AudioRingBuffer(capacity: 64))
                throw SmokeFailure("a muting tap was made in a smoke run")
            } catch let failure as ProcessTapSession.Failure {
                guard failure.stage.contains("refused") else { throw SmokeFailure("the muting tap failed otherwise: \(failure)") }
            }
        }
        do {
            _ = try EffectsOutput(sampleRate: rate)
            throw SmokeFailure("an effects output was made in a smoke run")
        } catch is EffectsOutput.Failure {
            // Refused, as it must be.
        }
        let controller = environment.effects
        guard controller.route == .off || controller.route == .demo || controller.route == .ownPlayer else {
            throw SmokeFailure("the effects' route in a smoke run is \(controller.route)")
        }
        let local = try await runLocalPlayer()
        return "neutral chain is the input (±\(String(format: "%.0e", difference))), Bass Boost +\(String(format: "%.1f", lift)) dB at 64 Hz, "
            + "an octave up puts 880 Hz \(Int(moved))× over 440 Hz, echo \(String(format: "%.2f", repeatLevel)) after 0.32 s, "
            + "reverb tail \(String(format: "%.3f", tail)), orbit \(Int(min(left, right)))× to each ear, "
            + "\(SoundPreset.allCases.count - 1) presets render (\(String(format: "%.1f", slowest * 100)) % of real time at most), the pitch stage delays by \(delay) frames (a shifted burst by \(Int(onset * 1000)) ms); "
            + local + "; " + external + "; no tap can be muted and nothing played in this run"
    }

    // MARK: Rendering

    /// The settings with `preset` chosen, as a chain.
    static func chain(_ preset: SoundPreset, reverb: Double? = nil) -> SoundEffectChain {
        var settings = SoundEffectSettings()
        settings.enabled = true
        settings.select(preset)
        if let reverb { settings.reverb = reverb }
        return SoundEffectChain(settings)
    }

    /// Runs `chain` over a stereo signal in the player's buffer size.
    static func render(_ chain: SoundEffectChain, left: [Float], right: [Float], includesPitch: Bool? = nil) throws -> (left: [Float], right: [Float]) {
        let processor = try LocalEffectsProcessor(sampleRate: rate, includesPitch: includesPitch ?? chain.shiftsPitch)
        processor.apply(chain)
        var left = left
        var right = right
        let total = min(left.count, right.count)
        let size = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = 2
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        try left.withUnsafeMutableBufferPointer { l in
            try right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < total {
                    let frames = min(processor.maximumFrames, total - done)
                    let bytes = UInt32(frames * MemoryLayout<Float>.size)
                    buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: l.baseAddress! + done)
                    buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: r.baseAddress! + done)
                    guard processor.context.pointee.process(list, frames: frames, sampleRate: rate) else {
                        throw SmokeFailure("the effects engine did not render a buffer of \(frames) frames")
                    }
                    done += frames
                }
            }
        }
        let counts = processor.counts
        guard counts.failed == 0, counts.rendered > 0 else { throw SmokeFailure("\(counts.failed) buffers were left dry") }
        return (left, right)
    }

    /// The same for a mono buffer.
    static func render(_ chain: SoundEffectChain, mono: [Float]) throws -> [Float] {
        let processor = try LocalEffectsProcessor(sampleRate: rate, includesPitch: chain.shiftsPitch)
        processor.apply(chain)
        var samples = mono
        try samples.withUnsafeMutableBufferPointer { pointer in
            var done = 0
            while done < pointer.count {
                let frames = min(processor.maximumFrames, pointer.count - done)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: pointer.baseAddress! + done
                ))
                guard processor.context.pointee.process(&list, frames: frames, sampleRate: rate) else {
                    throw SmokeFailure("the effects engine did not render a mono buffer")
                }
                done += frames
            }
        }
        return samples
    }

    /// The same for one buffer in which left and right take turns.
    static func render(_ chain: SoundEffectChain, interleaved left: [Float], _ right: [Float]) throws -> (left: [Float], right: [Float]) {
        let processor = try LocalEffectsProcessor(sampleRate: rate, includesPitch: chain.shiftsPitch)
        processor.apply(chain)
        let total = min(left.count, right.count)
        var samples = [Float](repeating: 0, count: total * 2)
        for index in 0..<total {
            samples[index * 2] = left[index]
            samples[index * 2 + 1] = right[index]
        }
        try samples.withUnsafeMutableBufferPointer { pointer in
            var done = 0
            while done < total {
                let frames = min(processor.maximumFrames, total - done)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size), mData: pointer.baseAddress! + done * 2
                ))
                guard processor.context.pointee.process(&list, frames: frames, sampleRate: rate) else {
                    throw SmokeFailure("the effects engine did not render an interleaved buffer")
                }
                done += frames
            }
        }
        return ((0..<total).map { samples[$0 * 2] }, (0..<total).map { samples[$0 * 2 + 1] })
    }

    // MARK: Another app's sound

    /// The way another app's sound takes, without a tap and without a
    /// device: the tap's hand-over writes stereo into the ring in every
    /// layout a tap delivers, and a silent output reads it through the
    /// effects, waits for a buffer in reserve, falls silent when it runs
    /// dry and catches up after falling behind.
    static func checkTapToOutput() throws -> String {
        let rate = 48_000.0
        let frames = 512
        let output = try EffectsOutput(sampleRate: rate, silent: true)
        output.apply(.neutral)
        try output.start()
        defer { output.stop() }
        let analysis = AudioRingBuffer(capacity: 1 << 17)
        let context = TapIOContext(writer: analysis.writer, stereo: output.ring.writer, scratchCapacity: 2_048)
        defer { context.release() }
        var position = 0
        func chunk() -> (left: [Float], right: [Float]) {
            let left = (0..<frames).map { Float(0.4 * sin(2 * .pi * 300 * Double(position + $0) / rate)) }
            let right = (0..<frames).map { Float(-0.3 * sin(2 * .pi * 500 * Double(position + $0) / rate)) }
            position += frames
            return (left, right)
        }
        /// Hands a chunk over as a tap does, in one of its layouts.
        func feed(_ part: (left: [Float], right: [Float]), interleaved: Bool) {
            if interleaved {
                var samples = [Float](repeating: 0, count: frames * 2)
                for index in 0..<frames {
                    samples[index * 2] = part.left[index]
                    samples[index * 2 + 1] = part.right[index]
                }
                samples.withUnsafeMutableBytes { raw in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                    context.mix(&list)
                    context.feed(&list)
                }
            } else {
                var left = part.left
                var right = part.right
                let size = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
                let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { memory.deallocate() }
                let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
                list.pointee.mNumberBuffers = 2
                left.withUnsafeMutableBytes { l in
                    right.withUnsafeMutableBytes { r in
                        let buffers = UnsafeMutableAudioBufferListPointer(list)
                        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                        context.mix(list)
                        context.feed(list)
                    }
                }
            }
        }

        // Nothing yet, and one buffer only: the output waits (silence).
        guard try output.render(frames: frames).left.allSatisfy({ $0 == 0 }) else { throw SmokeFailure("the output made sound out of nothing") }
        let first = chunk()
        feed(first, interleaved: true)
        guard try output.render(frames: frames).left.allSatisfy({ $0 == 0 }) else { throw SmokeFailure("the output did not wait for a buffer in reserve") }
        // With one in reserve it plays what came, in order, left as left.
        let second = chunk()
        feed(second, interleaved: false)
        let played = try output.render(frames: frames)
        guard zip(played.left, first.left).allSatisfy({ abs($0 - $1) < 1e-5 }), zip(played.right, first.right).allSatisfy({ abs($0 - $1) < 1e-5 }) else {
            throw SmokeFailure("the output did not play the tap's first buffer as it came")
        }
        let next = try output.render(frames: frames)
        guard zip(next.left, second.left).allSatisfy({ abs($0 - $1) < 1e-5 }), zip(next.right, second.right).allSatisfy({ abs($0 - $1) < 1e-5 }) else {
            throw SmokeFailure("separate channels did not arrive like interleaved ones")
        }
        // Dry: silence, and a buffer in reserve again before it goes on.
        guard try output.render(frames: frames).left.allSatisfy({ $0 == 0 }) else { throw SmokeFailure("a dry ring was not silence") }
        // Far behind (the engine stalled for half a second): it skips to the newest.
        var latest = [first, first]
        for _ in 0..<47 {
            latest = [latest[1], chunk()]
            feed(latest[1], interleaved: true)
        }
        // It plays the newest but one, and keeps the newest in reserve.
        let caught = try output.render(frames: frames)
        guard zip(caught.left, latest[0].left).allSatisfy({ abs($0 - $1) < 1e-5 }), output.ring.availableSamples == frames * 2 else {
            throw SmokeFailure("the output did not catch up after falling behind")
        }
        // The analysis got its mono mix of every buffer, effects or not.
        guard analysis.availableSamples == 49 * frames else { throw SmokeFailure("the analysis got \(analysis.availableSamples) samples of \(49 * frames)") }
        // A ring that is full takes no half chunks (left and right never swap).
        let small = AudioRingBuffer(capacity: 1_024)
        let tight = TapIOContext(writer: analysis.writer, stereo: small.writer, scratchCapacity: 2_048)
        defer { tight.release() }
        for _ in 0..<3 {
            var samples = [Float](repeating: 0.1, count: frames * 2)
            samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                tight.feed(&list)
            }
        }
        guard small.availableSamples == 1_024 else { throw SmokeFailure("a full ring took part of a chunk (\(small.availableSamples) samples)") }
        // The effects are in the way of the sound: Bass Boost changes it.
        output.apply(chain(.bassBoost))
        var boosted: [Float] = []
        var dry: [Float] = []
        for _ in 0..<40 {
            let part = chunk()
            feed(part, interleaved: true)
            if output.ring.availableSamples >= frames * 4 {
                boosted += try output.render(frames: frames).left
                dry += part.left
            }
        }
        let change = EffectsCheck.rms(boosted, from: 0.05, to: 0.3) / max(1e-9, EffectsCheck.rms(dry, from: 0.05, to: 0.3))
        guard abs(change - 1) > 0.02 else { throw SmokeFailure("the effects did not touch the other app's sound") }
        // The pitch stage is wired in and out while the output runs.
        var shifted = SoundEffectChain()
        shifted.pitchCents = 1200
        var heard: [Float] = []
        for (chain, rounds) in [(shifted, 60), (SoundEffectChain.neutral, 12), (shifted, 12)] {
            output.apply(chain)
            guard output.graph.isPitchWired == chain.shiftsPitch else { throw SmokeFailure("the pitch stage was not rewired") }
            for _ in 0..<rounds {
                feed(chunk(), interleaved: true)
                guard output.ring.availableSamples >= frames * 4 else { continue }
                let part = try output.render(frames: frames).left
                if chain.shiftsPitch, rounds == 60 { heard += part }
            }
        }
        let octave = Array(heard.suffix(frames * 20))
        let up = goertzel(octave, frequency: 600, rate: rate) / max(1e-9, goertzel(octave, frequency: 300, rate: rate))
        guard up > 3 else { throw SmokeFailure("the other app's sound was not shifted (600 Hz at \(up)× of 300 Hz)") }
        return "another app's sound: the tap's stereo hand-over (interleaved and separate) reaches a silent output through the ring in order, "
            + "with a buffer in reserve, silence when dry and a jump to the newest after falling behind; "
            + "the pitch stage is wired in and out while it runs (600 Hz \(Int(up))× over 300 Hz)"
    }

    // MARK: Ahenk's own player

    /// A generated tone played by the local player, muted, with the effects
    /// hooked into its audio chain as the app does it: the player's audio
    /// thread renders every buffer, the speed is the player's and shows in
    /// the snapshot, and taking the effects away leaves the player playing.
    static func runLocalPlayer() async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-smoke-effects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tone.wav")
        try GeneratedSongFiles.writeWAV(GeneratedSongFiles.tone(seconds: 12, sampleRate: Int(rate), bpm: 120, frequency: 330), sampleRate: Int(rate), to: file)
        let songs = await LocalLibraryScanner.songs(in: folder)
        guard songs.count == 1 else { throw SmokeFailure("the generated tone was not found") }

        let tap = OwnAudioTap()
        let player = LocalPlayer(tap: tap, publishesNowPlaying: false, muted: true)
        defer {
            tap.effectsHook.storePointer(nil, at: 0)
            player.shutdown()
        }
        func wait(_ what: String, seconds: Double = 4, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw SmokeFailure("\(what) within \(Int(seconds)) s") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        player.play(songs.map(\.catalogSong), at: 0, context: nil)
        try await wait("the tone did not start") { player.isPlaying && tap.buffersSeen > 2 && tap.sampleRate == rate }

        // Slowed + Reverb as it is needs no pitch stage in this player (its
        // pitch is the speed's own); two semitones on top make every stage run.
        var settings = SoundEffectSettings()
        settings.enabled = true
        settings.select(.slowedReverb)
        guard !SoundEffectChain(settings).adapted(to: .ownPlayer).shiftsPitch else {
            throw SmokeFailure("Slowed + Reverb asks for a pitch stage in Ahenk's own player")
        }
        settings.pitch += 2
        let chain = SoundEffectChain(settings).adapted(to: .ownPlayer)
        guard chain.shiftsPitch else { throw SmokeFailure("the pitch on top was lost") }
        let processor = try LocalEffectsProcessor(sampleRate: rate, maximumFrames: max(4096, tap.framesPerBuffer), includesPitch: chain.shiftsPitch)
        processor.apply(chain)
        tap.effectsHook.storePointer(UnsafeMutableRawPointer(processor.context), at: 0)
        player.setSpeed(chain.speed)
        do {
            try await wait("the player's audio thread did not run the effects") { processor.counts.rendered >= 3 }
        } catch {
            let skips = processor.skips
            throw SmokeFailure("the player's audio thread did not run the effects: \(processor.counts.rendered) rendered, \(processor.counts.failed) failed, "
                + "\(skips.count) skipped (\(skips.last)), \(tap.framesPerBuffer) frames a buffer at \(tap.sampleRate) Hz")
        }
        guard let slowed = player.makeSnapshot(), slowed.playbackRate == chain.speed else {
            throw SmokeFailure("the snapshot does not report the speed")
        }
        // The position moves at the speed, and so does the audio handed over.
        let buffers = tap.buffersSeen
        let started = Date()
        let from = slowed.elapsedTime
        try await Task.sleep(for: .milliseconds(1500))
        guard let later = player.makeSnapshot() else { throw SmokeFailure("the player stopped") }
        let wall = Date().timeIntervalSince(started)
        let pace = (later.elapsedTime - from) / wall
        let handed = Double((tap.buffersSeen - buffers) * tap.framesPerBuffer) / rate / wall
        guard abs(pace - chain.speed) < 0.12 else { throw SmokeFailure("at \(chain.speed)× the position moved at \(pace)×") }
        guard tap.playbackSpeed == chain.speed, tap.analysisRate == rate * chain.speed else {
            throw SmokeFailure("the analysis was not told the speed")
        }
        let counts = processor.counts
        guard counts.failed == 0 else { throw SmokeFailure("\(counts.failed) of the player's buffers were left dry") }

        // Effects off: the hook is gone, the song plays on at its own speed.
        tap.effectsHook.storePointer(nil, at: 0)
        player.setSpeed(1)
        let seen = tap.buffersSeen
        try await wait("the player did not play on without the effects") { tap.buffersSeen > seen + 1 }
        guard player.makeSnapshot()?.playbackRate == 1, processor.counts.rendered - counts.rendered <= 1 else {
            throw SmokeFailure("the effects were not taken out of the player")
        }
        return "own player (muted): \(counts.rendered) buffers rendered on its audio thread, position at \(String(format: "%.2f", pace))× for \(chain.speed)×, "
            + "audio handed over at \(String(format: "%.2f", handed))× real time"
    }

    // MARK: Signals and measures

    static func sine(_ frequency: Double, seconds: Double, amplitude: Float = 0.4) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// The amplitude of `frequency` in the signal (Goertzel).
    static func level(_ samples: [Float], at frequency: Double) -> Double {
        goertzel(samples, frequency: frequency, rate: rate)
    }

    static func goertzel(_ samples: [Float], frequency: Double, rate: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / rate)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let value = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = value
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return 2 * power.squareRoot() / Double(max(1, samples.count))
    }

    static func rms(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let range = max(0, Int(start * rate))..<min(samples.count, Int(end * rate))
        guard !range.isEmpty else { return 0 }
        let sum = samples[range].reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(range.count)).squareRoot()
    }
}
