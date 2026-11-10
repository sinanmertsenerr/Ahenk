import Foundation
import os

/// Finds a song's lyrics in this order: the version the user picked for
/// it, the lyrics the playing source supplied itself (a music site's own,
/// held in memory, never cached), the disk cache, then the providers (whose
/// answer is cached).
///
/// A song the providers had nothing for is not asked about again for
/// `missMemory` seconds (a repeated song does not cost requests every
/// time); a lookup that failed because the providers could not be reached
/// is not remembered.
public final class LyricsFinder: Sendable {
    public enum Origin: String, Sendable, Equatable {
        /// The version the user picked.
        case choice
        /// The playing source's own lyrics (a music site in the browser).
        case playingSource
        case cache
        case providers
        /// Remembered as not found a short while ago.
        case recentMiss
    }

    public struct Found: Sendable, Equatable {
        public var response: LyricsResponse
        public var origin: Origin
        /// The providers could not be reached at all.
        public var allFailed: Bool
        /// The picked version, when that is what was found.
        public var choice: LyricsVersion?
    }

    public static let missMemory: TimeInterval = 30 * 60

    public let chain: LyricsChain
    public let cache: LyricsCache?
    public let songs: LyricsSongStore
    private let misses = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    private let clock: @Sendable () -> Date
    private static let log = AhenkLogger(category: "lyrics")

    public init(chain: LyricsChain, cache: LyricsCache?, songs: LyricsSongStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.chain = chain
        self.cache = cache
        self.songs = songs
        self.clock = clock
    }

    /// The same cache, store and misses with other providers (Settings
    /// turned one off or on).
    public func with(chain: LyricsChain) -> LyricsFinder {
        let finder = LyricsFinder(chain: chain, cache: cache, songs: songs, clock: clock)
        return finder
    }

    static func choiceKey(_ query: LyricsQuery) -> String {
        "choice\u{1}" + query.cacheKey
    }

    /// - Parameter otherwise: other ways to ask about the same song, tried
    ///   in order when the song's own metadata finds no lyrics (a music
    ///   video asked about as the song it plays, `LyricsQuery.songsOfVideo`).
    ///   What they find was timed for another recording: nothing is proved
    ///   about this one, so the timing stays open to correction.
    public func find(
        _ query: LyricsQuery, otherwise: [LyricsQuery] = [], onProvisional: (@Sendable (LyricsResponse) async -> Void)? = nil
    ) async -> Found {
        let key = query.cacheKey
        // A miss without the other ways says nothing about a lookup with them.
        let missKey = otherwise.isEmpty ? key : key + "\u{1}otherwise"
        if let choice = songs.entry(for: key)?.choice {
            if let stored = await cache?.load(Self.choiceKey(query)) {
                return Found(response: stored, origin: .choice, allFailed: false, choice: choice)
            }
            if let result = try? await chain.lyrics(of: choice), result.hasLyrics {
                let response = LyricsResponse(result: result, source: choice.provider)
                await cache?.store(response, for: Self.choiceKey(query))
                return Found(response: response, origin: .choice, allFailed: false, choice: choice)
            }
            Self.log.notice("The picked lyrics could not be loaded again; looking them up anew")
        }
        for provider in chain.providers where provider.answersFromMemory {
            if let response = try? await provider.fetchResponse(query), case .synced = response.result {
                return Found(response: response, origin: .playingSource, allFailed: false, choice: nil)
            }
        }
        if let stored = await cache?.load(key) {
            return Found(response: stored, origin: .cache, allFailed: false, choice: nil)
        }
        let now = clock()
        if let missed = misses.withLock({ $0[missKey] }), now.timeIntervalSince(missed) < Self.missMemory {
            return Found(response: .none, origin: .recentMiss, allFailed: false, choice: nil)
        }
        var lookup = await chain.fetch(query, onProvisional: onProvisional)
        if !lookup.response.result.hasLyrics {
            for other in otherwise {
                let found = await chain.fetch(other)
                if found.response.result.hasLyrics {
                    Self.log.info("Nothing under the video's own title and length; found as the song it plays (\(found.response.source))")
                    lookup = LyricsLookup(response: LyricsResponse(result: found.response.result, source: found.response.source, timingAuthority: .unverified))
                    break
                }
                lookup.allFailed = lookup.allFailed && found.allFailed
            }
        }
        if lookup.response.result.hasLyrics {
            await cache?.store(lookup.response, for: key)
            misses.withLock { $0[missKey] = nil }
        } else if !lookup.allFailed {
            misses.withLock { misses in
                misses[missKey] = now
                if misses.count > 500 {
                    misses = misses.filter { now.timeIntervalSince($0.value) < Self.missMemory }
                }
            }
        }
        return Found(response: lookup.response, origin: .providers, allFailed: lookup.allFailed, choice: nil)
    }

    /// Makes `version` the song's lyrics from now on and returns them.
    ///
    /// The playing source's own lyrics come first by themselves, so picking
    /// them is going back to the automatic pick: no choice is kept and
    /// nothing is cached (they live in memory only).
    public func choose(_ version: LyricsVersion, for query: LyricsQuery) async throws -> LyricsResponse {
        if let own = chain.providers.first(where: { $0.answersFromMemory && $0.name == version.provider }) {
            let response = try await own.fetchResponse(query)
            guard response.result.hasLyrics else { throw LyricsError.malformed }
            await clearChoice(for: query)
            return response
        }
        let result = try await chain.lyrics(of: version)
        guard result.hasLyrics || result == .instrumental else { throw LyricsError.malformed }
        let response = LyricsResponse(result: result, source: version.provider)
        if result.hasLyrics {
            await cache?.store(response, for: Self.choiceKey(query))
        }
        songs.setChoice(version, for: query.cacheKey)
        misses.withLock { $0[query.cacheKey] = nil }
        return response
    }

    /// Back to the providers' own pick.
    public func clearChoice(for query: LyricsQuery) async {
        songs.setChoice(nil, for: query.cacheKey)
        await cache?.remove(Self.choiceKey(query))
    }

    /// The name lyrics timed on this Mac go by (in place of a provider's).
    public static let alignedSource = "aligned"

    /// Makes lyrics that were timed on this Mac (plain words aligned to
    /// the song, `LyricAligner`) the song's lyrics from now on: kept like
    /// a picked version, so they come back with the song, and dropped the
    /// same way ("use the lyrics Ahenk found"). They were timed against
    /// this very recording, so nothing corrects them afterwards.
    @discardableResult
    public func adopt(_ lyrics: SyncedLyrics, for query: LyricsQuery) async -> (response: LyricsResponse, version: LyricsVersion) {
        let response = LyricsResponse(result: .synced(lyrics), source: Self.alignedSource, timingAuthority: .canonicalRecording)
        let version = LyricsVersion(
            provider: Self.alignedSource, reference: lyrics.timingFingerprint, title: query.title, artist: query.artist,
            album: query.album, duration: query.duration, kind: .synced
        )
        await cache?.store(response, for: Self.choiceKey(query))
        songs.setChoice(version, for: query.cacheKey)
        misses.withLock { $0[query.cacheKey] = nil }
        return (response, version)
    }

    public func versions(for query: LyricsQuery) async -> [LyricsVersion] {
        await chain.versions(for: query)
    }

    public func search(_ query: LyricsQuery) async -> [LyricsVersion] {
        await chain.search(query)
    }

    /// Forgets every cached lyric and every remembered miss (the picks and
    /// offsets stay).
    public func clearCache() async {
        misses.withLock { $0 = [:] }
        await cache?.removeAll()
    }
}
