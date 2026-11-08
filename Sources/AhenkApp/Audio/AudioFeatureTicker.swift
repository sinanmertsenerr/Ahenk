import AhenkKit
import AppKit
import QuartzCore

/// Hands the audio features to UI code on the main thread at display
/// rate: the publisher for views that animate with the music (the Settings
/// monitor; later the Dock ring and desktop widgets).
///
/// One display link serves every subscriber, each at its own maximum rate.
/// It runs only while someone subscribes and the music is not silent: half
/// a second after the features turn silent it pauses (subscribers got the
/// silent frame), and the store's activity signal wakes it when music comes
/// back. No polling.
///
/// Render threads (the edge light) should not use this: read
/// `AudioFeatureStore.features(at:)` from the render loop instead.
@MainActor
final class AudioFeatureTicker: NSObject {
    private struct Subscriber {
        let interval: Double
        var last: Double
        let handler: (AudioFeatures) -> Void
    }

    private let store: AudioFeatureStore
    private var subscribers: [UUID: Subscriber] = [:]
    private var link: CADisplayLink?
    private var activity: AudioActivityObservation?
    private var silentSince: Double?

    init(store: AudioFeatureStore) {
        self.store = store
        super.init()
        activity = store.observeActivity { [weak self] _ in
            DispatchQueue.main.async { self?.wake() }
        }
    }

    /// Calls `handler` with the features at most `framesPerSecond` times a
    /// second (and once right away). Keep the subscription; releasing or
    /// cancelling it unsubscribes.
    func subscribe(framesPerSecond: Double, _ handler: @escaping (AudioFeatures) -> Void) -> AudioFeatureSubscription {
        let key = UUID()
        subscribers[key] = Subscriber(interval: 1 / max(1, framesPerSecond), last: 0, handler: handler)
        handler(store.currentFeatures())
        wake()
        return AudioFeatureSubscription { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.unsubscribe(key) }
            } else {
                DispatchQueue.main.async { self?.unsubscribe(key) }
            }
        }
    }

    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    private func unsubscribe(_ key: UUID) {
        subscribers[key] = nil
        if subscribers.isEmpty { pause() }
    }

    private func wake() {
        guard !subscribers.isEmpty, store.isActive || silentSince == nil else { return }
        silentSince = nil
        if link == nil {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        let fastest = subscribers.values.map { 1 / $0.interval }.max() ?? 30
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: Float(fastest), preferred: Float(fastest))
        link?.isPaused = false
    }

    private func pause() {
        link?.isPaused = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = link.targetTimestamp
        let features = store.features(at: time)
        for (key, subscriber) in subscribers where time - subscriber.last >= subscriber.interval * 0.9 {
            subscribers[key]?.last = time
            subscriber.handler(features)
        }
        if features.isSilent {
            if silentSince == nil { silentSince = time }
            if let since = silentSince, time - since > 0.5 { pause() }
        } else {
            silentSince = nil
        }
    }

    deinit {
        link?.invalidate()
    }
}

/// Ends a ticker subscription when cancelled or released.
final class AudioFeatureSubscription {
    private var cancellation: (() -> Void)?

    init(_ cancel: @escaping () -> Void) {
        cancellation = cancel
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }

    deinit {
        cancel()
    }
}
