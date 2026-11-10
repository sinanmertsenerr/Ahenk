import Foundation
import os

/// Synced lyrics that a music site loaded itself for the song in one of the
/// user's tabs (its lyrics view), handed over by the browser extension.
///
/// They belong to the exact recording the site plays, so they are answered
/// as `.canonicalRecording` (shown first, never moved by automatic sync) and
/// from memory, before the cache (`answersFromMemory`). A song the site sent
/// nothing for is `.notFound` at once, so the other providers are not held
/// up. Nothing is written to disk or to the log.
public final class BrowserLyricsProvider: LyricsProvider, Sendable {
    public static let providerName = "site"
    public let name = BrowserLyricsProvider.providerName
    public var reliability: Int { 100 }
    public var answersFromMemory: Bool { true }

    /// How many songs are kept (the latest per tab first).
    public static let capacity = 24

    private struct Entry: Sendable {
        var tabKey: String
        var site: BrowserSite
        var song: BridgeSong
        var lyrics: SyncedLyrics
    }

    /// A video's automatic captions: the words heard in it, with times.
    private struct Heard: Sendable {
        var tabKey: String
        var site: BrowserSite
        var song: BridgeSong
        var words: [RecognizedWord]
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var heard: [Heard] = []
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The response's `source` for lyrics from `site` ("site:spotify").
    public static func sourceName(for site: BrowserSite) -> String {
        "\(providerName):\(site.rawValue)"
    }

    /// The site behind a response's `source`, when it came from one.
    public static func site(ofSource source: String) -> BrowserSite? {
        guard source.hasPrefix(providerName + ":") else { return nil }
        return BrowserSite(rawValue: String(source.dropFirst(providerName.count + 1)))
    }

    /// Keeps lyrics a site sent (a later report for the same tab and song
    /// replaces them). Empty or untimed lists are ignored.
    public func store(_ lyrics: BridgeSiteLyrics, tabKey: String) {
        guard let site = BrowserSite(rawValue: lyrics.site) else { return }
        if lyrics.heard {
            storeHeard(lyrics, site: site, tabKey: tabKey)
            return
        }
        let lines = lyrics.lines
            .filter { $0.start.isFinite && $0.start >= 0 }
            .map { line in
                LyricLine(
                    start: line.start,
                    end: line.end.flatMap { $0.isFinite && $0 >= line.start ? $0 : nil },
                    text: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    words: (line.words ?? []).filter { $0.start.isFinite }.map { LyricWord(text: $0.text, start: $0.start, end: $0.end) }
                )
            }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return }
        let entry = Entry(tabKey: tabKey, site: site, song: lyrics.song, lyrics: SyncedLyrics(lines: lines))
        let continuations = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.entries.removeAll { $0.tabKey == tabKey && Self.matches(entry.song, $0.song) }
            state.entries.insert(entry, at: 0)
            if state.entries.count > Self.capacity { state.entries.removeLast(state.entries.count - Self.capacity) }
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(()) }
    }

    private func storeHeard(_ lyrics: BridgeSiteLyrics, site: BrowserSite, tabKey: String) {
        var words: [RecognizedWord] = []
        for line in lyrics.lines {
            for word in line.words ?? [] where word.start.isFinite && word.start >= 0 {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { words.append(RecognizedWord(text: text, start: word.start, end: word.end ?? word.start + 0.3)) }
            }
        }
        guard words.count >= 8 else { return }
        words.sort { $0.start < $1.start }
        let entry = Heard(tabKey: tabKey, site: site, song: lyrics.song, words: words)
        let continuations = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.heard.removeAll { $0.tabKey == tabKey && Self.matches(entry.song, $0.song) }
            state.heard.insert(entry, at: 0)
            if state.heard.count > Self.capacity { state.heard.removeLast(state.heard.count - Self.capacity) }
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(()) }
    }

    /// The words a video's automatic captions heard in this song, when a
    /// tab sent them: the times to put the song's real lyrics at.
    public func heardWords(for query: LyricsQuery) -> (site: BrowserSite, words: [RecognizedWord])? {
        let heard = state.withLock { $0.heard }
        let song = BridgeSong(title: query.title, artist: query.artist, album: query.album, duration: query.duration, trackID: query.spotifyTrackID)
        return heard.first { Self.matches(song, $0.song, spotifyID: query.spotifyTrackID) }.map { ($0.site, $0.words) }
    }

    /// Forgets everything (the bridge stopped).
    public func removeAll() {
        state.withLock {
            $0.entries = []
            $0.heard = []
        }
    }

    /// Fires whenever lyrics arrive, so the lyrics on screen can be looked
    /// up again (a site often loads them a moment after the song started).
    public func changes() -> AsyncStream<Void> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: key) }
        }
        return stream
    }

    /// The site's lyrics for this song, if a tab sent them.
    public func lookup(_ query: LyricsQuery) -> (site: BrowserSite, lyrics: SyncedLyrics)? {
        let entries = state.withLock { $0.entries }
        let song = BridgeSong(title: query.title, artist: query.artist, album: query.album, duration: query.duration, trackID: query.spotifyTrackID)
        guard let entry = entries.first(where: { Self.matches(song, $0.song, spotifyID: query.spotifyTrackID) }) else { return nil }
        return (entry.site, entry.lyrics)
    }

    // MARK: LyricsProvider

    public func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        lookup(query).map { .synced($0.lyrics) } ?? .notFound
    }

    public func fetchResponse(_ query: LyricsQuery) async throws -> LyricsResponse {
        guard let found = lookup(query) else { return LyricsResponse(result: .notFound, source: name) }
        return LyricsResponse(result: .synced(found.lyrics), source: Self.sourceName(for: found.site), timingAuthority: .canonicalRecording)
    }

    public func versions(for query: LyricsQuery) async throws -> [LyricsVersion] {
        guard let found = lookup(query) else { return [] }
        return [LyricsVersion(
            provider: name, reference: query.cacheKey, title: query.title, artist: query.artist, album: query.album,
            duration: query.duration, kind: .synced, lyrics: .synced(found.lyrics)
        )]
    }

    /// The site's lyrics cannot be searched.
    public func search(_ query: LyricsQuery) async throws -> [LyricsVersion] { [] }

    // MARK: Matching

    /// One song: the same Spotify recording when both name one, else the
    /// same core title, agreeing artists and lengths within 3 s.
    static func matches(_ a: BridgeSong, _ b: BridgeSong, spotifyID: String? = nil) -> Bool {
        let idA = spotifyID ?? a.trackID.flatMap(BrowserSite.spotifyTrackID)
        let idB = b.trackID.flatMap(BrowserSite.spotifyTrackID)
        if let idA, let idB { return idA == idB }
        let titleA = TrackMatching.coreTitle(a.title)
        guard !titleA.isEmpty, titleA == TrackMatching.coreTitle(b.title) else { return false }
        let artistA = TrackMatching.normalized(a.artist)
        let artistB = TrackMatching.normalized(b.artist)
        guard artistA.isEmpty || artistB.isEmpty || artistA == artistB || artistA.contains(artistB) || artistB.contains(artistA) else {
            return false
        }
        if let durationA = a.duration, let durationB = b.duration, durationA > 0, durationB > 0 {
            return abs(durationA - durationB) <= 3
        }
        return true
    }
}
