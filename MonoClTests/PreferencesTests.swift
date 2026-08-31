import Foundation
import Indicators
import Testing
@testable import MonoCl

@Suite("Preferences")
final class PreferencesTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "net.sinistral.monocl.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Defaults match the spec")
    func defaultValues() {
        let p = Preferences(defaults: defaults)
        #expect(p.warningThreshold == 75)
        #expect(p.criticalThreshold == 90)
        #expect(p.refreshInterval == 300)
        #expect(p.staleAfter == 900)
    }

    @Test("Values round-trip")
    func roundTrip() {
        let p = Preferences(defaults: defaults)
        p.warningThreshold = 60
        p.refreshInterval = 120

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.warningThreshold == 60)
        #expect(reloaded.refreshInterval == 120)
    }

    @Test("Critical is never below warning")
    func criticalClamped() {
        let p = Preferences(defaults: defaults)
        p.warningThreshold = 80
        p.criticalThreshold = 70
        #expect(p.criticalThreshold == 80)
    }

    @Test("Raising warning masks the critical value rather than destroying it")
    func criticalIsMaskedNotDestroyed() {
        let p = Preferences(defaults: defaults)
        p.criticalThreshold = 90
        p.warningThreshold = 95
        // Masked upward: the invariant holds on read.
        #expect(p.criticalThreshold == 95)

        p.warningThreshold = 50
        // The user's original choice reappears, which is the point of
        // clamping on read instead of overwriting on write.
        #expect(p.criticalThreshold == 90)
    }

    @Test("The refresh interval has a floor")
    func intervalFloor() {
        let p = Preferences(defaults: defaults)
        p.refreshInterval = 1
        #expect(p.refreshInterval == 60)
    }

    @Test("The stale budget is never shorter than two poll intervals")
    func staleBudgetSpansTwoPolls() {
        let p = Preferences(defaults: defaults)
        p.refreshInterval = 300
        p.staleAfter = 60
        #expect(p.staleAfter == 600)
    }

    @Test("Shortening the interval unmasks the stale budget the user chose")
    func staleBudgetIsMaskedNotDestroyed() {
        let p = Preferences(defaults: defaults)
        p.refreshInterval = 300
        p.staleAfter = 120
        #expect(p.staleAfter == 600)

        p.refreshInterval = 60
        #expect(p.staleAfter == 120)
    }

    @Test("Thresholds are exposed as an Indicators value")
    func thresholdsValue() {
        let p = Preferences(defaults: defaults)
        p.warningThreshold = 50
        p.criticalThreshold = 65
        #expect(p.thresholds == Thresholds(warning: 50, critical: 65))
    }
}
