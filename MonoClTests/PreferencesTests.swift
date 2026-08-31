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
        #expect(p.refreshInterval == 60)
        #expect(p.staleAfter == 300)
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

    @Test("The refresh interval has a floor")
    func intervalFloor() {
        let p = Preferences(defaults: defaults)
        p.refreshInterval = 1
        #expect(p.refreshInterval == 15)
    }

    @Test("Thresholds are exposed as an Indicators value")
    func thresholdsValue() {
        let p = Preferences(defaults: defaults)
        p.warningThreshold = 50
        p.criticalThreshold = 65
        #expect(p.thresholds == Thresholds(warning: 50, critical: 65))
    }
}
