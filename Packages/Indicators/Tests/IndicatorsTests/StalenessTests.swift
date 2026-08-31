// Packages/Indicators/Tests/IndicatorsTests/StalenessTests.swift
import Foundation
import Testing
@testable import Indicators

@Suite("Staleness rule")
struct StalenessTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let staleAfter: TimeInterval = 300

    private func inputs(
        age: TimeInterval = 10,
        tokenExpiresAt: Date? = nil,
        windowResetsAt: Date? = nil
    ) -> TrustInputs {
        TrustInputs(
            asOf: now.addingTimeInterval(-age),
            now: now,
            staleAfter: staleAfter,
            tokenExpiresAt: tokenExpiresAt,
            windowResetsAt: windowResetsAt
        )
    }

    @Test("Fresh sample with no token or window is trusted")
    func freshNoConditions() {
        #expect(isTrusted(inputs()) == true)
    }

    @Test("Fresh sample with live token and future reset is trusted")
    func freshAllConditions() {
        #expect(isTrusted(inputs(
            tokenExpiresAt: now.addingTimeInterval(3600),
            windowResetsAt: now.addingTimeInterval(1800)
        )) == true)
    }

    @Test("Age alone can untrust")
    func tooOld() {
        #expect(isTrusted(inputs(age: 301)) == false)
    }

    @Test("Age exactly at the budget is untrusted")
    func exactlyAtBudget() {
        #expect(isTrusted(inputs(age: 300)) == false)
    }

    @Test("Expired token alone can untrust")
    func expiredToken() {
        #expect(isTrusted(inputs(tokenExpiresAt: now.addingTimeInterval(-1))) == false)
    }

    @Test("Passed window reset alone can untrust")
    func passedWindow() {
        #expect(isTrusted(inputs(windowResetsAt: now.addingTimeInterval(-1))) == false)
    }
}
