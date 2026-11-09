import Accelerate
import AhenkKit
import AVFoundation
import os

/// Plays another app's sound with the effects: the process tap writes the
/// app's (muted) stereo sound into ``ring``, and an audio engine reads it
/// from there, runs it through the effects and plays it on the output
/// device.
///
/// This is the only thing in Ahenk that makes sound from another app's
/// audio, and with it comes the only reason to mute an app's own output,
/// so it exists in a normal run only: demo and smoke runs cannot make one
/// (``isAllowed``).
final class EffectsOutput: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Set once at launch: true in a normal run, false in demo and smoke
    /// runs, where nothing may be played or muted.
    nonisolated(unsafe) static var isAllowed = false

    let sampleRate: Double
    /// Interleaved stereo (left, right, left, …), written by the tap.
    let ring: AudioRingBuffer
    let graph = EffectsGraph()
    /// The output device changed or the engine stopped by itself.
    var onInterrupted: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let storage = AtomicSlotStorage(count: 2)
    private let scratch: UnsafeMutablePointer<Float>
    private let state: UnsafeMutablePointer<RenderState>
    private var observer: NSObjectProtocol?
    private static let scratchFrames = 4096

    /// The render thread's own state.
    private struct RenderState {
        var orbiter = SoundOrbiter(orbit: SoundOrbit(period: 8, depth: 0))
        /// Enough waits in the ring to start reading.
        var isPrimed = false
    }

    init(sampleRate: Double) throws {
        guard Self.isAllowed else {
            throw Failure(description: "processed sound is never played in a demo or smoke run")
        }
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw Failure(description: "no stereo format at \(sampleRate) Hz")
        }
        self.sampleRate = sampleRate
        // About 0.7 s of stereo at 48 kHz: far more than ever waits.
        ring = AudioRingBuffer(capacity: 1 << 16)
        scratch = .allocate(capacity: Self.scratchFrames * 2)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState())

        let reader = ring.reader
        let slots = storage.slots
        let scratch = self.scratch
        let state = self.state
        // More than this waiting means the engine fell behind: catch up.
        let ceiling = Int(sampleRate * 0.15)
        source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let frames = Int(frameCount)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            var waiting = reader.available / 2
            if waiting > frames + ceiling {
                reader.skip((waiting - frames) * 2)
                waiting = frames
            }
            // Start (and start again after running dry) with a buffer in
            // reserve, so the two audio threads' jitter is never heard.
            if !state.pointee.isPrimed, waiting >= frames * 2 { state.pointee.isPrimed = true }
            var done = 0
            if state.pointee.isPrimed {
                while done < frames {
                    let wanted = min(Self.scratchFrames, frames - done)
                    let got = reader.read(into: scratch, maxCount: wanted * 2) / 2
                    guard got > 0 else { break }
                    var one: Float = 1
                    vDSP_vsmul(scratch, 2, &one, left + done, 1, vDSP_Length(got))
                    vDSP_vsmul(scratch + 1, 2, &one, right + done, 1, vDSP_Length(got))
                    done += got
                }
                if done < frames { state.pointee.isPrimed = false }
            }
            if done < frames {
                vDSP_vclr(left + done, 1, vDSP_Length(frames - done))
                vDSP_vclr(right + done, 1, vDSP_Length(frames - done))
            }
            if done == 0 {
                isSilence.pointee = true
                return noErr
            }
            let depth = slots.double(1)
            if depth > 0 {
                state.pointee.orbiter.orbit = SoundOrbit(period: slots.double(0), depth: depth)
                state.pointee.orbiter.process(left: left, right: right, frames: done, sampleRate: sampleRate)
            }
            return noErr
        }
        engine.attach(source)
        graph.install(in: engine, from: source, format: format, pitchWired: false)
        engine.prepare()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.onInterrupted?()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
        scratch.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        do {
            try engine.start()
        } catch {
            throw Failure(description: "the output engine did not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
    }

    func apply(_ chain: SoundEffectChain) {
        graph.setPitchWired(chain.shiftsPitch)
        graph.apply(chain)
        storage.slots.storeDouble(chain.orbit?.period ?? 8, at: 0)
        storage.slots.storeDouble(chain.orbits ? chain.orbit?.depth ?? 0 : 0, at: 1)
    }
}

/// What the audio capture asks of the sound effects when it is about to
/// mute an app: Ahenk must already be playing that app's sound.
protocol EffectsTapSink: AnyObject, Sendable {
    /// Starts playing what will be written to the returned ring
    /// (interleaved stereo at `sampleRate`); `nil` when it cannot, and the
    /// app then keeps its own sound.
    func startOutput(sampleRate: Double) -> AudioRingBuffer?
    /// The tap is gone (the app has its own sound back): stop playing.
    func stopOutput()
}

/// The sound effects for other apps: holds the chain and makes the output
/// when the capture has an app's sound for it. Called from the main thread
/// (the chain) and the capture's control queue (the output).
final class ExternalEffects: EffectsTapSink, @unchecked Sendable {
    private struct State {
        var chain = SoundEffectChain.neutral
        var output: EffectsOutput?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// The output stopped by itself (a new output device): the capture
    /// builds the tap again, and with it a new output.
    var onInterrupted: (@Sendable () -> Void)?
    private let log = AhenkLogger(category: "effects")

    func set(_ chain: SoundEffectChain) {
        state.withLockUnchecked { state in
            state.chain = chain
            state.output?.apply(chain)
        }
    }

    var isPlaying: Bool {
        state.withLockUnchecked { $0.output?.isRunning ?? false }
    }

    func startOutput(sampleRate: Double) -> AudioRingBuffer? {
        do {
            let output = try EffectsOutput(sampleRate: sampleRate)
            output.onInterrupted = { [weak self] in self?.onInterrupted?() }
            let previous = state.withLockUnchecked { state -> EffectsOutput? in
                let previous = state.output
                output.apply(state.chain)
                state.output = output
                return previous
            }
            previous?.stop()
            try output.start()
            log.notice("Playing the app's sound with effects (\(Int(sampleRate)) Hz)")
            return output.ring
        } catch {
            log.error("The effects' output could not start: \(error); the app keeps its own sound")
            stopOutput()
            return nil
        }
    }

    func stopOutput() {
        let output = state.withLockUnchecked { state -> EffectsOutput? in
            defer { state.output = nil }
            return state.output
        }
        guard let output else { return }
        output.stop()
        log.info("Stopped playing with effects")
    }
}
