import AhenkKit
import AppKit
import Observation

/// What the UI shows as "now playing": the snapshot of the active provider
/// plus its artwork, lyrics and live audio features.
///
/// Step 1 attaches the demo provider directly. Step 2 puts the
/// `NowPlayingHub` (several providers, active-source rules) in front of this
/// model; the UI only depends on the properties below.
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
        streamTask = nil
        detailTask = nil
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
            artwork = nil
            artworkImage = nil
            lyrics = nil
            return
        }
        guard previous.map({ !$0.isSameTrack(as: new) }) ?? true else { return }
        let track = new.track
        Self.log.info("Now playing \u{201C}\(track.title)\u{201D} by \(track.artist) [\(track.source.rawValue)]")
        artwork = nil
        artworkImage = nil
        lyrics = nil
        loadDetails(for: track)
    }

    private func loadDetails(for track: Track) {
        detailTask?.cancel()
        let artworkProvider = self.artworkProvider
        let lyricsProvider = self.lyricsProvider
        detailTask = Task { [weak self] in
            async let art = artworkProvider?.artwork(for: track, pixelSize: Self.artworkPixelSize)
            async let words = Self.fetchLyrics(lyricsProvider, track: track)
            let (loadedArt, loadedLyrics) = await (art, words)
            guard let self, !Task.isCancelled, self.snapshot?.track.id == track.id else { return }
            if let loadedArt {
                self.artwork = loadedArt
                self.artworkImage = NSImage(cgImage: loadedArt.image, size: .zero)
            }
            self.lyrics = loadedLyrics
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
