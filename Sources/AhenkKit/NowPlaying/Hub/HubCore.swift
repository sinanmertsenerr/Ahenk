import Foundation

/// The hub's decisions as a pure state machine: providers report what they
/// see, the core merges reports that describe the same player, keeps track
/// of who started playing when, picks the player to follow, notices when
/// several play at once and routes commands. Time is passed in, so tests
/// drive it by hand; `nextDeadline` says when `tick` must run again.
public struct HubCore: Sendable {
    /// A player that pauses and resumes within this window keeps its start
    /// time (a song change can look like a short pause).
    public static let resumeGrace: TimeInterval = 2.5
    /// The followed player stays on screen this long after its source went
    /// quiet, so a gap between two songs does not flash an empty player.
    public static let vanishGrace: TimeInterval = 1.2
    /// A system report for a browser whose tabs the bridge reports is taken
    /// for another player only after it has matched none of them this long
    /// (the two sides learn about a new song a moment apart).
    public static let shadowGrace: TimeInterval = 4

    public private(set) var configuration: HubConfiguration
    public private(set) var state = HubState()

    private var priorities: [String: Int]
    private var reports: [String: [NowPlayingSnapshot]] = [:]
    /// Providers whose reports hide lower-priority reports of the same app.
    private var shadowing: Set<String> = []
    /// Lower-priority reports of a shadowed app that match none of its
    /// songs, waiting out `shadowGrace` (since when)…
    private var unmatchedSince: [String: Date] = [:]
    /// …and the ones that have waited it out and show.
    private var acceptedUnmatched: Set<String> = []
    private var starts: [PlayerID: StartRecord] = [:]
    private var lastPlayingAt: [PlayerID: Date] = [:]
    private var override: Override?
    private var answeredOverlap: Set<String>?
    private var expectations: [PlayerID: PlaybackExpectation] = [:]
    private var lingering: Lingering?
    private var conflictDeadline: Date?

    private struct StartRecord: Sendable {
        var since: Date
        var stoppedAt: Date?
    }

    private struct Override: Sendable {
        var player: PlayerID
        var at: Date
    }

    private struct Lingering: Sendable {
        var player: HubPlayer
        var until: Date
    }

    /// `priorities`: provider ID → rank; higher wins when two providers
    /// describe the same player (a music app's own provider over the
    /// system's Now Playing).
    public init(configuration: HubConfiguration = HubConfiguration(), priorities: [String: Int] = [:]) {
        self.configuration = configuration
        self.priorities = priorities
        state.selection = configuration.selection
    }

    public mutating func setPriority(_ priority: Int, for provider: String) {
        priorities[provider] = priority
    }

    /// `provider`'s reports for an app hide lower-priority reports for the
    /// same app that describe one of its songs: the browser extension knows
    /// each tab, while the system's Now Playing sees one of them and guesses
    /// the site. A system report that matches none of the tabs is another
    /// player in that browser (a site the extension does not know) and shows
    /// up after `shadowGrace`.
    public mutating func setShadowing(_ shadows: Bool, for provider: String) {
        if shadows { shadowing.insert(provider) } else { shadowing.remove(provider) }
    }

    // MARK: Inputs

    /// Everything `provider` sees right now (an empty list: nothing).
    public mutating func ingest(_ snapshots: [NowPlayingSnapshot], from provider: String, now: Date) {
        reports[provider] = snapshots
        refresh(now: now, allowLinger: true)
    }

    public mutating func removeProvider(_ provider: String, now: Date) {
        reports[provider] = nil
        refresh(now: now, allowLinger: false)
    }

    public mutating func setConfiguration(_ configuration: HubConfiguration, now: Date) {
        if configuration.selection != self.configuration.selection { override = nil }
        self.configuration = configuration
        refresh(now: now, allowLinger: false)
    }

    /// The user picked `player` (from the conflict question): follow it
    /// while it plays, until something else starts.
    public mutating func choose(_ player: PlayerID, now: Date) {
        override = Override(player: player, at: now)
        let playing = state.players.filter(\.isPlaying)
        if playing.count >= 2 { answeredOverlap = Self.signature(of: playing) }
        refresh(now: now, allowLinger: false)
    }

    /// Shows `expectation` for `player` until it is confirmed or expires.
    public mutating func expect(_ expectation: PlaybackExpectation, for player: PlayerID, now: Date) {
        expectations[player] = expectation
        refresh(now: now, allowLinger: false)
    }

    public mutating func dropExpectation(for player: PlayerID, now: Date) {
        guard expectations.removeValue(forKey: player) != nil else { return }
        refresh(now: now, allowLinger: false)
    }

    /// Re-evaluates time-based rules (conflict delay, expectations, the
    /// vanish grace).
    public mutating func tick(now: Date) {
        refresh(now: now, allowLinger: true)
    }

    /// When `tick` has to run next, if anything waits for time.
    public var nextDeadline: Date? {
        let shadows = unmatchedSince.values.map { $0.addingTimeInterval(Self.shadowGrace) }
        return ([conflictDeadline, lingering?.until] + expectations.values.map(\.until) + shadows).compactMap { $0 }.min()
    }

    // MARK: Routing

    /// The provider that should carry out `command` on `player`: the most
    /// authoritative one whose report supports it.
    public func provider(for command: PlaybackCommand, on player: PlayerID) -> String? {
        candidates(for: player).first { $0.snapshot.capabilities.supports(command) }?.provider
    }

    /// Providers that currently describe `player`, most authoritative first.
    public func providers(reporting player: PlayerID) -> [String] {
        candidates(for: player).map(\.provider)
    }

    private func candidates(for player: PlayerID) -> [(provider: String, snapshot: NowPlayingSnapshot)] {
        var result: [(provider: String, snapshot: NowPlayingSnapshot)] = []
        for (provider, snapshots) in reports {
            for snapshot in snapshots where PlayerID(snapshot: snapshot) == player {
                result.append((provider, snapshot))
            }
        }
        return result.sorted { ordered($0.provider, $1.provider) }
    }

    private func ordered(_ a: String, _ b: String) -> Bool {
        let pa = priorities[a] ?? 0
        let pb = priorities[b] ?? 0
        return pa != pb ? pa > pb : a < b
    }

    // MARK: Evaluation

    private mutating func refresh(now: Date, allowLinger: Bool) {
        var grouped: [PlayerID: [(provider: String, snapshot: NowPlayingSnapshot)]] = [:]
        for (provider, snapshots) in visibleReports(now: now) {
            for snapshot in snapshots {
                grouped[PlayerID(snapshot: snapshot), default: []].append((provider, snapshot))
            }
        }

        var players: [HubPlayer] = []
        var present = Set<PlayerID>()
        for (id, entries) in grouped where !configuration.ignoredSources.contains(id.source) {
            let sorted = entries.sorted { ordered($0.provider, $1.provider) }
            var merged = Self.merge(sorted.map(\.snapshot))
            if let expectation = expectations[id] {
                if expectation.until <= now || !expectation.track.isSameSong(as: merged.track)
                    || expectation.isConfirmed(by: merged, at: now) {
                    expectations[id] = nil
                } else {
                    merged = expectation.apply(to: merged)
                }
            }
            present.insert(id)
            players.append(HubPlayer(id: id, snapshot: merged, providerIDs: sorted.map(\.provider)))
        }
        expectations = expectations.filter { present.contains($0.key) }

        // Who plays since when.
        for index in players.indices {
            let id = players[index].id
            if players[index].isPlaying {
                if let record = starts[id], let stopped = record.stoppedAt {
                    starts[id] = now.timeIntervalSince(stopped) <= Self.resumeGrace
                        ? StartRecord(since: record.since, stoppedAt: nil)
                        : StartRecord(since: now, stoppedAt: nil)
                } else if starts[id] == nil {
                    starts[id] = StartRecord(since: now, stoppedAt: nil)
                }
                lastPlayingAt[id] = now
                players[index].playingSince = starts[id]?.since
            } else if let record = starts[id], record.stoppedAt == nil {
                starts[id] = StartRecord(since: record.since, stoppedAt: now)
            }
            players[index].lastPlayingAt = lastPlayingAt[id]
        }
        for (id, record) in starts where !present.contains(id) && record.stoppedAt == nil {
            starts[id] = StartRecord(since: record.since, stoppedAt: now)
        }
        starts = starts.filter { _, record in
            record.stoppedAt.map { now.timeIntervalSince($0) <= Self.resumeGrace } ?? true
        }
        lastPlayingAt = lastPlayingAt.filter { present.contains($0.key) }
        players.sort(by: Self.precedes)

        let playing = players.filter(\.isPlaying)
        if let current = override {
            let gone = !players.contains { $0.id == current.player }
            let overtaken = playing.contains { ($0.playingSince ?? .distantPast) > current.at }
            if gone || overtaken { override = nil }
        }

        // Several at once?
        conflictDeadline = nil
        var conflict: PlaybackConflict?
        // The player of the source the user chose, while it has a song.
        let preferred = configuration.preferredSource.flatMap { source in players.first { $0.id.source == source }?.id }
        if playing.count >= 2, configuration.selection == .automatic, configuration.askWhenSeveralPlay, preferred == nil {
            let signature = Self.signature(of: playing)
            let overlapSince = playing.compactMap(\.playingSince).max() ?? now
            let answered = answeredOverlap == signature
                || (override.map { choice in playing.contains { $0.id == choice.player } } ?? false)
            if !answered {
                let askAt = overlapSince.addingTimeInterval(configuration.conflictDelay)
                if now >= askAt {
                    conflict = PlaybackConflict(players: playing.map(\.id), since: askAt)
                } else {
                    conflictDeadline = askAt
                }
            }
        } else if playing.count < 2 {
            answeredOverlap = nil
        }

        // Whom to follow.
        var active: PlayerID?
        switch configuration.selection {
        case .automatic:
            if let choice = override, playing.contains(where: { $0.id == choice.player }) {
                active = choice.player
            } else if let preferred {
                active = preferred
            } else if let newest = playing.first {
                active = newest.id
            } else if let previous = state.activeID, present.contains(previous) {
                active = previous
            } else {
                active = players.first?.id
            }
        case .pinned(let source):
            active = players.first { $0.id.source == source }?.id
        }

        // Keep the followed player a moment after it went quiet.
        if allowLinger, active == nil, let previous = state.active, !present.contains(previous.id),
           !configuration.ignoredSources.contains(previous.id.source), lingering?.player.id != previous.id {
            lingering = Lingering(player: previous, until: now.addingTimeInterval(Self.vanishGrace))
        }
        if let held = lingering {
            if active != nil || now >= held.until || present.contains(held.player.id) || !allowLinger {
                lingering = nil
            } else {
                players.append(held.player)
                active = held.player.id
            }
        }

        state = HubState(activeID: active, players: players, conflict: conflict, selection: configuration.selection)
    }

    /// The reports without the ones a shadowing provider hides.
    private mutating func visibleReports(now: Date) -> [String: [NowPlayingSnapshot]] {
        var shadows: [String: (priority: Int, snapshots: [NowPlayingSnapshot])] = [:]
        for provider in shadowing {
            let priority = priorities[provider] ?? 0
            for snapshot in reports[provider] ?? [] {
                guard let app = snapshot.bundleIdentifier else { continue }
                var entry = shadows[app] ?? (priority, [])
                entry.priority = max(entry.priority, priority)
                entry.snapshots.append(snapshot)
                shadows[app] = entry
            }
        }
        guard !shadows.isEmpty else {
            unmatchedSince = [:]
            acceptedUnmatched = []
            return reports
        }
        var visible = reports
        var pending: [String: Date] = [:]
        var accepted: Set<String> = []
        for (provider, snapshots) in reports where !shadowing.contains(provider) {
            let priority = priorities[provider] ?? 0
            visible[provider] = snapshots.filter { snapshot in
                guard let app = snapshot.bundleIdentifier, let shadow = shadows[app], priority < shadow.priority else { return true }
                if snapshot.track.title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
                if shadow.snapshots.contains(where: { Self.describesSameSong(snapshot, $0) }) { return false }
                let track = snapshot.track
                let key = "\(provider)|\(app)|" + TrackMatching.metadataKey(title: track.title, artist: track.artist, album: "")
                let since = unmatchedSince[key] ?? now
                if acceptedUnmatched.contains(key) || now.timeIntervalSince(since) >= Self.shadowGrace {
                    accepted.insert(key)
                    return true
                }
                pending[key] = since
                return false
            }
        }
        unmatchedSince = pending
        acceptedUnmatched = accepted
        return visible
    }

    /// Whether a system report and a tab describe one song, whatever source
    /// each names (the system's guess is often "another app"): the same core
    /// title, or one containing the other (a site suffix, a tag), and
    /// artists that agree when both are known.
    static func describesSameSong(_ guess: NowPlayingSnapshot, _ tab: NowPlayingSnapshot) -> Bool {
        let a = TrackMatching.coreTitle(guess.track.title)
        let b = TrackMatching.coreTitle(tab.track.title)
        guard !a.isEmpty, !b.isEmpty else { return false }
        func overlaps(_ x: String, _ y: String) -> Bool {
            if x == y { return true }
            let (short, long) = x.count <= y.count ? (x, y) : (y, x)
            return short.count >= 4 && long.contains(short)
        }
        guard overlaps(a, b) else { return false }
        let artistA = TrackMatching.normalized(guess.track.artist)
        let artistB = TrackMatching.normalized(tab.track.artist)
        return artistA.isEmpty || artistB.isEmpty || overlaps(artistA, artistB)
    }

    /// Playing first, newest start first; then paused, most recently
    /// playing first.
    private static func precedes(_ a: HubPlayer, _ b: HubPlayer) -> Bool {
        if a.isPlaying != b.isPlaying { return a.isPlaying }
        let keyA = a.isPlaying ? a.playingSince : a.lastPlayingAt
        let keyB = b.isPlaying ? b.playingSince : b.lastPlayingAt
        if keyA != keyB { return (keyA ?? .distantPast) > (keyB ?? .distantPast) }
        return a.id.description < b.id.description
    }

    private static func signature(of playing: [HubPlayer]) -> Set<String> {
        Set(playing.map { "\($0.id)@\($0.playingSince?.timeIntervalSinceReferenceDate ?? 0)" })
    }

    /// The most authoritative report, completed from the others where they
    /// describe the same song: a known position, shuffle, repeat, like,
    /// the process, the cover, a missing album or duration. Commands are the
    /// union (routing picks the provider that can carry each one).
    static func merge(_ snapshots: [NowPlayingSnapshot]) -> NowPlayingSnapshot {
        var merged = snapshots[0]
        for other in snapshots.dropFirst() {
            guard other.isSameTrack(as: merged) else { continue }
            if !merged.isPositionKnown, other.isPositionKnown, other.isPlaying == merged.isPlaying {
                merged.elapsedTime = other.elapsedTime
                merged.timestamp = other.timestamp
                merged.isPositionKnown = true
            }
            merged.isShuffled = merged.isShuffled ?? other.isShuffled
            merged.repeatMode = merged.repeatMode ?? other.repeatMode
            merged.isLiked = merged.isLiked ?? other.isLiked
            merged.processIdentifier = merged.processIdentifier ?? other.processIdentifier
            if merged.artworkData == nil, merged.track.artworkURL == nil {
                merged.artworkData = other.artworkData
                merged.artworkIdentifier = other.artworkIdentifier
            }
            if merged.track.album.isEmpty { merged.track.album = other.track.album }
            if merged.track.duration == 0 { merged.track.duration = other.track.duration }
            if merged.contentKind == .unknown { merged.contentKind = other.contentKind }
            merged.songVideoKind = merged.songVideoKind ?? other.songVideoKind
            merged.capabilities.formUnion(other.capabilities)
        }
        return merged
    }
}
