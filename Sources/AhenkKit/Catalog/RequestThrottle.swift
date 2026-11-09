import Foundation

/// Keeps a public service's rate limit: at most `limit` requests in any
/// `window`. A request that would have to wait longer than `maximumWait`
/// fails at once with `CatalogError.rateLimited` instead of queueing (a
/// search result that arrives a minute late is useless). After the service
/// itself says "too many" (HTTP 429/403), every request fails until the
/// back-off ends.
public actor RequestThrottle {
    public let limit: Int
    public let window: TimeInterval
    public let maximumWait: TimeInterval
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Start times of recent and reserved requests, ascending.
    private var slots: [Date] = []
    private var blockedUntil: Date?

    public init(
        limit: Int,
        per window: TimeInterval,
        maximumWait: TimeInterval = 4,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.limit = max(1, limit)
        self.window = max(0.001, window)
        self.maximumWait = max(0, maximumWait)
        self.clock = clock
        self.sleep = sleep
    }

    /// Waits for a free slot (reserving it first, so concurrent callers
    /// never share one), or throws `CatalogError.rateLimited`.
    public func acquire() async throws {
        let now = clock()
        if let blockedUntil, blockedUntil > now { throw CatalogError.rateLimited }
        blockedUntil = nil
        slots.removeAll { now.timeIntervalSince($0) >= window }
        let start = slots.count < limit ? now : max(now, slots[slots.count - limit].addingTimeInterval(window))
        let wait = start.timeIntervalSince(now)
        guard wait <= maximumWait else { throw CatalogError.rateLimited }
        slots.append(start)
        if wait > 0 { try await sleep(wait) }
    }

    /// The service answered "too many requests": nothing goes out for
    /// `seconds`.
    public func backOff(for seconds: TimeInterval) {
        let until = clock().addingTimeInterval(max(0, seconds))
        blockedUntil = max(blockedUntil ?? .distantPast, until)
    }

    /// How long a request starting now would wait (`nil`: it would fail).
    public func delay() -> TimeInterval? {
        let now = clock()
        if let blockedUntil, blockedUntil > now { return nil }
        let recent = slots.filter { now.timeIntervalSince($0) < window }
        guard recent.count >= limit else { return 0 }
        let wait = recent[recent.count - limit].addingTimeInterval(window).timeIntervalSince(now)
        return wait <= maximumWait ? max(0, wait) : nil
    }
}
