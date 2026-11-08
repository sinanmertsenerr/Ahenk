import Foundation
import os
@testable import AhenkKit

/// A throwaway `UserDefaults` domain, removed when the test ends.
final class ScratchDefaults {
    let suiteName = "com.sinanmertsener.Ahenk.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var function: @Sendable () -> Date { { [self] in self.now } }
}

/// A fresh temporary directory, deleted when the test ends.
final class ScratchDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AhenkTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Polls `condition` until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func decodeSettings(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

// MARK: - Generated images

import CoreGraphics

/// Images drawn in code for artwork and palette tests (no real covers).
enum TestImages {
    /// Vertical bands of `colors` with the given relative widths.
    static func bands(_ colors: [SRGBColor], weights: [Double]? = nil, width: Int = 120, height: Int = 120) -> CGImage {
        let weights = weights ?? Array(repeating: 1, count: colors.count)
        let total = weights.reduce(0, +)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var x = 0.0
        for (color, weight) in zip(colors, weights) {
            let w = Double(width) * weight / total
            context.setFillColor(color.cgColor())
            context.fill(CGRect(x: x, y: 0, width: w + 1, height: Double(height)))
            x += w
        }
        return context.makeImage()!
    }

    static func solid(_ color: SRGBColor, width: Int = 64, height: Int = 64) -> CGImage {
        bands([color], width: width, height: height)
    }

    /// A horizontal gradient through `colors`.
    static func gradient(_ colors: [SRGBColor], width: Int = 128, height: Int = 64) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let locations = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        let gradient = CGGradient(colorsSpace: space, colors: colors.map { $0.cgColor() } as CFArray, locations: locations)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        return context.makeImage()!
    }

    /// A wide picture with black bars at the top and bottom, like a video
    /// thumbnail, with `color` in the middle.
    static func letterboxed(_ color: SRGBColor, width: Int = 160, height: Int = 120, bar: Int = 15) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(SRGBColor.black.cgColor())
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color.cgColor())
        context.fill(CGRect(x: 0, y: bar, width: width, height: height - 2 * bar))
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        ArtworkImageDecoder.pngData(image)!
    }
}

/// Reads up to `count` elements, or what arrived when the stream ends or
/// `timeout` passes.
func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeout: Duration = .seconds(3)) async -> [T] {
    let box = OSAllocatedUnfairLock(initialState: (items: [T](), done: false))
    let task = Task {
        for await item in stream {
            let enough = box.withLock { state -> Bool in
                state.items.append(item)
                return state.items.count >= count
            }
            if enough { break }
        }
        box.withLock { $0.done = true }
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !box.withLock({ $0.done }) {
        try? await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    return box.withLock { $0.items }
}

/// Collects values from any thread.
final class Recorder<Value: Sendable>: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Value]())

    func append(_ value: Value) { lock.withLock { $0.append(value) } }
    var values: [Value] { lock.withLock { $0 } }
}
