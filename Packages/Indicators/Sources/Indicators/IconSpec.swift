/// How one dot should be drawn. Deliberately free of AppKit types so
/// the decision is testable without a screen.
public struct DotSpec: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        case ring(faint: Bool)
        case filled
        /// Filled with a gap at the top, so critical is distinguishable
        /// from warning by shape alone.
        case notched
    }

    public enum Tint: Sendable, Equatable {
        case monochrome
        case dimmed
        case amber
        case red
    }

    public let fill: Fill
    public let tint: Tint

    public init(fill: Fill, tint: Tint) {
        self.fill = fill
        self.tint = tint
    }
}

/// A whole menu bar image: the dots in display order, plus whether the
/// image may be a template.
public struct IconSpec: Sendable, Equatable {
    public let dots: [DotSpec]
    public let isTemplate: Bool

    public init(dots: [DotSpec], isTemplate: Bool) {
        self.dots = dots
        self.isTemplate = isTemplate
    }
}

/// Maps indicator states to a drawable specification.
///
/// A template image is tinted by the system from its alpha channel,
/// which is exactly right for monochrome and dimmed dots and destroys
/// amber and red. So the image stays a template until something
/// actually needs colour — `.unknown` does not, because "dimmed" is
/// alpha, not hue.
public func iconSpec(
    for states: [IndicatorState],
    differentiateWithoutColor: Bool
) -> IconSpec {
    let dots = states.map { state in
        DotSpec(
            fill: fill(for: state, differentiateWithoutColor: differentiateWithoutColor),
            tint: tint(for: state)
        )
    }
    return IconSpec(dots: dots, isTemplate: !states.contains { $0.isBreach })
}

private func fill(
    for state: IndicatorState,
    differentiateWithoutColor: Bool
) -> DotSpec.Fill {
    switch state {
    case .unknown: .ring(faint: true)
    case .nominal: .ring(faint: false)
    case .warning: .filled
    case .critical: differentiateWithoutColor ? .notched : .filled
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
