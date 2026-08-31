import Foundation

/// A resolved value for one indicator, ready for display.
public struct Reading: Sendable, Equatable {
    public let state: IndicatorState
    public let detail: String
    /// Why this value may be ageing.  Nil normally.
    public let note: String?
    public let asOf: Date

    public init(state: IndicatorState, detail: String, note: String? = nil, asOf: Date) {
        self.state = state
        self.detail = detail
        self.note = note
        self.asOf = asOf
    }

    /// A reading MonoCl cannot vouch for.
    public static func unknown(detail: String, asOf: Date) -> Reading {
        Reading(state: .unknown, detail: detail, note: nil, asOf: asOf)
    }
}
