/// Percentage thresholds at which a usage indicator changes state.
///
/// Comparisons are inclusive: a percentage equal to `warning` is already
/// a warning.  This matches the user's stated intent (">=75%", ">=90%").
public struct Thresholds: Sendable, Equatable {
    public let warning: Double
    public let critical: Double

    public init(warning: Double, critical: Double) {
        self.warning = warning
        self.critical = critical
    }

    public static let `default` = Thresholds(warning: 75, critical: 90)

    public func state(forPercent percent: Double) -> IndicatorState {
        if percent >= critical { return .critical }
        if percent >= warning { return .warning }
        return .nominal
    }
}
