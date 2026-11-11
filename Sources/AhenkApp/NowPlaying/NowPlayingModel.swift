import AhenkKit
import AppKit
import Observation

/// What the UI shows as "now playing": the snapshot of the followed player
/// plus its artwork and live audio features (lyrics: `LyricsController`).
///
/// Normally attached to the `NowPlayingHub` (which is itself a provider and
/// merges every source); tests and the smoke run may attach any provider.
/// The UI only depends on the properties below. Step 3's audio engine reads
/// `snapshot` for the app to tap (`bundleIdentifier`, `processIdentifier`)
/// and whether it plays music (`isPlaying`, `contentKind`).
@MainActor
@Observable
final class NowPlayingModel {
    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var artwork: Artwork?
    /// `artwork` as an image for AppKit and SwiftUI.
    private(set) var artworkImage: NSImage?
    private(set) var providerID: String?

    /// Polled by render loops; not observed.
    @ObservationIgnored private(set) var featureSource: AudioFeatureSource?
    @ObservationIgnored private var provider: NowPlayingProvider?
    @ObservationIgnored private var artworkProvider: ArtworkProvider?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Which cover `artwork` shows (song plus the source's cover identity).
    @ObservationIgnored private var artworkSignature: String?

    private static let log = AhenkLogger(category: "now-playing")
    static let artworkPixelSize = 600

    var isPlaying: Bool { snapshot?.isPlaying ?? false }

    func attach(
        provider: NowPlayingProvider,
        artwork: ArtworkProvider?,
        features: AudioFeatureSource?
    ) {
        detach()
        self.provider = provider
        self.artworkProvider = artwork
        self.featureSource = features
        providerID = provider.id
        Self.log.info("Following provider \(provider.id)")
        let stream = provider.snapshots()
        streamTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(snapshot)
            }
        }
    }

    func detach() {
        streamTask?.cancel()
        artworkTask?.cancel()
        streamTask = nil
        artworkTask = nil
        artworkSignature = nil
        provider = nil
        artworkProvider = nil
        featureSource = nil
        providerID = nil
        snapshot = nil
        artwork = nil
        artworkImage = nil
    }

    func perform(_ command: PlaybackCommand) {
        guard let provider else { return }
        Task { await provider.perform(command) }
    }

    private func apply(_ new: NowPlayingSnapshot?) {
        let previous = snapshot
        snapshot = new
        guard let new else {
            if previous != nil { Self.log.info("Nothing is playing") }
            artworkTask?.cancel()
            artworkSignature = nil
            artwork = nil
            artworkImage = nil
            return
        }
        let isNewTrack = previous.map { !$0.isSameTrack(as: new) } ?? true
        if isNewTrack {
            let track = new.track
            Self.log.info("Now playing \u{201C}\(track.title)\u{201D} by \(track.artist) [\(track.source.rawValue), \(new.contentKind.rawValue), \(new.bundleIdentifier ?? "-")]")
            artwork = nil
            artworkImage = nil
        }
        // The cover may arrive after the song (a later update, a lookup);
        // the old cover of the same song stays until the new one is ready.
        let signature = Self.artworkSignature(of: new)
        if isNewTrack || signature != artworkSignature {
            artworkSignature = signature
            loadArtwork(for: new)
        }
    }

    static func artworkSignature(of snapshot: NowPlayingSnapshot) -> String {
        let track = snapshot.track
        let cover = snapshot.artworkIdentifier ?? snapshot.artworkData.map { "\($0.count)" } ?? ""
        return "\(track.source.rawValue):\(track.id)|\(cover)|\(track.artworkURL?.absoluteString ?? "")|\(snapshot.contentKind.rawValue)|\(snapshot.isMusicVideo)"
    }

    private func loadArtwork(for snapshot: NowPlayingSnapshot) {
        artworkTask?.cancel()
        guard let artworkProvider else { return }
        let signature = artworkSignature
        artworkTask = Task { [weak self] in
            let loaded = await artworkProvider.artwork(for: snapshot, pixelSize: Self.artworkPixelSize)
            guard let self, !Task.isCancelled, self.artworkSignature == signature else { return }
            guard let loaded else {
                if self.snapshot.map({ !$0.isSameTrack(as: snapshot) }) ?? true {
                    self.artwork = nil
                    self.artworkImage = nil
                }
                return
            }
            self.artwork = loaded
            self.artworkImage = NSImage(cgImage: loaded.image, size: .zero)
        }
    }
}
