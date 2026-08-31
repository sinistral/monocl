import ClaudeUsage
import Foundation
import Indicators
import Observation
import PlatformStatus

/// Holds the latest raw samples and derives the three displayed readings.
///
/// Samples and readings are kept separate on purpose: thresholds are
/// applied in `revalidate`, so moving a threshold in Settings updates the
/// lights immediately rather than at the next poll.
@MainActor
@Observable
final class IndicatorStore {
    // Displayed state.
    private(set) var session: Reading
    private(set) var week: Reading
    private(set) var platform: Reading
    private(set) var usageFailure: UsageFailure?
    private(set) var statusFailure: StatusFailure?
    private(set) var usagePollingStopped = false

    // Settings, applied on revalidate.
    var thresholds: Thresholds
    var staleAfter: TimeInterval

    // Raw samples.
    private var sessionSample: UsageSample?
    private var weekSample: UsageSample?
    private var usageAsOf: Date?
    private var tokenExpiresAt: Date?
    private var statusSample: StatusSample?
    private var statusAsOf: Date?

    init(thresholds: Thresholds = .default, staleAfter: TimeInterval = 300) {
        self.thresholds = thresholds
        self.staleAfter = staleAfter
        let epoch = Date(timeIntervalSince1970: 0)
        session = .unknown(detail: Self.noReading, asOf: epoch)
        week = .unknown(detail: Self.noReading, asOf: epoch)
        platform = .unknown(detail: Self.noReading, asOf: epoch)
    }

    // Not actor-isolated: TooltipComposerTests reads this from a
    // nonisolated test suite, and a constant string carries no actor state.
    nonisolated static let noReading = "no recent reading"

    func apply(_ outcome: UsageOutcome) {
        switch outcome {
        case let .samples(session, week, asOf, tokenExpiresAt):
            sessionSample = session
            weekSample = week
            usageAsOf = asOf
            self.tokenExpiresAt = tokenExpiresAt
            usageFailure = nil
        case let .failure(failure):
            sessionSample = nil
            weekSample = nil
            usageAsOf = nil
            tokenExpiresAt = nil
            usageFailure = failure
            if failure.stopsPolling { usagePollingStopped = true }
        }
    }

    func apply(_ outcome: StatusOutcome) {
        switch outcome {
        case let .sample(sample, asOf):
            statusSample = sample
            statusAsOf = asOf
            statusFailure = nil
        case let .failure(failure):
            statusSample = nil
            statusAsOf = nil
            statusFailure = failure
        }
    }

    /// Discards every sample.  Called on wake, when any held reading
    /// describes a moment that may be hours old.
    func clearOnWake(now: Date) {
        sessionSample = nil
        weekSample = nil
        usageAsOf = nil
        tokenExpiresAt = nil
        statusSample = nil
        statusAsOf = nil
        revalidate(now: now)
    }

    func retryUsage() {
        usagePollingStopped = false
        usageFailure = nil
    }

    /// Recomputes the three readings from the current samples.
    func revalidate(now: Date) {
        session = usageReading(sessionSample, now: now)
        week = usageReading(weekSample, now: now)
        platform = platformReading(now: now)
    }

    private func usageReading(_ sample: UsageSample?, now: Date) -> Reading {
        let detail = usageFailure?.menuText ?? Self.noReading
        guard let sample, let asOf = usageAsOf else {
            return .unknown(detail: detail, asOf: now)
        }
        let trusted = isTrusted(TrustInputs(
            asOf: asOf,
            now: now,
            staleAfter: staleAfter,
            tokenExpiresAt: tokenExpiresAt,
            windowResetsAt: sample.resetsAt
        ))
        guard trusted else { return .unknown(detail: detail, asOf: asOf) }
        return Reading(
            state: thresholds.state(forPercent: sample.percent),
            detail: "\(Int(sample.percent.rounded()))%",
            asOf: asOf
        )
    }

    private func platformReading(now: Date) -> Reading {
        let detail = statusFailure?.menuText ?? Self.noReading
        guard let sample = statusSample, let asOf = statusAsOf else {
            return .unknown(detail: detail, asOf: now)
        }
        let trusted = isTrusted(TrustInputs(
            asOf: asOf,
            now: now,
            staleAfter: staleAfter,
            tokenExpiresAt: nil,
            windowResetsAt: nil
        ))
        guard trusted else { return .unknown(detail: detail, asOf: asOf) }
        return Reading(state: sample.state, detail: sample.description, asOf: asOf)
    }

    /// Convenience for the renderer: the three states in display order.
    var states: [IndicatorState] { [session.state, week.state, platform.state] }
}

extension IndicatorStore {
    var sessionResetsAt: Date? { sessionSample?.resetsAt }
    var weekResetsAt: Date? { weekSample?.resetsAt }
}
