import Foundation
import Indicators
import ClaudeUsage
import PlatformStatus
import Testing
@testable import MonoCl

@MainActor
@Suite("Indicator store")
struct IndicatorStoreTests {
    private let now = Date(timeIntervalSince1970: 1_767_000_000)

    private func store(
        thresholds: Thresholds = .default,
        staleAfter: TimeInterval = 300
    ) -> IndicatorStore {
        IndicatorStore(thresholds: thresholds, staleAfter: staleAfter)
    }

    private func samples(
        session: Double = 76,
        week: Double = 20,
        resetsIn: TimeInterval = 3600,
        tokenExpiresIn: TimeInterval = 7200,
        age: TimeInterval = 0
    ) -> UsageOutcome {
        .samples(
            session: UsageSample(percent: session, resetsAt: now.addingTimeInterval(resetsIn)),
            week: UsageSample(percent: week, resetsAt: now.addingTimeInterval(resetsIn * 10)),
            asOf: now.addingTimeInterval(-age),
            tokenExpiresAt: now.addingTimeInterval(tokenExpiresIn)
        )
    }

    @Test("Thresholds are applied to fresh samples")
    func appliesThresholds() {
        let s = store()
        s.apply(samples(session: 76, week: 20))
        s.revalidate(now: now)
        #expect(s.session.state == .warning)
        #expect(s.week.state == .nominal)
    }

    @Test("Changing thresholds re-renders without a new sample")
    func thresholdChangeRerenders() {
        let s = store()
        s.apply(samples(session: 76))
        s.revalidate(now: now)
        #expect(s.session.state == .warning)

        s.thresholds = Thresholds(warning: 80, critical: 95)
        s.revalidate(now: now)
        #expect(s.session.state == .nominal)
    }

    @Test("An aged sample becomes unknown")
    func agedSample() {
        let s = store(staleAfter: 300)
        s.apply(samples(session: 10, age: 0))
        s.revalidate(now: now.addingTimeInterval(301))
        #expect(s.session.state == .unknown)
        #expect(s.session.detail == "no recent reading")
    }

    @Test("A passed window reset clears only that window")
    func passedWindowReset() {
        let s = store()
        s.apply(.samples(
            session: UsageSample(percent: 10, resetsAt: now.addingTimeInterval(60)),
            week: UsageSample(percent: 20, resetsAt: now.addingTimeInterval(86_400)),
            asOf: now,
            tokenExpiresAt: now.addingTimeInterval(7200)
        ))
        s.revalidate(now: now.addingTimeInterval(61))
        #expect(s.session.state == .unknown)
        #expect(s.week.state == .nominal)
    }

    @Test("An expired token clears both usage readings")
    func expiredToken() {
        let s = store()
        s.apply(samples(session: 10, week: 20, tokenExpiresIn: 60))
        s.revalidate(now: now.addingTimeInterval(61))
        #expect(s.session.state == .unknown)
        #expect(s.week.state == .unknown)
    }

    @Test("Every failure either retains the sample or clears it, by case", arguments: [
        (UsageFailure.offline, true),
        (UsageFailure.rateLimited(retryAfter: nil), true),
        (UsageFailure.credentialsNotFound, false),
        (UsageFailure.keychainDenied, false),
        (UsageFailure.keychainUnavailable, false),
        (UsageFailure.credentialsUnreadable, false),
        (UsageFailure.tokenExpired, false),
        (UsageFailure.authorizationRejected, false),
        (UsageFailure.accessRefused, false),
        (UsageFailure.unexpectedResponse, false),
    ])
    func failureRetainsOrClears(failure: UsageFailure, retains: Bool) {
        let s = store()
        s.apply(samples(session: 95))
        s.revalidate(now: now)
        #expect(s.session.state == .critical)

        s.apply(UsageOutcome.failure(failure))
        s.revalidate(now: now)

        if retains {
            // The value stands, annotated with why it may be ageing.
            #expect(s.session.state == .critical)
            #expect(s.session.detail == "95%")
            #expect(s.session.note == failure.menuText)
        } else {
            #expect(s.session.state == .unknown)
            #expect(s.session.detail == failure.menuText)
            #expect(s.session.note == nil)
        }
    }

    @Test("A failure never itself chooses warning or critical")
    func failureNeverChoosesState() {
        let s = store()

        // A retained failure yields the sample's own state, unaltered by
        // the failure - not .warning or .critical as a consequence of
        // .offline itself.
        s.apply(samples(session: 10))
        s.revalidate(now: now)
        #expect(s.session.state == .nominal)
        s.apply(UsageOutcome.failure(.offline))
        s.revalidate(now: now)
        #expect(s.session.state == .nominal)

        // A cleared failure yields .unknown regardless of how high the
        // prior sample was.
        s.apply(samples(session: 95))
        s.revalidate(now: now)
        #expect(s.session.state == .critical)
        s.apply(UsageOutcome.failure(.keychainDenied))
        s.revalidate(now: now)
        #expect(s.session.state == .unknown)
    }

    @Test("Platform failures retain or clear the same way as usage failures")
    func platformFailureRetainsOrClears() {
        let s = store()
        s.apply(StatusOutcome.sample(
            StatusSample(state: .warning, description: "Elevated error rates"),
            asOf: now
        ))
        s.revalidate(now: now)
        #expect(s.platform.state == .warning)

        s.apply(StatusOutcome.failure(.offline))
        s.revalidate(now: now)
        #expect(s.platform.state == .warning)
        #expect(s.platform.note == StatusFailure.offline.menuText)

        s.apply(StatusOutcome.failure(.unexpectedResponse))
        s.revalidate(now: now)
        #expect(s.platform.state == .unknown)
        #expect(s.platform.detail == StatusFailure.unexpectedResponse.menuText)
    }

    @Test("Only credential failures stop polling")
    func stopsPolling() {
        let s = store()
        s.apply(UsageOutcome.failure(.offline))
        #expect(s.usagePollingStopped == false)

        s.apply(UsageOutcome.failure(.keychainDenied))
        #expect(s.usagePollingStopped == true)
    }

    @Test("Retry clears the stopped flag")
    func retryResumes() {
        let s = store()
        s.apply(UsageOutcome.failure(.credentialsNotFound))
        #expect(s.usagePollingStopped == true)
        s.retryUsage()
        #expect(s.usagePollingStopped == false)
    }

    @Test("Platform status maps through")
    func platformStatus() {
        let s = store()
        s.apply(StatusOutcome.sample(
            StatusSample(state: .nominal, description: "All Systems Operational"),
            asOf: now
        ))
        s.revalidate(now: now)
        #expect(s.platform.state == .nominal)
        #expect(s.platform.detail == "All Systems Operational")
    }

    @Test("Waking clears everything")
    func wakeClears() {
        let s = store()
        s.apply(samples(session: 95))
        s.apply(StatusOutcome.sample(
            StatusSample(state: .nominal, description: "All Systems Operational"),
            asOf: now
        ))
        s.revalidate(now: now)
        #expect(s.session.state == .critical)

        s.clearOnWake(now: now)
        #expect(s.session.state == .unknown)
        #expect(s.week.state == .unknown)
        #expect(s.platform.state == .unknown)

        // The sample is gone, not merely hidden: revalidating cannot
        // resurrect it.
        s.revalidate(now: now)
        #expect(s.session.state == .unknown)
    }

    @Test("The three states are reported in display order")
    func statesInDisplayOrder() {
        let s = store()
        s.apply(.samples(
            session: UsageSample(percent: 95, resetsAt: now.addingTimeInterval(3600)),
            week: UsageSample(percent: 10, resetsAt: now.addingTimeInterval(86_400)),
            asOf: now,
            tokenExpiresAt: now.addingTimeInterval(7200)
        ))
        s.apply(StatusOutcome.sample(
            StatusSample(state: .warning, description: "Elevated error rates"),
            asOf: now
        ))
        s.revalidate(now: now)

        // Three DISTINGUISHABLE states, so a transposition fails rather
        // than coincidentally matching: session critical (95%), week
        // nominal (10%), platform warning.
        #expect(s.states == [.critical, .nominal, .warning])
    }
}
