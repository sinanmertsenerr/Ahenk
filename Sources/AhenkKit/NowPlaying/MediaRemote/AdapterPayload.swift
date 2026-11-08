import Foundation

/// One record of the MediaRemote adapter (`stream` / `get`), read leniently:
/// every field is optional, numbers may arrive as strings or the other way
/// round, times come in seconds or (with `--micros`) microseconds, and the
/// timestamp as epoch seconds, milliseconds, microseconds or ISO 8601.
public struct AdapterPayload: Sendable, Equatable {
    public var processIdentifier: Int32?
    public var bundleIdentifier: String?
    /// Set when a helper process (WebKit) publishes for its app.
    public var parentBundleIdentifier: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?
    public var elapsedTime: Double?
    public var playbackRate: Double?
    /// Epoch seconds.
    public var timestamp: Double?
    public var playing: Bool?
    /// Decoded cover bytes.
    public var artworkData: Data?
    public var artworkMimeType: String?
    public var artworkIdentifier: String?
    /// The source's own identity of the item (`uniqueIdentifier` or
    /// `contentItemIdentifier`).
    public var trackIdentifier: String?
    public var isLiked: Bool?
    public var supportsIsLiked: Bool?
    /// MediaRemote values: 1 off, 2 albums, 3 tracks.
    public var shuffleMode: Int?
    /// MediaRemote values: 1 off, 2 one track, 3 all.
    public var repeatMode: Int?
    public var mediaType: String?
    public var isMusicApp: Bool?
    public var isAdvertisement: Bool?
    public var prohibitsSkip: Bool?

    public init(
        processIdentifier: Int32? = nil,
        bundleIdentifier: String? = nil,
        parentBundleIdentifier: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        elapsedTime: Double? = nil,
        playbackRate: Double? = nil,
        timestamp: Double? = nil,
        playing: Bool? = nil,
        artworkData: Data? = nil,
        artworkMimeType: String? = nil,
        artworkIdentifier: String? = nil,
        trackIdentifier: String? = nil,
        isLiked: Bool? = nil,
        supportsIsLiked: Bool? = nil,
        shuffleMode: Int? = nil,
        repeatMode: Int? = nil,
        mediaType: String? = nil,
        isMusicApp: Bool? = nil,
        isAdvertisement: Bool? = nil,
        prohibitsSkip: Bool? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.parentBundleIdentifier = parentBundleIdentifier
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.timestamp = timestamp
        self.playing = playing
        self.artworkData = artworkData
        self.artworkMimeType = artworkMimeType
        self.artworkIdentifier = artworkIdentifier
        self.trackIdentifier = trackIdentifier
        self.isLiked = isLiked
        self.supportsIsLiked = supportsIsLiked
        self.shuffleMode = shuffleMode
        self.repeatMode = repeatMode
        self.mediaType = mediaType
        self.isMusicApp = isMusicApp
        self.isAdvertisement = isAdvertisement
        self.prohibitsSkip = prohibitsSkip
    }

    /// Reads the adapter's JSON dictionary. `artworkData` is passed in
    /// already decoded (the stream decoder decodes base64 once per cover).
    public init(fields: [String: Any], artworkData: Data?) {
        self.init()
        processIdentifier = Self.int(fields["processIdentifier"]).map(Int32.init(truncatingIfNeeded:))
        bundleIdentifier = Self.string(fields["bundleIdentifier"])
        parentBundleIdentifier = Self.string(fields["parentApplicationBundleIdentifier"])
        title = Self.string(fields["title"])
        artist = Self.string(fields["artist"])
        album = Self.string(fields["album"])
        duration = Self.double(fields["duration"]) ?? Self.double(fields["durationMicros"]).map { $0 / 1_000_000 }
        elapsedTime = Self.double(fields["elapsedTime"]) ?? Self.double(fields["elapsedTimeMicros"]).map { $0 / 1_000_000 }
        playbackRate = Self.double(fields["playbackRate"])
        playing = Self.bool(fields["playing"])
        if let micros = Self.double(fields["timestampEpochMicros"]) {
            timestamp = micros / 1_000_000
        } else if let number = Self.number(fields["timestamp"]) {
            timestamp = Self.normalizeEpoch(number)
        } else if let text = fields["timestamp"] as? String {
            timestamp = Self.parseISODate(text)?.timeIntervalSince1970
        }
        self.artworkData = artworkData
        artworkMimeType = Self.string(fields["artworkMimeType"])
        artworkIdentifier = Self.string(fields["artworkIdentifier"])
        trackIdentifier = Self.string(fields["uniqueIdentifier"]) ?? Self.string(fields["contentItemIdentifier"])
        isLiked = Self.bool(fields["isLiked"])
        supportsIsLiked = Self.bool(fields["supportsIsLiked"])
        shuffleMode = Self.int(fields["shuffleMode"])
        repeatMode = Self.int(fields["repeatMode"])
        mediaType = Self.string(fields["mediaType"])
        isMusicApp = Self.bool(fields["isMusicApp"])
        isAdvertisement = Self.bool(fields["isAdvertisement"])
        prohibitsSkip = Self.bool(fields["prohibitsSkip"])
    }

    /// No song at all (the adapter prints `{}` when nothing plays).
    public var isEmpty: Bool {
        (title ?? "").isEmpty && (artist ?? "").isEmpty
    }

    public var isPlaying: Bool {
        if let playing { return playing }
        return (playbackRate ?? 0) > 0
    }

    // MARK: Lenient field readers

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber).map(\.doubleValue)
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let d = number.doubleValue
            return d.isFinite ? d : nil
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        double(value).flatMap { $0.magnitude < 9e15 ? Int($0) : nil }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Epoch seconds from seconds (~1e9), milliseconds (~1e12) or
    /// microseconds (~1e15).
    static func normalizeEpoch(_ value: Double) -> Double {
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1000 }
        return value
    }

    static func parseISODate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Base64 (optionally a `data:` URL) to bytes.
    public static func decodeArtwork(_ string: String?) -> Data? {
        guard var text = string, !text.isEmpty else { return nil }
        if let marker = text.range(of: ";base64,") {
            text = String(text[marker.upperBound...])
        } else if text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") {
            text = String(text[text.index(after: comma)...])
        }
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }
}

// MARK: - Snapshot mapping

extension AdapterPayload {
    /// The app that owns the player (the browser for WebKit helpers).
    public var ownerBundleIdentifier: String? {
        SourceResolver.owner(bundleIdentifier: bundleIdentifier, parent: parentBundleIdentifier)
    }

    /// The payload as a snapshot, with the source resolved from the owning
    /// app and, for browsers, guessed from the metadata.
    /// `artworkAspectRatio` (width / height of `artworkData`) helps tell
    /// video thumbnails from album covers.
    public func snapshot(resolver: SourceResolver, artworkAspectRatio: Double?, now: Date) -> NowPlayingSnapshot? {
        guard !isEmpty else { return nil }
        let owner = ownerBundleIdentifier
        var title = self.title ?? ""
        var artist = self.artist ?? ""
        let album = self.album ?? ""
        let source: MusicSource
        var kind: ContentKind

        switch resolver.kind(of: owner) {
        case .musicApp(let app):
            source = app
            kind = .music
        case .browser:
            let guess = WebSiteInference.guess(title: title, artist: artist, album: album, artworkAspectRatio: artworkAspectRatio)
            source = guess.source
            kind = guess.contentKind
            title = guess.title
            artist = guess.artist
        case .videoPlayer:
            source = .otherApp
            kind = .video
        case .spokenWordPlayer:
            source = .otherApp
            kind = .podcast
        case .other:
            source = .otherApp
            kind = isMusicApp == true ? .music : .unknown
        }
        // What the player says about itself wins over the guesses.
        if let mediaType {
            if mediaType.localizedCaseInsensitiveContains("video") {
                kind = .video
            } else if mediaType.localizedCaseInsensitiveContains("podcast") || mediaType.localizedCaseInsensitiveContains("audiobook") {
                kind = .podcast
            } else if mediaType.localizedCaseInsensitiveContains("music"), kind == .unknown {
                kind = .music
            }
        }
        if isAdvertisement == true { kind = .advertisement }

        let isPlaying = self.isPlaying
        let rate: Double = isPlaying ? ((playbackRate ?? 0) > 0 ? playbackRate! : 1) : 0
        let identifier = trackIdentifier.map { "mr:\($0)" }
            ?? TrackMatching.metadataKey(title: title, artist: artist, album: album)

        var capabilities: PlaybackCapabilities = [.playPause, .seek]
        if prohibitsSkip != true { capabilities.insert(.skip) }
        if shuffleMode != nil { capabilities.insert(.shuffle) }
        if repeatMode != nil { capabilities.formUnion([.repeatAll, .repeatOne]) }
        if supportsIsLiked == true { capabilities.insert(.like) }

        return NowPlayingSnapshot(
            track: Track(
                id: identifier,
                source: source,
                title: title,
                artist: artist,
                album: album,
                duration: duration ?? 0
            ),
            bundleIdentifier: owner,
            processIdentifier: processIdentifier,
            elapsedTime: max(0, elapsedTime ?? 0),
            playbackRate: rate,
            timestamp: timestamp.map { Date(timeIntervalSince1970: $0) } ?? now,
            isPositionKnown: elapsedTime != nil,
            isShuffled: shuffleMode.flatMap(Self.shuffle(fromMediaRemote:)),
            repeatMode: repeatMode.flatMap(Self.repeatMode(fromMediaRemote:)),
            isLiked: supportsIsLiked == true ? isLiked : nil,
            capabilities: capabilities,
            contentKind: kind,
            artworkData: artworkData,
            artworkIdentifier: artworkData.map { data in artworkIdentifier ?? ArtworkDigest.hex(of: data) }
        )
    }

    static func shuffle(fromMediaRemote value: Int) -> Bool? {
        switch value {
        case 1: false
        case 2, 3: true
        default: nil
        }
    }

    static func repeatMode(fromMediaRemote value: Int) -> RepeatMode? {
        switch value {
        case 1: .off
        case 2: .one
        case 3: .all
        default: nil
        }
    }
}
