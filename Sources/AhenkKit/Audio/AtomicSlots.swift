internal import AhenkAtomics
import Foundation

/// A few 64-bit values shared between an audio thread and everyone else
/// without locks: numbers, bit patterns of `Double`s, raw pointers, and a
/// flag that works as a try-lock.
///
/// A plain view of memory owned by ``AtomicSlotStorage``: copying it costs
/// nothing and involves no reference count, so it is safe to hold on a
/// real-time thread. Keep the storage alive for as long as a view is used.
public struct AtomicSlots: @unchecked Sendable {
    let base: UnsafeMutablePointer<Int64>
    public let count: Int

    public func load(_ index: Int) -> Int64 {
        ahenk_load_acquire(base + index)
    }

    public func store(_ value: Int64, at index: Int) {
        ahenk_store_release(base + index, value)
    }

    public func double(_ index: Int) -> Double {
        Double(bitPattern: UInt64(bitPattern: load(index)))
    }

    public func storeDouble(_ value: Double, at index: Int) {
        store(Int64(bitPattern: value.bitPattern), at: index)
    }

    public func pointer(_ index: Int) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: Int(load(index)))
    }

    public func storePointer(_ pointer: UnsafeMutableRawPointer?, at index: Int) {
        store(Int64(Int(bitPattern: pointer)), at: index)
    }

    @discardableResult
    public func add(_ delta: Int64, at index: Int) -> Int64 {
        ahenk_fetch_add_relaxed(base + index, delta)
    }

    /// Takes the flag at `index` if nobody holds it; never waits.
    public func tryLock(_ index: Int) -> Bool {
        ahenk_compare_exchange(base + index, 0, 1)
    }

    public func unlock(_ index: Int) {
        ahenk_store_release(base + index, 0)
    }
}

/// Owns the memory behind ``AtomicSlots``.
public final class AtomicSlotStorage: @unchecked Sendable {
    public let slots: AtomicSlots

    public init(count: Int) {
        let base = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, count))
        base.initialize(repeating: 0, count: max(1, count))
        slots = AtomicSlots(base: base, count: max(1, count))
    }

    deinit {
        slots.base.deallocate()
    }
}
