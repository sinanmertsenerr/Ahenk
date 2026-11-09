import Foundation
import os
import Testing
@testable import AhenkKit

// Every line here is invented for the tests.

/// A provider that answers from a table and counts its calls.
final class ScriptedLyricsProvider: LyricsProvider, Sendable {
    let name: String
    let supportsCanonicalSpotifyLookup: Bool
    private let answer: @Sendable (LyricsQuery) throws -> LyricsResponse
    private let delay: Duration
    private let calls = OSAllocatedUnfairLock(initialState: [LyricsQuery]())

    init(_ name: String, canonical: Bool = false, delay: Duration = .zero, answer: @escaping @Sendable (LyricsQuery) throws -> LyricsResponse) {
        self.name = name
        self.supportsCanonicalSpotifyLookup = canonical
        self.delay = delay
        self.answer = answer
    }

    var queries: [LyricsQuery] { calls.withLock { $0 } }

    func fetch(_ query: LyricsQuery) async throws -> LyricsResult {
        try await fetchResponse(query).result
    }

    func fetchResponse(_ query: LyricsQuery) async throws -> LyricsResponse {
        calls.withLock { $0.append(query) }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try answer(query)
    }
}

enum ChainFixtures {
    static let synced = LRCParser.parse(LyricsFixtures.lrc)
    static let query = LyricsQuery(title: "Paper Lanterns (Live)", artist: "The Tin Orchard", duration: 192)

    static func response(_ result: LyricsResult, from name: String, authority: LyricsTimingAuthority = .unverified) -> LyricsResponse {
        LyricsResponse(result: result, source: name, timingAuthority: authority)
    }
}

@Suite("Lyrics chain")
struct LyricsChainTests {
    @Test("Synced lyrics beat plain ones; the first provider wins among equals")
    func policy() async {
        let first = ScriptedLyricsProvider("A") { _ in ChainFixtures.response(.plain("words"), from: "A") }
        let second = ScriptedLyricsProvider("B") { _ in ChainFixtures.response(.synced(ChainFixtures.synced), from: "B") }
        let lookup = await LyricsChain(providers: [first, second]).fetch(LyricsQuery(title: "Paper Lanterns", artist: "The Tin Orchard"))
        #expect(lookup.response.source == "B" && !lookup.allFailed)
        let plainOnly = await LyricsChain(providers: [first]).fetch(LyricsQuery(title: "x", artist: "y"))
        #expect(plainOnly.response.result == .plain("words"))
    }

    @Test("The cleaned-up title counts only after every provider missed the original")
    func sanitized() async {
        let provider = ScriptedLyricsProvider("A") { query in
            query.title == "Paper Lanterns" ? ChainFixtures.response(.synced(ChainFixtures.synced), from: "A") : .none
        }
        let lookup = await LyricsChain(providers: [provider]).fetch(ChainFixtures.query)
        #expect(lookup.response.source == "A")
        #expect(Set(provider.queries.map(\.title)) == ["Paper Lanterns (Live)", "Paper Lanterns"])
    }

    @Test("Lyrics that start after the song ended belong to another recording")
    func plausibility() async {
        let late = SyncedLyrics(lines: [LyricLine(start: 300, text: "Far too late")])
        let provider = ScriptedLyricsProvider("A") { _ in ChainFixtures.response(.synced(late), from: "A") }
        let lookup = await LyricsChain(providers: [provider]).fetch(LyricsQuery(title: "t", artist: "a", duration: 200))
        #expect(lookup.response.result == .notFound)
    }

    @Test("When every provider fails the lookup says so; a provider that throws is skipped")
    func failures() async {
        let broken = ScriptedLyricsProvider("A") { _ in throw URLError(.notConnectedToInternet) }
        let failed = await LyricsChain(providers: [broken]).fetch(LyricsQuery(title: "t", artist: "a"))
        #expect(failed.allFailed && failed.response.result == .notFound)
        let working = ScriptedLyricsProvider("B") { _ in ChainFixtures.response(.synced(ChainFixtures.synced), from: "B") }
        let mixed = await LyricsChain(providers: [broken, working]).fetch(LyricsQuery(title: "t", artist: "a"))
        #expect(!mixed.allFailed && mixed.response.source == "B")
        let none = await LyricsChain(providers: [working]).fetch(LyricsQuery(title: "t", artist: "a"))
        #expect(!none.allFailed)
    }

    @Test("A Spotify lookup waits for the provider that can prove the recording")
    func canonical() async {
        let fast = ScriptedLyricsProvider("Fast") { _ in ChainFixtures.response(.synced(ChainFixtures.synced.shifted(by: 1)), from: "Fast") }
        let proving = ScriptedLyricsProvider("Proving", canonical: true, delay: .milliseconds(80)) { _ in
            ChainFixtures.response(.synced(ChainFixtures.synced), from: "Proving", authority: .canonicalRecording)
        }
        let provisional = OSAllocatedUnfairLock(initialState: [String]())
        let query = LyricsQuery(title: "t", artist: "a", spotifyTrackID: "0123456789abcdefABCDEF")
        let lookup = await LyricsChain(providers: [fast, proving]).fetch(query) { response in
            provisional.withLock { $0.append(response.source) }
        }
        #expect(lookup.response.source == "Proving" && lookup.response.timingAuthority == .canonicalRecording)
        #expect(provisional.withLock { $0 } == ["Fast"], "the faster answer shows meanwhile")
    }

    @Test("Versions from every provider, synced first, without duplicates or other lengths")
    func versions() async {
        func version(_ provider: String, _ reference: String, _ kind: LyricsVersion.Kind, duration: Double = 192) -> LyricsVersion {
            LyricsVersion(provider: provider, reference: reference, title: "Paper Lanterns", artist: "The Tin Orchard", duration: duration, kind: kind)
        }
        struct Listing: LyricsProvider {
            let name: String
            let list: [LyricsVersion]
            func fetch(_ query: LyricsQuery) async throws -> LyricsResult { .notFound }
            func versions(for query: LyricsQuery) async throws -> [LyricsVersion] { list }
        }
        let chain = LyricsChain(providers: [
            Listing(name: "A", list: [version("A", "1", .plain), version("A", "2", .synced), version("A", "2", .synced)]),
            Listing(name: "B", list: [version("B", "1", .synced), version("B", "9", .synced, duration: 260)]),
        ])
        let found = await chain.versions(for: LyricsFixtures.query)
        #expect(found.map(\.id) == ["A\u{1}2", "B\u{1}1", "A\u{1}1"])
    }

    @Test("Standard chain: LRCLIB, Musixmatch, NetEase, minus the ones turned off")
    func standard() {
        let fetcher = RouteFetcher()
        #expect(LyricsChain.standard(http: fetcher).providers.map(\.name) == LyricsChain.standardProviderNames)
        #expect(LyricsChain.standard(http: fetcher, disabled: ["Musixmatch"]).providers.map(\.name) == ["LRCLIB", "NetEase"])
    }
}

@Suite("Lyrics consensus")
struct LyricsConsensusTests {
    static func candidate(_ shift: Double, score: Int) -> LyricsConsensus.Candidate {
        .init(lyrics: ChainFixtures.synced.shifted(by: shift), score: score)
    }

    @Test("Fewer than three timelines, or all in agreement: no vote")
    func noVote() {
        #expect(LyricsConsensus.pick([Self.candidate(0, score: 1), Self.candidate(2, score: 2)]) == nil)
        #expect(LyricsConsensus.pick([Self.candidate(0, score: 1), Self.candidate(0.1, score: 2), Self.candidate(-0.1, score: 3)]) == nil)
    }

    @Test("A shifted copy is voted out even with the best score")
    func vote() {
        let pick = LyricsConsensus.pick([Self.candidate(1.5, score: 100), Self.candidate(0, score: 10), Self.candidate(0.05, score: 20)])
        #expect(pick == 2)
    }

    @Test("Too few shared lines: no vote")
    func fewLines() {
        let short = SyncedLyrics(lines: [LyricLine(start: 1, text: "Only one line here")])
        let candidates = [LyricsConsensus.Candidate(lyrics: short, score: 1), .init(lyrics: short.shifted(by: 2), score: 2), .init(lyrics: short, score: 3)]
        #expect(LyricsConsensus.pick(candidates) == nil)
    }
}
