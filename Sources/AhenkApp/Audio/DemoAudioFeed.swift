import AhenkKit
import Foundation

/// `--demo`'s stand-in for a process tap: renders the demo song's beat
/// (``DemoAudioSynth``) at real-time pace into the analysis ring, following
/// the demo player's position, and zeros while it is paused (as a tap on a
/// paused app would). Lives on the analysis queue.
final class DemoAudioFeed {
    static let sampleRate = 48_000.0

    private let provider: DemoProvider
    private let synth = DemoAudioSynth(sampleRate: DemoAudioFeed.sampleRate)
    private let capacity = Int(DemoAudioFeed.sampleRate / 10)
    private let buffer: UnsafeMutablePointer<Float>
    private var lastRender: Double?
    /// Song position of the next sample to render.
    private var position: Double?
    private var carry = 0.0

    init(provider: DemoProvider) {
        self.provider = provider
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// Renders the audio due between the previous call and `now`
    /// (``AudioClock`` seconds), at most a tenth of a second.
    func render(until now: Double, into writer: AudioRingBuffer.Writer) {
        guard let last = lastRender else {
            lastRender = now
            return
        }
        lastRender = now
        let due = max(0, now - last) * Self.sampleRate + carry
        let count = min(capacity, Int(due))
        carry = count == capacity ? 0 : due - Double(count)
        guard count > 0 else { return }
        let snapshot = provider.snapshot()
        if snapshot.isPlaying {
            // Follow the player: start again after a seek or a song change.
            let start = snapshot.elapsed(at: Date()) - Double(count) / Self.sampleRate
            if position.map({ abs($0 - start) > 0.08 }) ?? true { position = max(0, start) }
            synth.render(into: buffer, count: count, from: position ?? 0)
            position = (position ?? 0) + Double(count) / Self.sampleRate
        } else {
            buffer.update(repeating: 0, count: count)
            position = nil
        }
        writer.write(buffer, count: count)
    }
}
