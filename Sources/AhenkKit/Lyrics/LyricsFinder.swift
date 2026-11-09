import Foundation
import os

/// Finds a song's lyrics in this order: the version the user picked for
/// it, the disk cache, then the providers (whose answer is cached).
///
/// A song the providers had nothing for is not asked about again for
/// `missMemory` seconds (a repeated song does not cost requests every
/// time); a lookup that failed because the providers could not be reached
/// is not remembered.
public final class LyricsFinder: Sendable {
    public enum Origin: String, Sendable, Equatable {
        /// The version the user picked.
        case choice
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

    public func find(_ query: LyricsQuery, onProvisional: (@Sendable (LyricsResponse) async -> Void)? = nil) async -> Found {
        let key = query.cacheKey
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
        if let stored = await cache?.load(key) {
            return Found(response: stored, origin: .cache, allFailed: false, choice: nil)
        }
        let now = clock()
        if let missed = misses.withLock({ $0[key] }), now.timeIntervalSince(missed) < Self.missMemory {
            return Found(response: .none, origin: .recentMiss, allFailed: false, choice: nil)
        }
        let lookup = await chain.fetch(query, onProvisional: onProvisional)
        if lookup.response.result.hasLyrics {
            await cache?.store(lookup.response, for: key)
            misses.withLock { $0[key] = nil }
        } else if !lookup.allFailed {
            misses.withLock { misses in
                misses[key] = now
                if misses.count > 500 {
                    misses = misses.filter { now.timeIntervalSince($0.value) < Self.missMemory }
                }
            }
        }
        return Found(response: lookup.response, origin: .providers, allFailed: lookup.allFailed, choice: nil)
    }

    /// Makes `version` the song's lyrics from now on and returns them.
    public func choose(_ version: LyricsVersion, for query: LyricsQuery) async throws -> LyricsResponse {
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
