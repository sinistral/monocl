import Foundation
import Indicators

/// Everything the engine needs from the user's preferences, as one
/// value.
///
/// One value rather than three closures: thresholds, cadence and the
/// staleness budget are read together on every revalidation, and a
/// single read cannot observe a half-applied pair.
public struct EngineSettings: Equatable, Sendable {
    /// The shortest cadence the user may choose, and the floor
    /// `Refresher` applies to every request it makes.  Chosen for the
    /// endpoint's sake rather than the display's: the windows being
    /// reported span five hours and seven days, so a minute is already
    /// finer resolution than the data has.
    public static let minimumRefreshInterval: TimeInterval = 60

    public let thresholds: Thresholds
    public let refreshInterval: TimeInterval
    public let staleAfter: TimeInterval

    public init(thresholds: Thresholds, refreshInterval: TimeInterval, staleAfter: TimeInterval) {
        self.thresholds = thresholds
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter
    }
}
