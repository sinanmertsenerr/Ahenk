internal import AhenkAtomics
import Foundation

/// A single-producer, single-consumer ring of mono samples between Core
/// Audio's I/O thread and the analysis queue.
///
/// The producer (``Writer``) never blocks, locks or allocates: it copies
/// what fits and drops the rest (counted in ``droppedSamples``) when the
/// reader falls behind. Positions are 64-bit totals that only grow, so the
/// two sides synchronise with one acquire/release pair each and never
/// confuse a full ring with an empty one.
///
/// The ring owns its memory; ``Writer`` and ``Reader`` are plain views of it
/// without a reference count, so the I/O thread does no ARC work. Keep the
/// ring alive for as long as either view is in use.
public final class AudioRingBuffer: @unchecked Sendable {
    /// A power of two.
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// `[0]` samples written in total, `[1]` read in total, `[2]` dropped.
    private let counters: UnsafeMutablePointer<Int64>

    /// `capacity` is rounded up to a power of two (at least 2).
    public init(capacity: Int) {
        var size = 2
        while size < capacity { size <<= 1 }
        self.capacity = size
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
        counters = .allocate(capacity: 3)
        counters.initialize(repeating: 0, count: 3)
    }

    deinit {
        storage.deallocate()
        counters.deallocate()
    }

    public var writer: Writer { Writer(storage: storage, counters: counters, mask: capacity - 1) }
    public var reader: Reader { Reader(storage: storage, counters: counters, mask: capacity - 1) }

    /// Samples the writer could not store because the ring was full.
    public var droppedSamples: Int { Int(ahenk_load_relaxed(counters + 2)) }
    /// Samples waiting to be read.
    public var availableSamples: Int { reader.available }

    /// The producer side. Use from one thread at a time.
    public struct Writer: @unchecked Sendable {
        fileprivate let storage: UnsafeMutablePointer<Float>
        fileprivate let counters: UnsafeMutablePointer<Int64>
        fileprivate let mask: Int

        /// Copies up to `count` samples; returns how many fit. Real-time
        /// safe: two `memcpy`s and two atomic operations.
        @discardableResult
        public func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
            guard count > 0 else { return 0 }
            let written = ahenk_load_relaxed(counters)
            let read = ahenk_load_acquire(counters + 1)
            let free = (mask + 1) - Int(written - read)
            let accepted = min(count, max(0, free))
            if accepted < count {
                ahenk_fetch_add_relaxed(counters + 2, Int64(count - accepted))
            }
            guard accepted > 0 else { return 0 }
            let start = Int(written) & mask
            let first = min(accepted, mask + 1 - start)
            (storage + start).update(from: samples, count: first)
            if first < accepted {
                storage.update(from: samples + first, count: accepted - first)
            }
            ahenk_store_release(counters, written + Int64(accepted))
            return accepted
        }
    }

    /// The consumer side. Use from one thread at a time.
    public struct Reader: @unchecked Sendable {
        fileprivate let storage: UnsafeMutablePointer<Float>
        fileprivate let counters: UnsafeMutablePointer<Int64>
        fileprivate let mask: Int

        public var available: Int {
            Int(ahenk_load_acquire(counters) - ahenk_load_relaxed(counters + 1))
        }

        /// Copies up to `maxCount` of the oldest samples into `destination`;
        /// returns how many.
        @discardableResult
        public func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
            let written = ahenk_load_acquire(counters)
            let read = ahenk_load_relaxed(counters + 1)
            let count = min(maxCount, Int(written - read))
            guard count > 0 else { return 0 }
            let start = Int(read) & mask
            let first = min(count, mask + 1 - start)
            destination.update(from: storage + start, count: first)
            if first < count {
                (destination + first).update(from: storage, count: count - first)
            }
            ahenk_store_release(counters + 1, read + Int64(count))
            return count
        }

        /// Throws away everything waiting; returns how many samples.
        @discardableResult
        public func skipAll() -> Int {
            let written = ahenk_load_acquire(counters)
            let read = ahenk_load_relaxed(counters + 1)
            ahenk_store_release(counters + 1, written)
            return Int(written - read)
        }
    }
}
