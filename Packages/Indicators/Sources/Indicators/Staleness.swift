import Foundation

/// Everything the staleness rule needs.  `now` is injected rather than
/// read from the clock so the rule stays a pure function and its tests
/// cannot flake.
public struct TrustInputs: Sendable, Equatable {
    public let asOf: Date
    public let now: Date
    public let staleAfter: TimeInterval

    /// When the credential backing this sample expires, or `nil` for a
    /// source that needs no credential.
    public let tokenExpiresAt: Date?

    /// When the rate-limit window this sample describes resets, or `nil`
    /// for a sample that describes no window.
    public let windowResetsAt: Date?

    public init(
        asOf: Date,
        now: Date,
        staleAfter: TimeInterval,
        tokenExpiresAt: Date?,
        windowResetsAt: Date?
    ) {
        self.asOf = asOf
        self.now = now
        self.staleAfter = staleAfter
        self.tokenExpiresAt = tokenExpiresAt
        self.windowResetsAt = windowResetsAt
    }
}

/// Whether a sample may still be shown.
///
/// All three conditions must hold.  A `nil` expiry or window means the
/// condition does not apply to this source, not that it has lapsed.
public func isTrusted(_ i: TrustInputs) -> Bool {
    guard i.now.timeIntervalSince(i.asOf) < i.staleAfter else { return false }
    if let token = i.tokenExpiresAt, token <= i.now { return false }
    if let window = i.windowResetsAt, window <= i.now { return false }
    return true
}
