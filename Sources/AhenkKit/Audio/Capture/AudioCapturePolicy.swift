import Foundation

/// macOS's "System Audio Recording Only" permission for Ahenk.
public enum AudioCapturePermission: String, Sendable, Equatable, CaseIterable {
    case authorized
    case denied
    /// macOS has not asked yet.
    case notDetermined
    /// The state cannot be read on this macOS.
    case unknown

    /// The answer of TCC's preflight check: 0 granted, 1 denied, 2 not
    /// decided yet.
    public init(preflightResult: Int) {
        switch preflightResult {
        case 0: self = .authorized
        case 1: self = .denied
        case 2: self = .notDetermined
        default: self = .unknown
        }
    }
}

/// The app whose sound Ahenk listens to, as the followed player names it.
public struct AudioTapTarget: Sendable, Hashable, CustomStringConvertible {
    public var source: MusicSource
    /// The app that plays (the music app or the browser).
    public var bundleIdentifier: String?
    /// The process that published Now Playing, when known.
    public var processIdentifier: Int32?

    public init(source: MusicSource, bundleIdentifier: String?, processIdentifier: Int32?) {
        self.source = source
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    public init(snapshot: NowPlayingSnapshot) {
        self.init(source: snapshot.track.source, bundleIdentifier: snapshot.bundleIdentifier, processIdentifier: snapshot.processIdentifier)
    }

    /// Something to look up among the audio processes.
    public var isResolvable: Bool { bundleIdentifier != nil || processIdentifier != nil }

    public var description: String {
        bundleIdentifier ?? processIdentifier.map { "pid \($0)" } ?? source.rawValue
    }
}

/// What to listen to.
public enum AudioTapRequest: Sendable, Equatable {
    /// The audio processes of one app (resolved when the tap is built).
    case app(AudioTapTarget)
    /// Every process except Ahenk: the app's sound could not be found.
    case everything(AudioTapTarget)
    /// The demo synthesizer (`--demo`); no tap.
    case demo

    public var target: AudioTapTarget? {
        switch self {
        case .app(let target), .everything(let target): target
        case .demo: nil
        }
    }
}

/// Why Ahenk is or is not listening, for Settings and the menu.
public enum AudioCaptureState: Sendable, Equatable {
    /// Nothing plays (or the tap was released after the grace period).
    case idle
    /// The followed player plays a video, a podcast or an advert.
    case notMusic
    case needsPermission
    case denied
    case listening(AudioTapRequest)
    /// Building the tap failed; trying again soon.
    case retrying
}

/// Decides when Ahenk listens and to what, from the followed player, the
/// permission and time. Pure: the app's engine feeds it events and carries
/// out ``request``.
///
/// - Music plays (music or unlabelled content, playing) → listen to the
///   player's app, gate open.
/// - Paused, stopped, or not music → gate closed at once (features fall to
///   silence); the tap stays for ``Configuration/idleGrace`` so a short
///   pause costs no rebuild, then goes away. Nothing runs while idle.
/// - Another player starts → retarget.
/// - The app's processes cannot be found for a moment, or its tap stays
///   digitally silent while the player says it plays → look again once,
///   then listen to everything except Ahenk until the player changes.
/// - Building the tap fails → back off (2 s, 5 s, 15 s, 30 s) and retry.
public struct AudioCapturePolicy: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var idleGrace: Double = 8
        /// Digital silence while playing before the processes are resolved again…
        public var silenceRetarget: Double = 3
        /// …and before falling back to everything.
        public var silenceFallback: Double = 6
        /// How long a target may stay unresolved before the fallback.
        public var unresolvedFallback: Double = 2.5
        public var retryDelays: [Double] = [2, 5, 15, 30]

        public init() {}
    }

    public let configuration: Configuration
    /// False for the demo, which needs no permission.
    public let requiresPermission: Bool

    public private(set) var request: AudioTapRequest?
    public private(set) var isGateOpen = false
    /// Bumped when the engine should look up the processes again even
    /// though the request did not change.
    public private(set) var resolveGeneration = 0
    public private(set) var state: AudioCaptureState = .idle

    private var permission: AudioCapturePermission = .unknown
    /// The user asked to listen while the permission could not be read.
    private var userAllowedListening = false
    private var current: AudioTapTarget?
    private var wantsAudio = false
    private var isMusic = true
    /// The target of the newest music that played; kept through the grace period.
    private var active: AudioTapTarget?
    private var idleSince: Double?
    private var fallback: AudioTapTarget?
    private var resolvedAgainFor: AudioTapTarget?
    private var unresolvedSince: Double?
    private var failures = 0
    private var retryAt: Double?

    public init(configuration: Configuration = Configuration(), requiresPermission: Bool = true) {
        self.configuration = configuration
        self.requiresPermission = requiresPermission
    }

    /// Music the light reacts to: music, or a player that does not say
    /// (mostly music) unless it is a video site.
    public static func reactsTo(_ snapshot: NowPlayingSnapshot) -> Bool {
        switch snapshot.contentKind {
        case .music: true
        case .unknown: snapshot.track.source != .youtube
        case .video, .podcast, .advertisement: false
        }
    }

    public var nextDeadline: Double? {
        var deadlines: [Double] = []
        if let idleSince, request != nil { deadlines.append(idleSince + configuration.idleGrace) }
        if let retryAt { deadlines.append(retryAt) }
        if let unresolvedSince, fallback == nil { deadlines.append(unresolvedSince + configuration.unresolvedFallback) }
        return deadlines.min()
    }

    // MARK: Inputs

    public mutating func update(snapshot: NowPlayingSnapshot?, now: Double) {
        current = snapshot.map(AudioTapTarget.init(snapshot:))
        isMusic = snapshot.map(Self.reactsTo) ?? true
        wantsAudio = snapshot.map { $0.isPlaying && Self.reactsTo($0) } ?? false
        evaluate(now: now)
    }

    public mutating func update(permission: AudioCapturePermission, now: Double) {
        self.permission = permission
        evaluate(now: now)
    }

    /// The user pressed "Allow Listening" while macOS could not tell the
    /// permission state: listen and let macOS ask if it needs to.
    public mutating func allowListening(now: Double) {
        userAllowedListening = true
        evaluate(now: now)
    }

    /// No audio process of the target was found.
    public mutating func noteUnresolved(now: Double) {
        if unresolvedSince == nil { unresolvedSince = now }
        evaluate(now: now)
    }

    public mutating func noteResolved(now: Double) {
        unresolvedSince = nil
        evaluate(now: now)
    }

    /// The tap delivered nothing but digital silence for `seconds` while
    /// the gate was open.
    public mutating func noteDigitalSilence(_ seconds: Double, now: Double) {
        guard isGateOpen, case .app(let target) = request else { return }
        if seconds >= configuration.silenceFallback, resolvedAgainFor == target {
            fallback = target
        } else if seconds >= configuration.silenceRetarget, resolvedAgainFor != target {
            resolvedAgainFor = target
            resolveGeneration += 1
        }
        evaluate(now: now)
    }

    public mutating func noteTapFailed(now: Double) {
        failures += 1
        let delays = configuration.retryDelays
        retryAt = now + delays[min(failures - 1, delays.count - 1)]
        evaluate(now: now)
    }

    public mutating func noteTapStarted(now: Double) {
        failures = 0
        retryAt = nil
        evaluate(now: now)
    }

    public mutating func tick(now: Double) {
        evaluate(now: now)
    }

    // MARK: Rules

    private var mayListen: Bool {
        guard requiresPermission else { return true }
        switch permission {
        case .authorized: return true
        case .unknown: return userAllowedListening
        case .denied, .notDetermined: return false
        }
    }

    private mutating func evaluate(now: Double) {
        if wantsAudio, let current {
            if current != active {
                // A new player: start over.
                active = current
                fallback = nil
                resolvedAgainFor = nil
                unresolvedSince = nil
                failures = 0
                retryAt = nil
            }
            idleSince = nil
        } else if idleSince == nil {
            idleSince = now
        }
        if let retryAt, now >= retryAt { self.retryAt = nil }
        if let unresolvedSince, fallback == nil, let active,
           now - unresolvedSince >= configuration.unresolvedFallback {
            fallback = active
        }

        guard mayListen else {
            request = nil
            isGateOpen = false
            state = permission == .denied ? .denied : .needsPermission
            return
        }
        let expired = idleSince.map { now - $0 >= configuration.idleGrace } ?? false
        guard let active, !expired else {
            request = nil
            isGateOpen = false
            state = wantsAudio || isMusic ? .idle : .notMusic
            if expired { self.active = nil }
            return
        }
        guard retryAt == nil else {
            request = nil
            isGateOpen = false
            state = .retrying
            return
        }
        let next: AudioTapRequest
        if active.source == .demo {
            next = .demo
        } else if !active.isResolvable || fallback == active {
            next = .everything(active)
        } else {
            next = .app(active)
        }
        request = next
        isGateOpen = wantsAudio && current == active
        state = isGateOpen ? .listening(next) : (isMusic ? .idle : .notMusic)
    }
}
