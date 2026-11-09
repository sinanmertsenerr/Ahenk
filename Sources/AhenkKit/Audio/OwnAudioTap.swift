internal import AhenkAtomics
import Accelerate
import CoreAudio
import Foundation

/// Ahenk's own playback (the local player) as samples for the analysis.
///
/// A process tap cannot hear Ahenk (the system tap excludes it, and the
/// fallback "everything" tap leaves it out on purpose), so the local player
/// hands its audio over from inside: an audio processing tap on each player
/// item calls ``Context/mix(_:frames:)`` on the player's audio thread,
/// which mixes the buffer to mono into ``ring``. The analysis queue then
/// moves it on at real-time pace (``OwnAudioPacer``), exactly as it reads a
/// process tap. Nothing is recorded or saved.
///
/// AVFoundation renders about half a second ahead of what is heard and in
/// bursts of a few thousand frames; ``measuredLead`` (set by the player
/// from its clock) is how far ahead, so the features can wait for the
/// sound.
public final class OwnAudioTap: @unchecked Sendable {
    public let ring: AudioRingBuffer
    /// What the audio thread gets: raw pointers only (no reference
    /// counting on that thread).
    public let context: UnsafeMutablePointer<Context>
    /// `[0]` sample rate bits, `[1]` frames per buffer, `[2]` media time of
    /// the newest sample (bits), `[3]` measured lead (bits), `[4]` buffers seen.
    private let shared: UnsafeMutablePointer<Int64>

    public init(ringCapacity: Int = 1 << 16) {
        ring = AudioRingBuffer(capacity: ringCapacity)
        shared = .allocate(capacity: 5)
        shared.initialize(repeating: 0, count: 5)
        context = .allocate(capacity: 1)
        context.initialize(to: Context(writer: ring.writer, shared: shared, scratchCapacity: 8_192))
        // Before anything is measured: AVFoundation's usual lead.
        ahenk_store_release(shared + 3, Int64(bitPattern: Self.defaultLead.bitPattern))
    }

    deinit {
        context.pointee.release()
        context.deinitialize(count: 1)
        context.deallocate()
        shared.deallocate()
    }

    /// How far ahead of the audible sound AVFoundation hands the audio over
    /// on this Mac (measured by the player; ~0.47 s here).
    public static let defaultLead = 0.47

    /// The rate of the audio the player renders now; 0 before the first item.
    public var sampleRate: Double { Double(bitPattern: UInt64(bitPattern: ahenk_load_acquire(shared))) }

    /// Frames per buffer the player hands over (AVFoundation: 4096).
    public var framesPerBuffer: Int { Int(ahenk_load_acquire(shared + 1)) }

    /// The media time (seconds in its item) just after the newest sample
    /// handed over; `nil` before any.
    public var newestMediaTime: Double? {
        guard ahenk_load_acquire(shared + 4) > 0 else { return nil }
        return Double(bitPattern: UInt64(bitPattern: ahenk_load_acquire(shared + 2)))
    }

    /// Buffers handed over so far.
    public var buffersSeen: Int { Int(ahenk_load_acquire(shared + 4)) }

    /// Seconds between the audio reaching the tap and the sound being
    /// heard, on average over a burst.
    public var measuredLead: Double {
        get { Double(bitPattern: UInt64(bitPattern: ahenk_load_acquire(shared + 3))) }
        set {
            let value = newValue.isFinite ? min(1.5, max(0, newValue)) : Self.defaultLead
            ahenk_store_release(shared + 3, Int64(bitPattern: value.bitPattern))
        }
    }

    /// The real-time side, used from the player's audio thread.
    public struct Context: @unchecked Sendable {
        let writer: AudioRingBuffer.Writer
        let shared: UnsafeMutablePointer<Int64>
        let scratch: UnsafeMutablePointer<Float>
        let scratchCapacity: Int

        init(writer: AudioRingBuffer.Writer, shared: UnsafeMutablePointer<Int64>, scratchCapacity: Int) {
            self.writer = writer
            self.shared = shared
            self.scratchCapacity = scratchCapacity
            scratch = .allocate(capacity: scratchCapacity)
            scratch.initialize(repeating: 0, count: scratchCapacity)
        }

        func release() {
            scratch.deallocate()
        }

        /// A player item's audio is about to flow: its rate and buffer size.
        public func prepare(sampleRate: Double, maxFrames: Int) {
            guard sampleRate > 0, sampleRate.isFinite else { return }
            ahenk_store_release(shared, Int64(bitPattern: sampleRate.bitPattern))
            ahenk_store_release(shared + 1, Int64(max(0, maxFrames)))
        }

        /// Averages every channel of every buffer (interleaved or not) into
        /// mono and writes it to the ring. Real-time safe: vDSP and the
        /// ring's lock-free writer, no allocation, no locks.
        public func mix(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, mediaTimeEnd: Double?) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            var channels = 0
            var available = Int.max
            for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
                available = min(available, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
                channels += Int(buffer.mNumberChannels)
            }
            guard channels > 0, available != Int.max else { return }
            let count = min(frames, available)
            guard count > 0 else { return }
            var gain = 1 / Float(channels)
            var done = 0
            while done < count {
                let chunk = min(scratchCapacity, count - done)
                var first = true
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
                    let stride = Int(buffer.mNumberChannels)
                    for channel in 0..<stride {
                        let source = data + done * stride + channel
                        if first {
                            vDSP_vsmul(source, stride, &gain, scratch, 1, vDSP_Length(chunk))
                            first = false
                        } else {
                            vDSP_vsma(source, stride, &gain, scratch, 1, scratch, 1, vDSP_Length(chunk))
                        }
                    }
                }
                writer.write(scratch, count: chunk)
                done += chunk
            }
            if let mediaTimeEnd, mediaTimeEnd.isFinite {
                ahenk_store_release(shared + 2, Int64(bitPattern: mediaTimeEnd.bitPattern))
            }
            ahenk_fetch_add_relaxed(shared + 4, 1)
        }
    }
}

/// Moves the own tap's bursts into the analysis ring at the pace they are
/// heard, so the analysis sees a steady stream (one frame per 10 ms pump,
/// as with a process tap) instead of a 90 ms burst every 90 ms.
///
/// It keeps about ``targetBacklog`` seconds waiting: each pump moves what
/// real time says is due, nudged towards the target; a backlog far beyond
/// it (after a stall) is skipped. Confined to the analysis queue.
public final class OwnAudioPacer: @unchecked Sendable {
    /// What stays waiting between bursts (more than half a burst).
    public static let targetBacklog = 0.12
    /// A backlog beyond the target by this much is skipped at once.
    public static let skipBeyond = 0.3
    /// Share of the distance to the target closed per second.
    static let correction = 0.5

    private let source: AudioRingBuffer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 4096
    private var lastTime: Double?
    private var carry = 0.0

    public init(source: AudioRingBuffer) {
        self.source = source
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        scratch.deallocate()
    }

    /// Seconds of audio waiting in the tap's ring at `sampleRate`.
    public func backlog(sampleRate: Double) -> Double {
        sampleRate > 0 ? Double(source.availableSamples) / sampleRate : 0
    }

    /// Starts over: what waits is dropped (stale audio from before).
    public func reset() {
        source.reader.skipAll()
        lastTime = nil
        carry = 0
    }

    /// Moves what is due between the last pump and `now` (``AudioClock``
    /// seconds) into `writer`; returns how many samples.
    @discardableResult
    public func pump(until now: Double, sampleRate: Double, into writer: AudioRingBuffer.Writer) -> Int {
        guard sampleRate > 0 else { return 0 }
        guard let last = lastTime else {
            lastTime = now
            return 0
        }
        let elapsed = min(0.1, max(0, now - last))
        lastTime = now
        var available = source.availableSamples
        let target = Self.targetBacklog * sampleRate
        let ceiling = (Self.targetBacklog + Self.skipBeyond) * sampleRate
        if Double(available) > ceiling {
            // Far behind (the pump stalled): drop the oldest down to the target.
            let excess = available - Int(target)
            skip(excess)
            available -= excess
        }
        let due = elapsed * sampleRate + carry
        let nudge = (Double(available) - target) * min(1, elapsed * Self.correction)
        let wanted = max(0, due + nudge)
        let count = min(available, Int(wanted))
        carry = count == available ? 0 : min(sampleRate * 0.01, wanted - Double(count))
        var moved = 0
        while moved < count {
            let chunk = source.reader.read(into: scratch, maxCount: min(scratchCapacity, count - moved))
            guard chunk > 0 else { break }
            writer.write(scratch, count: chunk)
            moved += chunk
        }
        return moved
    }

    private func skip(_ count: Int) {
        var left = count
        while left > 0 {
            let chunk = source.reader.read(into: scratch, maxCount: min(scratchCapacity, left))
            guard chunk > 0 else { break }
            left -= chunk
        }
    }
}
