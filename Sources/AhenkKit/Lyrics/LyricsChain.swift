import Foundation

/// What a lookup through the chain found, and whether the providers could
/// be asked at all (offline is not "no lyrics").
public struct LyricsLookup: Sendable, Equatable {
    public var response: LyricsResponse
    /// Every provider failed (network, server errors) for every query.
    public var allFailed: Bool

    public init(response: LyricsResponse, allFailed: Bool = false) {
        self.response = response
        self.allFailed = allFailed
    }
}

/// The providers in order of trust, asked together.
///
/// Policy: the first **synced** result for the song's own metadata wins at
/// once (a Spotify lookup waits for the provider that can prove the exact
/// recording); a synced result for the cleaned-up title only after every
/// provider has missed the original; then plain lyrics, then an
/// "instrumental" answer, else not found. A provider that throws is
/// skipped. A synced timeline that starts after the song has ended is
/// rejected (another recording).
public struct LyricsChain: Sendable {
    public var providers: [any LyricsProvider]
    private static let log = AhenkLogger(category: "lyrics")

    public init(providers: [any LyricsProvider]) {
        self.providers = providers
    }

    /// LRCLIB, Musixmatch and NetEase, without the ones in `disabled`.
    public static func standard(http: any HTTPFetching, disabled: Set<String> = []) -> LyricsChain {
        let all: [any LyricsProvider] = [
            LRCLIBProvider(http: http),
            MusixmatchProvider(http: http),
            NetEaseProvider(http: http),
        ]
        return LyricsChain(providers: all.filter { !disabled.contains($0.name) })
    }

    /// The names of the standard providers, in order (Settings lists them).
    public static let standardProviderNames = ["LRCLIB", "Musixmatch", "NetEase"]

    /// Looks the song up with its own metadata and, at the same time, with
    /// the noise stripped ("feat.", "Remastered", "(Live)"). For Spotify, a
    /// faster result that cannot prove the recording is handed to
    /// `onProvisional` while the lookup waits for one that can.
    public func fetch(_ query: LyricsQuery, onProvisional: (@Sendable (LyricsResponse) async -> Void)? = nil) async -> LyricsLookup {
        var queries = [query]
        let cleaned = query.sanitized
        if query.spotifyTrackID == nil, cleaned != query { queries.append(cleaned) }
        return await attempt(queries, onProvisional: onProvisional)
    }

    private typealias Item = (rank: Int, queryIndex: Int, source: String, result: LyricsResult, authority: LyricsTimingAuthority, failed: Bool)

    private func attempt(_ queries: [LyricsQuery], onProvisional: (@Sendable (LyricsResponse) async -> Void)?) async -> LyricsLookup {
        let providers = self.providers
        guard !providers.isEmpty else { return LyricsLookup(response: .none) }
        let canonicalRanks = Set(providers.indices.filter { providers[$0].supportsCanonicalSpotifyLookup })
        let waitsForCanonical = queries.first?.spotifyTrackID != nil && !canonicalRanks.isEmpty

        return await withTaskGroup(of: Item.self) { group in
            for (rank, provider) in providers.enumerated() {
                for (queryIndex, query) in queries.enumerated() {
                    group.addTask {
                        let fetched: LyricsResponse
                        var failed = false
                        do {
                            fetched = try await provider.fetchResponse(query)
                        } catch is CancellationError {
                            fetched = .none
                        } catch {
                            Self.log.debug("\(provider.name) failed: \(error.localizedDescription)")
                            fetched = LyricsResponse(result: .notFound, source: provider.name)
                            failed = true
                        }
                        var result = fetched.result
                        if case .synced(let lyrics) = result, !Self.isPlausible(lyrics, for: query.duration) {
                            result = .notFound
                        }
                        return (rank, queryIndex, fetched.source, result, fetched.timingAuthority, failed)
                    }
                }
            }

            func preferred(_ a: Item, over b: Item?) -> Bool {
                guard let b else { return true }
                return (a.rank, a.queryIndex) < (b.rank, b.queryIndex)
            }
            func taskID(rank: Int, queryIndex: Int) -> Int { rank * queries.count + queryIndex }
            func allCompleted(queryIndex: Int, before rank: Int? = nil, in completed: Set<Int>) -> Bool {
                let ranks = rank.map { 0..<$0 } ?? providers.indices
                return ranks.allSatisfy { completed.contains(taskID(rank: $0, queryIndex: queryIndex)) }
            }
            func response(_ item: Item) -> LyricsLookup {
                LyricsLookup(response: LyricsResponse(result: item.result, source: item.source, timingAuthority: item.authority))
            }
            func canonicalCompleted(in completed: Set<Int>) -> Bool {
                canonicalRanks.allSatisfy { completed.contains(taskID(rank: $0, queryIndex: 0)) }
            }

            var completed: Set<Int> = []
            var failures = 0
            var bestExactSynced: Item?
            var bestSanitizedSynced: Item?
            var bestPlain: Item?
            var bestInstrumental: Item?
            // 0 nothing, 1 plain, 2 synced: only upgrades are published.
            var provisionalQuality = 0
            for await item in group {
                completed.insert(taskID(rank: item.rank, queryIndex: item.queryIndex))
                if item.failed { failures += 1 }
                switch item.result {
                case .synced:
                    if item.queryIndex == 0 {
                        if item.authority == .canonicalRecording || !waitsForCanonical {
                            group.cancelAll()
                            return response(item)
                        }
                        if preferred(item, over: bestExactSynced) { bestExactSynced = item }
                        if provisionalQuality < 2, let provisional = bestExactSynced, let onProvisional {
                            provisionalQuality = 2
                            await onProvisional(response(provisional).response)
                        }
                    } else if preferred(item, over: bestSanitizedSynced) {
                        bestSanitizedSynced = item
                    }
                case .plain:
                    if preferred(item, over: bestPlain) { bestPlain = item }
                    if waitsForCanonical, item.queryIndex == 0, provisionalQuality == 0, let plain = bestPlain, let onProvisional {
                        provisionalQuality = 1
                        await onProvisional(response(plain).response)
                    }
                case .instrumental:
                    if preferred(item, over: bestInstrumental) { bestInstrumental = item }
                case .notFound:
                    break
                }

                // A fuzzy source may answer first, but it cannot outrun the
                // provider that can prove the Spotify recording.
                if waitsForCanonical, canonicalCompleted(in: completed), let exact = bestExactSynced {
                    group.cancelAll()
                    return response(exact)
                }
                // A cleaned title can name another edit: only once every
                // provider missed the original metadata.
                if queries.count > 1, allCompleted(queryIndex: 0, in: completed), let sanitized = bestSanitizedSynced,
                   allCompleted(queryIndex: sanitized.queryIndex, before: sanitized.rank, in: completed) {
                    group.cancelAll()
                    return response(sanitized)
                }
            }
            if let exact = bestExactSynced { return response(exact) }
            if let synced = bestSanitizedSynced { return response(synced) }
            if let plain = bestPlain { return response(plain) }
            if let instrumental = bestInstrumental { return response(instrumental) }
            let total = providers.count * queries.count
            return LyricsLookup(response: .none, allFailed: failures == total)
        }
    }

    /// The last line may come before the outro, but it cannot start after
    /// the recording has ended.
    static func isPlausible(_ lyrics: SyncedLyrics, for duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0, let last = lyrics.lines.last(where: { !$0.text.isEmpty }) else { return true }
        return last.start <= duration + 2
    }

    // MARK: Versions and search

    /// Every version the providers have for the song (for "Other Lyrics"):
    /// synced first, then the providers' order. A provider that fails or
    /// takes longer than `timeout` is left out.
    public func versions(for query: LyricsQuery, timeout: TimeInterval = 12) async -> [LyricsVersion] {
        await gather(timeout: timeout) { try await $0.versions(for: query) }
            .filter { version in version.duration.map(query.durationMatches) ?? true }
    }

    /// The providers' results for a title and an artist the user typed.
    public func search(_ query: LyricsQuery, timeout: TimeInterval = 12) async -> [LyricsVersion] {
        await gather(timeout: timeout) { try await $0.search(query) }
    }

    /// Loads a version listed by `versions` or `search`.
    public func lyrics(of version: LyricsVersion) async throws -> LyricsResult {
        if let lyrics = version.lyrics { return lyrics }
        guard let provider = providers.first(where: { $0.name == version.provider }) else { return .notFound }
        return try await provider.lyrics(of: version)
    }

    private func gather(timeout: TimeInterval, _ body: @escaping @Sendable (any LyricsProvider) async throws -> [LyricsVersion]) async -> [LyricsVersion] {
        let providers = self.providers
        let lists = await withTaskGroup(of: (Int, [LyricsVersion]).self) { group in
            for (rank, provider) in providers.enumerated() {
                group.addTask {
                    let found = await withTaskGroup(of: [LyricsVersion]?.self) { race in
                        race.addTask { (try? await body(provider)) ?? [] }
                        race.addTask {
                            try? await Task.sleep(for: .seconds(timeout))
                            return nil
                        }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        return first ?? []
                    }
                    return (rank, found)
                }
            }
            var lists: [(Int, [LyricsVersion])] = []
            for await list in group { lists.append(list) }
            return lists
        }
        var seen: Set<String> = []
        var merged: [(rank: Int, offset: Int, version: LyricsVersion)] = []
        for (rank, list) in lists {
            for (offset, version) in list.enumerated() where seen.insert(version.id).inserted {
                merged.append((rank, offset, version))
            }
        }
        func order(_ kind: LyricsVersion.Kind) -> Int {
            switch kind {
            case .synced: 0
            case .plain: 1
            case .unknown: 2
            case .instrumental: 3
            }
        }
        return merged
            .sorted { (order($0.version.kind), $0.rank, $0.offset) < (order($1.version.kind), $1.rank, $1.offset) }
            .map(\.version)
    }
}
