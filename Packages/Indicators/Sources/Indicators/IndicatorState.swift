/// What one light is currently saying.
///
/// `unknown` is a first-class outcome, not an error state: it is what
/// MonoCl shows whenever it cannot vouch for a value, which is
/// preferable to a stale number the reader would believe.
public enum IndicatorState: String, Sendable, Equatable, CaseIterable {
    case unknown
    case nominal
    case warning
    case critical

    /// Whether this state represents a breached threshold, as opposed to
    /// a quiet or absent reading.
    public var isBreach: Bool {
        self == .warning || self == .critical
    }
}
