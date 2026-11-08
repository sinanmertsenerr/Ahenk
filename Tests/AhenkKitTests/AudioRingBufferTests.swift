import Foundation
import Testing
@testable import AhenkKit

@Suite("Audio ring buffer")
struct AudioRingBufferTests {
    private func write(_ values: [Float], to ring: AudioRingBuffer) -> Int {
        values.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, count: $0.count) }
    }

    private func read(_ count: Int, from ring: AudioRingBuffer) -> [Float] {
        var output = [Float](repeating: -1, count: count)
        let read = output.withUnsafeMutableBufferPointer { ring.reader.read(into: $0.baseAddress!, maxCount: count) }
        return Array(output.prefix(read))
    }

    @Test("Capacity rounds up to a power of two")
    func capacity() {
        #expect(AudioRingBuffer(capacity: 5).capacity == 8)
        #expect(AudioRingBuffer(capacity: 8).capacity == 8)
        #expect(AudioRingBuffer(capacity: 1).capacity == 2)
    }

    @Test("Writes and reads wrap around the end in order")
    func wrapAround() {
        let ring = AudioRingBuffer(capacity: 8)
        #expect(write([0, 1, 2, 3, 4, 5], to: ring) == 6)
        #expect(read(4, from: ring) == [0, 1, 2, 3])
        // Positions 6, 7 and then 0, 1, 2 of the storage.
        #expect(write([6, 7, 8, 9, 10], to: ring) == 5)
        #expect(ring.availableSamples == 7)
        #expect(read(10, from: ring) == [4, 5, 6, 7, 8, 9, 10])
        #expect(ring.availableSamples == 0)
        #expect(read(3, from: ring).isEmpty)
        // Many laps keep the order.
        var expected: Float = 11
        for lap in 0..<50 {
            let chunk = (0..<(lap % 7 + 1)).map { Float($0) + expected }
            #expect(write(chunk, to: ring) == chunk.count)
            #expect(read(chunk.count, from: ring) == chunk)
            expected += Float(chunk.count)
        }
        #expect(ring.droppedSamples == 0)
    }

    @Test("A full ring keeps what fits and counts the rest as dropped")
    func overflow() {
        let ring = AudioRingBuffer(capacity: 4)
        #expect(write([1, 2, 3], to: ring) == 3)
        #expect(write([4, 5, 6], to: ring) == 1)
        #expect(ring.droppedSamples == 2)
        #expect(write([7], to: ring) == 0)
        #expect(ring.droppedSamples == 3)
        #expect(read(8, from: ring) == [1, 2, 3, 4])
        #expect(write([8, 9], to: ring) == 2)
        #expect(read(8, from: ring) == [8, 9])
    }

    @Test("Skipping drops everything waiting")
    func skip() {
        let ring = AudioRingBuffer(capacity: 16)
        _ = write([1, 2, 3, 4, 5], to: ring)
        #expect(ring.reader.skipAll() == 5)
        #expect(ring.availableSamples == 0)
        _ = write([6], to: ring)
        #expect(read(4, from: ring) == [6])
    }

    @Test("One writer thread and one reader thread pass every sample in order")
    func concurrentTransfer() async {
        let ring = AudioRingBuffer(capacity: 1024)
        let total = 400_000
        // The test's writer offers again what did not fit (the I/O thread
        // would drop it); the rejected offers are what `droppedSamples` counts.
        let writer = Task.detached { () -> Int in
            var next = 0
            var rejected = 0
            var chunk = [Float](repeating: 0, count: 300)
            var random = SplitMix64(seed: 3)
            while next < total {
                let size = min(total - next, Int(random.next() % 300) + 1)
                for index in 0..<size { chunk[index] = Float(next + index) }
                let written = chunk.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, count: size) }
                next += written
                rejected += size - written
                if written < size { await Task.yield() }
            }
            return rejected
        }
        let reader = Task.detached { () -> Bool in
            var expected = 0
            var buffer = [Float](repeating: 0, count: 257)
            while expected < total {
                let count = buffer.withUnsafeMutableBufferPointer { ring.reader.read(into: $0.baseAddress!, maxCount: 257) }
                for index in 0..<count where buffer[index] != Float(expected + index) { return false }
                expected += count
                if count == 0 { await Task.yield() }
            }
            return true
        }
        let rejected = await writer.value
        #expect(await reader.value)
        #expect(ring.droppedSamples == rejected)
    }
}
