import Accelerate
import AhenkKit
import AVFoundation

/// The sound effects inside Ahenk's own player: an audio engine in manual
/// rendering mode that the player's audio tap calls for every buffer, in
/// place, after the dry sound went to the analysis.
///
/// No device, no output of its own and nothing audible by itself: the
/// processed samples leave through the player, exactly where the dry ones
/// would have. The same processor run on generated tones is what the smoke
/// check measures.
///
/// Create and change it on the main thread; ``context`` is for the audio
/// thread.
final class LocalEffectsProcessor {
    enum Slot {
        /// Try-lock: one buffer at a time (two player items may overlap).
        static let busy = 0
        static let sampleRate = 1
        static let orbitPeriod = 2
        static let orbitDepth = 3
        /// Frames of the buffer in hand, and how many the engine took.
        static let pending = 4
        static let offset = 5
        static let rendered = 6
        static let failed = 7
        /// Why the last buffer was left as it came (`Skip`), and how many were.
        static let skipReason = 8
        static let skipped = 9
        static let count = 10
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Why a buffer was not processed.
    enum Skip: Int64 {
        case none = 0
        /// More frames than the engine was made for.
        case tooLong = 1
        /// Another sample rate than the engine's.
        case otherRate = 2
        /// Neither mono, nor two channels of floats.
        case otherShape = 3
        /// Another buffer was being processed.
        case busy = 4
    }

    let sampleRate: Double
    let maximumFrames: Int
    /// The pitch stage is part of this engine (see `EffectsGraph`); it
    /// holds the sound back by `EffectsGraph.pitchDelayFrames`.
    let includesPitch: Bool
    let graph = EffectsGraph()
    /// What the audio thread uses; valid until this object goes away.
    let context: UnsafeMutablePointer<LocalEffectsContext>
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let storage = AtomicSlotStorage(count: Slot.count)
    private let orbiter: UnsafeMutablePointer<SoundOrbiter>
    /// Four channels of `maximumFrames`: the buffer in hand (left, right)
    /// and what the engine made of it (left, right).
    private let samples: UnsafeMutablePointer<Float>
    private let listMemory: UnsafeMutableRawPointer

    init(sampleRate: Double, maximumFrames: Int = 4096, includesPitch: Bool = false) throws {
        guard sampleRate > 0, maximumFrames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw Failure(description: "no stereo format at \(sampleRate) Hz")
        }
        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames
        self.includesPitch = includesPitch
        do {
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: AVAudioFrameCount(maximumFrames))
        } catch {
            throw Failure(description: "manual rendering is not available: \(error.localizedDescription)")
        }
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames * 4)
        samples.initialize(repeating: 0, count: maximumFrames * 4)
        self.samples = samples
        let left = samples
        let right = samples + maximumFrames
        let slots = storage.slots
        // The engine pulls the buffer in hand through this node while it
        // renders (so nothing is delayed); what it asks beyond is silence.
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let frames = Int(frameCount)
            guard buffers.count == 2,
                  let outLeft = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let outRight = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            let pending = Int(slots.load(Slot.pending))
            let offset = Int(slots.load(Slot.offset))
            let count = max(0, min(frames, pending - offset))
            if count > 0 {
                outLeft.update(from: left + offset, count: count)
                outRight.update(from: right + offset, count: count)
                slots.store(Int64(offset + count), at: Slot.offset)
            }
            if count < frames {
                (outLeft + count).update(repeating: 0, count: frames - count)
                (outRight + count).update(repeating: 0, count: frames - count)
            }
            if count == 0 { isSilence.pointee = true }
            return noErr
        }
        self.source = source
        orbiter = .allocate(capacity: 1)
        orbiter.initialize(to: SoundOrbiter(orbit: SoundOrbit(period: 8, depth: 0)))
        // The two-buffer list the engine renders into.
        listMemory = .allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let rendered = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        rendered.pointee.mNumberBuffers = 2
        context = .allocate(capacity: 1)
        engine.attach(source)
        graph.install(in: engine, from: source, format: format, pitchWired: includesPitch)
        engine.prepare()
        var startFailure: Error?
        do {
            try engine.start()
        } catch {
            startFailure = error
        }
        slots.storeDouble(sampleRate, at: Slot.sampleRate)
        context.initialize(to: LocalEffectsContext(
            slots: slots, render: engine.manualRenderingBlock, rendered: rendered,
            left: left, right: right, outLeft: samples + maximumFrames * 2, outRight: samples + maximumFrames * 3,
            maximumFrames: maximumFrames, orbiter: orbiter
        ))
        if let startFailure {
            throw Failure(description: "the effects engine did not start: \(startFailure.localizedDescription)")
        }
    }

    deinit {
        engine.stop()
        context.deinitialize(count: 1)
        context.deallocate()
        listMemory.deallocate()
        orbiter.deinitialize(count: 1)
        orbiter.deallocate()
        samples.deallocate()
    }

    /// Sets every stage; safe while the player plays.
    func apply(_ chain: SoundEffectChain) {
        graph.apply(chain)
        let slots = storage.slots
        slots.storeDouble(chain.orbit?.period ?? 8, at: Slot.orbitPeriod)
        slots.storeDouble(chain.orbits ? chain.orbit?.depth ?? 0 : 0, at: Slot.orbitDepth)
    }

    /// Buffers processed so far, and buffers left dry because the engine
    /// could not render them.
    var counts: (rendered: Int, failed: Int) {
        (Int(storage.slots.load(Slot.rendered)), Int(storage.slots.load(Slot.failed)))
    }

    /// Buffers that were not of a kind this engine takes, and why the last one.
    var skips: (count: Int, last: Skip) {
        (Int(storage.slots.load(Slot.skipped)), Skip(rawValue: storage.slots.load(Slot.skipReason)) ?? .none)
    }
}

/// The audio thread's side of `LocalEffectsProcessor`: raw pointers and
/// lock-free slots only.
struct LocalEffectsContext {
    let slots: AtomicSlots
    let render: AVAudioEngineManualRenderingBlock
    /// The list the engine renders into (it points at `outLeft`/`outRight`).
    let rendered: UnsafeMutablePointer<AudioBufferList>
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let outLeft: UnsafeMutablePointer<Float>
    let outRight: UnsafeMutablePointer<Float>
    let maximumFrames: Int
    /// Used by the audio thread only.
    let orbiter: UnsafeMutablePointer<SoundOrbiter>

    /// How the player hands a buffer over.
    private enum Shape {
        /// One channel (a mono file): processed in stereo, folded back.
        case mono(UnsafeMutablePointer<Float>)
        /// Left and right in buffers of their own.
        case separate(UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)
        /// Left and right taking turns in one buffer.
        case interleaved(UnsafeMutablePointer<Float>)
    }

    /// Runs the effects over `frames` frames of float samples (mono, or
    /// stereo in either layout), in place. Returns false and leaves the
    /// sound as it was when the buffers are of another shape or rate, when
    /// another buffer is being processed, or when the engine cannot render.
    @discardableResult
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, sampleRate: Double) -> Bool {
        typealias Slot = LocalEffectsProcessor.Slot
        guard frames > 0 else { return false }
        guard frames <= maximumFrames else { return skip(.tooLong) }
        guard sampleRate == slots.double(Slot.sampleRate) else { return skip(.otherRate) }
        guard let shape = shape(of: list, frames: frames) else { return skip(.otherShape) }
        guard slots.tryLock(Slot.busy) else { return skip(.busy) }
        defer { slots.unlock(Slot.busy) }

        var one: Float = 1
        let length = vDSP_Length(frames)
        switch shape {
        case .mono(let data):
            left.update(from: data, count: frames)
            right.update(from: data, count: frames)
        case .separate(let first, let second):
            left.update(from: first, count: frames)
            right.update(from: second, count: frames)
        case .interleaved(let data):
            vDSP_vsmul(data, 2, &one, left, 1, length)
            vDSP_vsmul(data + 1, 2, &one, right, 1, length)
        }
        let depth = slots.double(Slot.orbitDepth)
        if depth > 0 {
            orbiter.pointee.orbit = SoundOrbit(period: slots.double(Slot.orbitPeriod), depth: depth)
            orbiter.pointee.process(left: left, right: right, frames: frames, sampleRate: sampleRate)
        }
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        let outputs = UnsafeMutableAudioBufferListPointer(rendered)
        outputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: outLeft)
        outputs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: outRight)
        slots.store(0, at: Slot.offset)
        slots.store(Int64(frames), at: Slot.pending)
        var status: OSStatus = noErr
        let result = render(AVAudioFrameCount(frames), rendered, &status)
        slots.store(0, at: Slot.pending)
        guard result == .success, status == noErr else {
            // The player's buffer was not touched: the sound stays dry.
            slots.add(1, at: Slot.failed)
            return false
        }
        switch shape {
        case .mono(let data):
            var half: Float = 0.5
            vDSP_vasm(outLeft, 1, outRight, 1, &half, data, 1, length)
        case .separate(let first, let second):
            first.update(from: outLeft, count: frames)
            second.update(from: outRight, count: frames)
        case .interleaved(let data):
            vDSP_vsmul(outLeft, 1, &one, data, 2, length)
            vDSP_vsmul(outRight, 1, &one, data + 1, 2, length)
        }
        slots.add(1, at: Slot.rendered)
        return true
    }

    private func shape(of list: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Shape? {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let bytes = frames * MemoryLayout<Float>.size
        guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        switch (buffers.count, Int(first.mNumberChannels)) {
        case (1, 1):
            return Int(first.mDataByteSize) >= bytes ? .mono(data) : nil
        case (1, 2):
            return Int(first.mDataByteSize) >= bytes * 2 ? .interleaved(data) : nil
        case (2, 1):
            guard buffers[1].mNumberChannels == 1, Int(first.mDataByteSize) >= bytes, Int(buffers[1].mDataByteSize) >= bytes,
                  let second = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return nil }
            return .separate(data, second)
        default:
            return nil
        }
    }

    private func skip(_ reason: LocalEffectsProcessor.Skip) -> Bool {
        slots.store(reason.rawValue, at: LocalEffectsProcessor.Slot.skipReason)
        slots.add(1, at: LocalEffectsProcessor.Slot.skipped)
        return false
    }
}
