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

/// The instant this sample stops being trustworthy: the earliest of its
/// age budget, the credential's expiry and the window's reset.
///
/// Non-optional deliberately.  `staleAfter` always bounds the result, so
/// there is no "nothing constrains it" case for a caller to branch on.
public func trustExpiry(_ i: TrustInputs) -> Date {
    min(
        i.asOf.addingTimeInterval(i.staleAfter),
        i.tokenExpiresAt ?? .distantFuture,
        i.windowResetsAt ?? .distantFuture
    )
}

/// Whether a sample may still be shown.
public func isTrusted(_ i: TrustInputs) -> Bool {
    trustExpiry(i) > i.now
}
