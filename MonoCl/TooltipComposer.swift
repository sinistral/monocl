// MonoCl/TooltipComposer.swift
import Foundation
import Indicators

/// Builds the multi-line hover text.
///
/// `NSStatusItem.button.toolTip` accepts newlines, which is why one
/// status item can report all three indicators on hover — the reason the
/// design uses a single item rather than three.
enum TooltipComposer {
    static func tooltip(
        session: Reading,
        week: Reading,
        platform: Reading,
        sessionResetsAt: Date?,
        weekResetsAt: Date?,
        timeZone: TimeZone = .current,
        now: Date = .now
    ) -> String {
        [
            line(label: "Session", reading: session, resetsAt: sessionResetsAt, timeZone: timeZone, now: now),
            line(label: "Week", reading: week, resetsAt: weekResetsAt, timeZone: timeZone, now: now),
            line(label: "Platform", reading: platform, resetsAt: nil, timeZone: timeZone, now: now),
        ].joined(separator: "\n")
    }

    private static func line(
        label: String,
        reading: Reading,
        resetsAt: Date?,
        timeZone: TimeZone,
        now: Date
    ) -> String {
        let padded = label.padding(toLength: 9, withPad: " ", startingAt: 0)
        guard reading.state != .unknown else {
            return "\(padded)—  \(reading.detail)"
        }
        var text = "\(padded)\(reading.detail)"
        if let resetsAt {
            text += "  ·  resets \(format(resetsAt, timeZone: timeZone, now: now))"
        }
        if let note = reading.note {
            text += "  ·  \(note)"
        }
        return text
    }

    private static func format(_ date: Date, timeZone: TimeZone, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        // Within the next 12 hours a bare time is unambiguous; beyond
        // that the weekday is needed for the weekly window to make sense.
        formatter.dateFormat = date.timeIntervalSince(now) < 12 * 3600 ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
