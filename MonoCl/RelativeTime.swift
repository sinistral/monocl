// MonoCl/RelativeTime.swift
import Foundation

/// Renders how far off an instant is, in words.
///
/// Hand-rolled rather than delegated to `RelativeDateTimeFormatter`,
/// which rounds to the nearest unit: it calls 36 hours "in 2 days",
/// overstating how long the reader has before a window resets.  This
/// truncates to the largest whole unit instead.
///
/// Truncation bounds the overstatement rather than eliminating it.  A
/// calendar day is 23 hours across a spring-forward, so a reset 23 real
/// hours out reads "in 1 day" — an hour more than is there, twice a
/// year.  That is the accepted price of agreeing with the weekday named
/// beside it in the menu; a countdown that contradicts the day it names
/// misleads on every reading, not two a year.
enum RelativeTime {
    /// Counted through a `Calendar` rather than by dividing seconds, so
    /// a day means the day the reader's calendar shows.  Noon Saturday
    /// to noon Monday across a spring-forward is 47 hours, and fixed
    /// arithmetic calls that one day — while the menu beside it names
    /// Monday, leaving one phrase to contradict itself twice a year.
    ///
    /// Days are the largest unit offered.  The widest window MonoCl
    /// reports is seven days, and "7 days" states that more plainly
    /// than "1 week".
    static func describe(_ date: Date, from now: Date, calendar: Calendar = .current) -> String {
        let elapsed = calendar.dateComponents([.day, .hour, .minute], from: now, to: date)
        let units: [(count: Int?, singular: String, plural: String)] = [
            (elapsed.day, "day", "days"),
            (elapsed.hour, "hour", "hours"),
            (elapsed.minute, "minute", "minutes"),
        ]
        for (count, singular, plural) in units where (count ?? 0) > 0 {
            let count = count ?? 0
            return "\(count) \(count == 1 ? singular : plural)"
        }
        // Also the resting place for an instant already past, whose
        // components are negative.  A reading whose window has reset is
        // untrusted and never rendered, so no caller can reach this with
        // a past date and be misled by it.
        return "under a minute"
    }
}
