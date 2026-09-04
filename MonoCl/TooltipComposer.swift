// MonoCl/TooltipComposer.swift
import Foundation
import Indicators

/// Builds the multi-line hover text.
///
/// `NSStatusItem.button.toolTip` accepts newlines, which is why one
/// status item can report all three indicators on hover — the reason the
/// design uses a single item rather than three.
///
/// Resets are given only as time remaining.  A tooltip is read at a
/// glance and is the narrower of the two surfaces, and "how long have I
/// got" is the question a glance is asking; the menu, which is opened
/// deliberately, carries the clock time as well.
enum TooltipComposer {
    static func tooltip(
        session: Reading,
        week: Reading,
        platform: Reading,
        sessionResetsAt: Date?,
        weekResetsAt: Date?,
        now: Date = .now
    ) -> String {
        [
            line(label: "Session", reading: session, resetsAt: sessionResetsAt, now: now),
            line(label: "Week", reading: week, resetsAt: weekResetsAt, now: now),
            line(label: "Platform", reading: platform, resetsAt: nil, now: now),
        ].joined(separator: "\n")
    }

    private static func line(
        label: String,
        reading: Reading,
        resetsAt: Date?,
        now: Date
    ) -> String {
        let padded = label.padding(toLength: 9, withPad: " ", startingAt: 0)
        guard reading.state != .unknown else {
            return "\(padded)—  \(reading.detail)"
        }
        var text = "\(padded)\(reading.detail)"
        if let resetsAt {
            text += "  ·  resets in \(RelativeTime.describe(resetsAt, from: now))"
        }
        if let note = reading.note {
            text += "  ·  \(note)"
        }
        return text
    }
}
