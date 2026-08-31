import Foundation

/// How long to wait before the next attempt.
///
/// `retryAfter` only ever lengthens the wait.  Honouring a shorter
/// server-supplied value would let a misconfigured header defeat the
/// backoff entirely, which is the opposite of being a good citizen.
public func backoffInterval(
    base: TimeInterval,
    consecutiveFailures: Int,
    cap: TimeInterval = 900,
    retryAfter: TimeInterval? = nil
) -> TimeInterval {
    let exponent = max(0, consecutiveFailures - 1)
    let computed = min(base * pow(2, Double(exponent)), cap)
    guard let retryAfter else { return computed }
    return max(computed, retryAfter)
}
