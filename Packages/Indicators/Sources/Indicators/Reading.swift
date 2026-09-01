import Foundation

/// A resolved value for one indicator, ready for display.
public struct Reading: Sendable, Equatable {
    public let state: IndicatorState
    public let detail: String
    /// Why this value may be ageing.  Nil normally.
    public let note: String?
    /// The utilisation this reading reports, 0...100, or nil where
    /// there is no number: the platform light, which has none, and any
    /// reading MonoCl cannot vouch for.  The renderer needs a
    /// magnitude; every text path uses `detail` instead.
    public let percent: Double?
    public let asOf: Date

    public init(
        state: IndicatorState,
        detail: String,
        note: String? = nil,
        percent: Double? = nil,
        asOf: Date
    ) {
        self.state = state
        self.detail = detail
        self.note = note
        self.percent = percent
        self.asOf = asOf
    }

    /// A reading MonoCl cannot vouch for.
    public static func unknown(detail: String, asOf: Date) -> Reading {
        Reading(state: .unknown, detail: detail, note: nil, percent: nil, asOf: asOf)
    }
}
