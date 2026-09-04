// MonoCl/RelativeTime.swift
import Foundation

/// Renders how far off an instant is, in words.
///
/// Hand-rolled rather than delegated to `RelativeDateTimeFormatter`,
/// which rounds to the nearest unit: it calls 36 hours "in 2 days",
/// overstating how long the reader has before a window resets.  This
/// truncates to the largest unit the interval wholly fills, so the
/// number never promises time that is not there.
enum RelativeTime {
    private static let unit: [(seconds: TimeInterval, singular: String, plural: String)] = [
        (86_400, "day", "days"),
        (3600, "hour", "hours"),
        (60, "minute", "minutes"),
    ]

    /// Days are the largest unit offered.  The widest window MonoCl
    /// reports is seven days, and "7 days" states that more plainly
    /// than "1 week".
    static func describe(_ date: Date, from now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        for (seconds, singular, plural) in unit where interval >= seconds {
            let count = Int(interval / seconds)
            return "\(count) \(count == 1 ? singular : plural)"
        }
        // Also the resting place for an instant already past.  A
        // reading whose window has reset is untrusted and never
        // rendered, so no caller can reach this with a negative
        // interval and be misled by it.
        return "under a minute"
    }
}
