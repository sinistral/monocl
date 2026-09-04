// MonoCl/TooltipComposer.swift
import Foundation
import Indicators

/// Builds the multi-line hover text.
///
/// A status item's tooltip accepts newlines, which is why one item can
/// report all three indicators on hover — the reason the design uses a
/// single item rather than three.
///
/// Resets are given only as time remaining.  A tooltip is read at a
/// glance and is the narrower of the two surfaces, and "how long have I
/// got" is the question a glance is asking; the menu, which is opened
/// deliberately, carries the clock time as well.
///
/// Labels are punctuated rather than padded into columns.  Padding with
/// spaces only lines up in a monospaced font, and a tooltip is drawn in
/// a proportional one — so the columns drifted apart exactly when the
/// values differed in width, which is whenever there was anything to
/// compare.  A colon aligns nothing and pretends to align nothing, and
/// it gives the platform row the separator a reset time was otherwise
/// supplying to the other two.
enum TooltipComposer {
    static func tooltip(
        session: Reading,
        week: Reading,
        platform: Reading,
        sessionResetsAt: Date?,
        weekResetsAt: Date?,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        // Counted through the same zone the menu names its weekday in,
        // so the two surfaces cannot report different day counts for one
        // reset.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return [
            line(
                label: "Session", reading: session, resetsAt: sessionResetsAt, now: now,
                calendar: calendar),
            line(
                label: "Week", reading: week, resetsAt: weekResetsAt, now: now, calendar: calendar),
            line(label: "Platform", reading: platform, resetsAt: nil, now: now, calendar: calendar),
        ].joined(separator: "\n")
    }

    private static func line(
        label: String,
        reading: Reading,
        resetsAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard reading.state != .unknown else {
            return "\(label): — \(reading.detail)"
        }
        var text = "\(label): \(reading.detail)"
        if let resetsAt {
            text += ", resets in \(RelativeTime.describe(resetsAt, from: now, calendar: calendar))"
        }
        if let note = reading.note {
            text += " · \(note)"
        }
        return text
    }
}
