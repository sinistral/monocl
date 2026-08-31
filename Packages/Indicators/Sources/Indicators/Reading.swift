import Foundation

/// A resolved value for one indicator, ready for display.
public struct Reading: Sendable, Equatable {
    public let state: IndicatorState
    public let detail: String
    public let asOf: Date

    public init(state: IndicatorState, detail: String, asOf: Date) {
        self.state = state
        self.detail = detail
        self.asOf = asOf
    }

    /// A reading MonoCl cannot vouch for.
    public static func unknown(detail: String, asOf: Date) -> Reading {
        Reading(state: .unknown, detail: detail, asOf: asOf)
    }
}
