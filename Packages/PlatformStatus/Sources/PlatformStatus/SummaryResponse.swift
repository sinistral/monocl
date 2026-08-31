import Foundation
import Indicators

/// The subset of Statuspage's `summary.json` MonoCl reads.
public struct SummaryResponse: Sendable, Equatable, Decodable {
    public struct Status: Sendable, Equatable, Decodable {
        public let indicator: String
        public let description: String
    }

    public let status: Status

    /// Statuspage's documented indicator values are `none`, `minor`,
    /// `major` and `critical`.  Anything else is treated as unknown
    /// rather than guessed at: inventing a severity for a value Anthropic
    /// has newly introduced would be worse than admitting ignorance.
    public var indicatorState: IndicatorState {
        switch status.indicator {
        case "none": .nominal
        case "minor": .warning
        case "major", "critical": .critical
        default: .unknown
        }
    }
}
