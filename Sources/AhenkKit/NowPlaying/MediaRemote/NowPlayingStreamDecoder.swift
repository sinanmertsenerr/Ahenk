import Foundation

/// Applies the MediaRemote adapter's `stream` output to a running state.
///
/// The adapter writes one JSON envelope per line, `{type, diff, payload}`.
/// With diffing on (the default) every envelope after the first carries only
/// the keys that changed: a present key updates, an explicit `null` removes,
/// an absent key stays as it was. A non-diff envelope replaces everything.
///
/// The base64 cover is decoded once, when its key changes, and kept as bytes,
/// so the hundreds of kilobytes of text are not re-parsed on every position
/// update.
///
/// Not thread-safe: drive it from one serial context (the adapter reader's
/// pipe handler).
public final class NowPlayingStreamDecoder {
    private var fields: [String: Any] = [:]
    private var artwork: Data?
    private let now: () -> TimeInterval

    public init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    public func reset() {
        fields = [:]
        artwork = nil
    }

    /// Feeds one line. Returns the merged payload (empty when nothing
    /// plays), or `nil` when the line is not a `data` envelope.
    public func decode(line: Data) -> AdapterPayload? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "data"
        else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let isDiff = (object["diff"] as? Bool) ?? false

        if isDiff {
            for (key, value) in payload where key != "artworkData" {
                if value is NSNull {
                    fields.removeValue(forKey: key)
                } else {
                    fields[key] = value
                }
            }
            if let value = payload["artworkData"] {
                artwork = value is NSNull ? nil : AdapterPayload.decodeArtwork(value as? String)
            }
            reanchorIfNeeded(payload)
        } else {
            fields = payload
            fields.removeValue(forKey: "artworkData")
            artwork = AdapterPayload.decodeArtwork(payload["artworkData"] as? String)
        }
        return AdapterPayload(fields: fields, artworkData: artwork)
    }

    /// A position or rate change without a fresh sample time would make the
    /// interpolation start from a stale timestamp (the seek "bounce", the
    /// resume overshoot). Anchor it to now instead.
    private func reanchorIfNeeded(_ payload: [String: Any]) {
        let timelineChanged = payload["elapsedTime"] != nil || payload["elapsedTimeMicros"] != nil
            || payload["playbackRate"] != nil || payload["playing"] != nil
        let hasFreshTimestamp = payload["timestamp"] != nil || payload["timestampEpochMicros"] != nil
        guard timelineChanged, !hasFreshTimestamp else { return }
        if fields["timestampEpochMicros"] != nil || payload["elapsedTimeMicros"] != nil {
            fields["timestampEpochMicros"] = now() * 1_000_000
            fields.removeValue(forKey: "timestamp")
        } else {
            fields["timestamp"] = now()
        }
    }
}

/// Splits a byte stream into newline-terminated lines.
public struct LineSplitter: Sendable {
    private var buffer = Data()
    /// Lines longer than this are dropped (a runaway writer must not grow
    /// memory without bound). Covers are well below it.
    public static let maximumLineLength = 32 * 1024 * 1024

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maximumLineLength { buffer.removeAll() }
        return lines
    }
}
