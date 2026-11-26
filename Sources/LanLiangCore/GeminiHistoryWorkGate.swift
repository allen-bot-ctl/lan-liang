import Foundation

/// Main-thread policy for foreground history work; callers do not request for startup,
/// timers or pointer previews. Quota work is independent. Times are monotonic.
struct GeminiHistoryWorkGate {
    static let debounce: TimeInterval = 0.25
    static let foregroundCooldown: TimeInterval = 45
    static let manualCooldown: TimeInterval = 8

    private(set) var pendingAt: TimeInterval?
    private(set) var inFlight = false
    private var lastStarted: TimeInterval?

    /// Reentry while queued/running is coalesced, not retried indefinitely.
    mutating func request(now: TimeInterval, manual: Bool = false) -> Bool {
        guard pendingAt == nil, !inFlight else { return false }
        if let lastStarted, now - lastStarted < (manual ? Self.manualCooldown : Self.foregroundCooldown) { return false }
        pendingAt = now + Self.debounce
        return true
    }

    mutating func start(now: TimeInterval, visible: Bool) -> Bool {
        guard let pendingAt else { return false }
        self.pendingAt = nil
        guard visible, !inFlight, now >= pendingAt else { return false }
        inFlight = true
        lastStarted = now
        return true
    }

    mutating func cancelPending() { pendingAt = nil }
    mutating func finish() { inFlight = false }
}
