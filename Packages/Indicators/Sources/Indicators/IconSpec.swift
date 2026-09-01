/// How one dot should be drawn. Deliberately free of AppKit types so
/// the decision is testable without a screen.
public struct DotSpec: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        case ring(faint: Bool)
        case filled
    }

    public enum Tint: Sendable, Equatable {
        case monochrome
        case dimmed
        case amber
        case red
    }

    public let fill: Fill
    public let tint: Tint
    /// Radial slots cut through the dot: none when quiet, one at
    /// warning, two at critical.  The same count the gauges carry, so
    /// a reader learns one rule rather than two.
    public let breachMarks: Int

    public init(fill: Fill, tint: Tint, breachMarks: Int = 0) {
        self.fill = fill
        self.tint = tint
        self.breachMarks = breachMarks
    }
}

/// How one usage gauge should be drawn.
public struct GaugeSpec: Sendable, Equatable {
    /// The fraction of the window consumed, 0...1, or nil where there
    /// is nothing to draw a value from.  Nil is not zero: an unknown
    /// reading is a track with no sweep, which says "no value" rather
    /// than "no usage".
    public let fraction: Double?
    public let tint: DotSpec.Tint
    /// Radial slots cut through the gauge: 0 nominal, 1 warning, 2
    /// critical.
    ///
    /// A count rather than a flag
    /// ---
    ///
    /// Colour alone cannot separate amber from red for a reader with a
    /// colour vision deficiency, and with a continuous sweep the
    /// geometry does not separate them either: the warning and
    /// critical thresholds are 54 degrees of arc apart, which reads as
    /// "fairly full" either way.  Counting to two is categorical where
    /// comparing two arc lengths is not.
    public let breachMarks: Int

    public init(fraction: Double?, tint: DotSpec.Tint, breachMarks: Int) {
        self.fraction = fraction
        self.tint = tint
        self.breachMarks = breachMarks
    }
}

/// A whole menu bar image: the two usage gauges, the platform dot, and
/// whether the image may be a template.
///
/// Named parts rather than a list, because the three are drawn three
/// different ways.  There is then no position to get wrong and no count
/// to enforce elsewhere.
public struct IconSpec: Sendable, Equatable {
    public let session: GaugeSpec
    public let week: GaugeSpec
    public let platform: DotSpec
    public let isTemplate: Bool

    public init(session: GaugeSpec, week: GaugeSpec, platform: DotSpec, isTemplate: Bool) {
        self.session = session
        self.week = week
        self.platform = platform
        self.isTemplate = isTemplate
    }
}

/// Maps readings to a drawable specification.
///
/// A template image is tinted by the system from its alpha channel,
/// which is exactly right for monochrome and dimmed and destroys amber
/// and red. So the image stays a template until something actually
/// needs colour — `.unknown` does not, because "dimmed" is alpha, not
/// hue.
///
/// The breach marks are not conditional on
/// `accessibilityDisplayShouldDifferentiateWithoutColor`.  They are the
/// only thing separating warning from critical by shape, they appear
/// only in a state that is exceptional by construction, and the reader
/// they exist for is the one who has not enabled the setting.
public func iconSpec(session: Reading, week: Reading, platform: Reading) -> IconSpec {
    IconSpec(
        session: gauge(for: session),
        week: gauge(for: week),
        platform: dot(for: platform),
        isTemplate: ![session, week, platform].contains { $0.state.isBreach }
    )
}

private func gauge(for reading: Reading) -> GaugeSpec {
    GaugeSpec(
        fraction: reading.percent.map { min(max($0 / 100, 0), 1) },
        tint: tint(for: reading.state),
        breachMarks: breachMarks(for: reading.state)
    )
}

private func dot(for reading: Reading) -> DotSpec {
    DotSpec(
        fill: reading.state.isBreach ? .filled : .ring(faint: reading.state == .unknown),
        tint: tint(for: reading.state),
        breachMarks: breachMarks(for: reading.state)
    )
}

private func breachMarks(for state: IndicatorState) -> Int {
    switch state {
    case .unknown, .nominal: 0
    case .warning: 1
    case .critical: 2
    }
}

private func tint(for state: IndicatorState) -> DotSpec.Tint {
    switch state {
    case .unknown: .dimmed
    case .nominal: .monochrome
    case .warning: .amber
    case .critical: .red
    }
}
