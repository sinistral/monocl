import Foundation
import Indicators
import Observation

/// User settings, backed by `UserDefaults`.
///
/// Settings are the only thing MonoCl persists.  Readings are not: a
/// reading restored from a previous launch describes an unknown moment,
/// and would be believed.
@Observable
final class Preferences {
    private enum Key {
        static let warning = "warningThreshold"
        static let critical = "criticalThreshold"
        static let refreshInterval = "refreshInterval"
        static let staleAfter = "staleAfter"
    }

    static let minimumRefreshInterval: TimeInterval = 15

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.warning: 75.0,
            Key.critical: 90.0,
            Key.refreshInterval: 60.0,
            Key.staleAfter: 300.0,
        ])
    }

    var warningThreshold: Double {
        get { defaults.double(forKey: Key.warning) }
        set { defaults.set(newValue, forKey: Key.warning) }
    }

    /// The invariant "critical is never below warning" is enforced HERE,
    /// on read, and not in `warningThreshold`'s setter.  No caller can
    /// observe an unclamped pair, so the guarantee holds for everyone.
    ///
    /// Clamping on read rather than on write also preserves the user's
    /// choice instead of overwriting it: raising the warning threshold
    /// past the critical one MASKS the stored critical value, and
    /// lowering the warning threshold again brings it back.  Pushing the
    /// stored value up on write would destroy it silently.
    var criticalThreshold: Double {
        get { max(defaults.double(forKey: Key.critical), defaults.double(forKey: Key.warning)) }
        set { defaults.set(max(newValue, warningThreshold), forKey: Key.critical) }
    }

    var refreshInterval: TimeInterval {
        get { max(defaults.double(forKey: Key.refreshInterval), Self.minimumRefreshInterval) }
        set { defaults.set(max(newValue, Self.minimumRefreshInterval), forKey: Key.refreshInterval) }
    }

    var staleAfter: TimeInterval {
        get { defaults.double(forKey: Key.staleAfter) }
        set { defaults.set(newValue, forKey: Key.staleAfter) }
    }

    var thresholds: Thresholds {
        Thresholds(warning: warningThreshold, critical: criticalThreshold)
    }
}
