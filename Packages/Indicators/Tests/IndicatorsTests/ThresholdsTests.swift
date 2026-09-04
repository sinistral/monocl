import Testing

@testable import Indicators

@Suite("Threshold evaluation")
struct ThresholdsTests {
    private let t = Thresholds.default

    @Test("Defaults are 75 and 90")
    func defaults() {
        #expect(t.warning == 75)
        #expect(t.critical == 90)
    }

    @Test(
        "Boundaries are inclusive",
        arguments: [
            (0.0, IndicatorState.nominal),
            (74.9, IndicatorState.nominal),
            (75.0, IndicatorState.warning),
            (75.1, IndicatorState.warning),
            (89.9, IndicatorState.warning),
            (90.0, IndicatorState.critical),
            (90.1, IndicatorState.critical),
            (100.0, IndicatorState.critical),
            (120.0, IndicatorState.critical),
        ])
    func boundaries(percent: Double, expected: IndicatorState) {
        #expect(t.state(forPercent: percent) == expected)
    }

    @Test("Custom thresholds are honored")
    func custom() {
        let strict = Thresholds(warning: 50, critical: 60)
        #expect(strict.state(forPercent: 49.9) == .nominal)
        #expect(strict.state(forPercent: 50.0) == .warning)
        #expect(strict.state(forPercent: 60.0) == .critical)
    }
}
