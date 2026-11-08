import AhenkKit
import AppKit
import Observation

/// What the UI shows as "now playing": the snapshot of the followed player
/// plus its artwork, lyrics and live audio features.
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
    private(set) var lyrics: SyncedLyrics?
    private(set) var providerID: String?

    /// Polled by render loops; not observed.
    @ObservationIgnored private(set) var featureSource: AudioFeatureSource?
    @ObservationIgnored private var provider: NowPlayingProvider?
    @ObservationIgnored private var artworkProvider: ArtworkProvider?
    @ObservationIgnored private var lyricsProvider: LyricsProvider?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Which cover `artwork` shows (song plus the source's cover identity).
    @ObservationIgnored private var artworkSignature: String?

    private static let log = AhenkLogger(category: "now-playing")
    static let artworkPixelSize = 600

    var isPlaying: Bool { snapshot?.isPlaying ?? false }

    func attach(
        provider: NowPlayingProvider,
        artwork: ArtworkProvider?,
        lyrics: LyricsProvider?,
        features: AudioFeatureSource?
    ) {
        detach()
        self.provider = provider
        self.artworkProvider = artwork
        self.lyricsProvider = lyrics
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
        detailTask?.cancel()
        artworkTask?.cancel()
        streamTask = nil
        detailTask = nil
        artworkTask = nil
        artworkSignature = nil
        provider = nil
        artworkProvider = nil
        lyricsProvider = nil
        featureSource = nil
        providerID = nil
        snapshot = nil
        artwork = nil
        artworkImage = nil
        lyrics = nil
    }

    func perform(_ command: PlaybackCommand) {
        guard let provider else { return }
        Task { await provider.perform(command) }
    }

    /// The lyric line at `date`, if lyrics are known.
    func lyricLine(at date: Date) -> LyricLine? {
        guard let snapshot, let lyrics else { return nil }
        return lyrics.line(at: snapshot.elapsed(at: date))
    }

    private func apply(_ new: NowPlayingSnapshot?) {
        let previous = snapshot
        snapshot = new
        guard let new else {
            if previous != nil { Self.log.info("Nothing is playing") }
            artworkTask?.cancel()
            detailTask?.cancel()
            artworkSignature = nil
            artwork = nil
            artworkImage = nil
            lyrics = nil
            return
        }
        let isNewTrack = previous.map { !$0.isSameTrack(as: new) } ?? true
        if isNewTrack {
            let track = new.track
            Self.log.info("Now playing \u{201C}\(track.title)\u{201D} by \(track.artist) [\(track.source.rawValue), \(new.contentKind.rawValue), \(new.bundleIdentifier ?? "-")]")
            artwork = nil
            artworkImage = nil
            lyrics = nil
            loadLyrics(for: track)
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
        return "\(track.source.rawValue):\(track.id)|\(cover)|\(track.artworkURL?.absoluteString ?? "")|\(snapshot.contentKind.rawValue)"
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

    private func loadLyrics(for track: Track) {
        detailTask?.cancel()
        let lyricsProvider = self.lyricsProvider
        detailTask = Task { [weak self] in
            let loaded = await Self.fetchLyrics(lyricsProvider, track: track)
            guard let self, !Task.isCancelled, self.snapshot?.track.isSameSong(as: track) == true else { return }
            self.lyrics = loaded
        }
    }

    private nonisolated static func fetchLyrics(_ provider: LyricsProvider?, track: Track) async -> SyncedLyrics? {
        guard let provider else { return nil }
        if case .synced(let lyrics) = try? await provider.fetch(LyricsQuery(track: track)) {
            return lyrics
        }
        return nil
    }
}
