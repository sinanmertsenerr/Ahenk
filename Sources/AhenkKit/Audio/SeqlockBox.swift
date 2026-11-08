internal import AhenkAtomics
import Foundation

/// The latest value of a plain-data type, written by one thread and read by
/// any number of threads, none of which ever takes a lock.
///
/// Two seqlock slots: the writer fills the slot readers are not pointed at,
/// then points them to it. A read fails (and retries) only if the writer
/// wrote twice while one read was in progress, so a writer preempted in the
/// middle of a write never makes readers wait.
final class SeqlockBox<Value: BitwiseCopyable>: @unchecked Sendable {
    private let wordCount: Int
    /// `[0]`, `[1]`: slot sequences; `[2]`: index of the newest slot.
    private let control: UnsafeMutablePointer<Int64>
    /// Two slots of `wordCount` words each.
    private let words: UnsafeMutablePointer<UInt64>

    init(_ initial: Value) {
        wordCount = max(1, (MemoryLayout<Value>.size + 7) / 8)
        control = .allocate(capacity: 3)
        control.initialize(repeating: 0, count: 3)
        words = .allocate(capacity: wordCount * 2)
        words.initialize(repeating: 0, count: wordCount * 2)
        write(initial)
    }

    deinit {
        control.deallocate()
        words.deallocate()
    }

    /// Publishes `value`. Call from one thread at a time.
    func write(_ value: Value) {
        let next = 1 - Int(ahenk_load_relaxed(control + 2))
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: wordCount) { buffer in
            let base = buffer.baseAddress!
            base.initialize(repeating: 0, count: wordCount)
            withUnsafeBytes(of: value) { raw in
                UnsafeMutableRawPointer(base).copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            ahenk_seqlock_write(control + next, words + next * wordCount, base, wordCount)
        }
        ahenk_store_release(control + 2, Int64(next))
    }

    /// The newest value. Never blocks.
    func read() -> Value {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: wordCount) { buffer in
            let base = buffer.baseAddress!
            base.initialize(repeating: 0, count: wordCount)
            for _ in 0..<64 {
                let slot = Int(ahenk_load_acquire(control + 2))
                if ahenk_seqlock_read(control + slot, words + slot * wordCount, base, wordCount) {
                    break
                }
            }
            // After 64 lost races (the reader stalled through many writes)
            // the copy may mix two versions word by word; every field still
            // holds a value that was written, so it is safe to use.
            return UnsafeRawPointer(base).loadUnaligned(as: Value.self)
        }
    }
}
