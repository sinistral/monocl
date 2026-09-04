// MonoCl/MenuBuilder.swift
import AppKit
import Engine
import Foundation
import Indicators

@MainActor
enum MenuBuilder {
    /// Selectors are supplied by the delegate that owns the menu.
    struct Actions {
        let refresh: Selector
        let retry: Selector
        let openSettings: Selector
        let openStatusPage: Selector
        let quit: Selector
    }

    static func menu(
        store: IndicatorStore,
        target: AnyObject,
        actions: Actions,
        refreshPending: PendingRefresh?,
        timeZone: TimeZone = .current,
        now: Date = .now
    ) -> NSMenu {
        let menu = NSMenu()
        populate(
            menu,
            store: store,
            target: target,
            actions: actions,
            refreshPending: refreshPending,
            timeZone: timeZone,
            now: now
        )
        return menu
    }

    /// Rebuilds `menu`'s items in place.  Used to refresh an already
    /// on-screen menu from `NSMenuDelegate.menuNeedsUpdate(_:)`, where
    /// reassigning `statusItem.menu` to a new instance mid-tracking is
    /// not safe.
    static func populate(
        _ menu: NSMenu,
        store: IndicatorStore,
        target: AnyObject,
        actions: Actions,
        refreshPending: PendingRefresh?,
        timeZone: TimeZone = .current,
        now: Date = .now
    ) {
        menu.removeAllItems()

        // Only the platform row leads anywhere.  Session and Week report
        // a number MonoCl already shows in full, so an enabled row would
        // promise detail that does not exist; the platform summary is one
        // line standing in for an incident page, and that page is where a
        // reader who wants more has to go.
        //
        // Named and typed rather than left to inference: two of the four
        // columns are nil in some rows, which a bare literal cannot type.
        let rows: [(label: String, reading: Reading, resetsAt: Date?, action: Selector?)] = [
            ("Session", store.session, store.sessionResetsAt, nil),
            ("Week", store.week, store.weekResetsAt, nil),
            ("Platform", store.platform, nil, actions.openStatusPage),
        ]
        for (label, reading, resetsAt, action) in rows {
            var detail = reading.state == .unknown ? "— \(reading.detail)" : reading.detail
            // A reading MonoCl cannot vouch for says nothing about when
            // its window turns over: the sample the reset came from is
            // the one being disbelieved.
            if reading.state != .unknown, let resetsAt {
                detail += ", resets \(resetPhrase(resetsAt, timeZone: timeZone, now: now))"
            }
            if let note = reading.note {
                detail += " · \(note)"
            }
            let item = NSMenuItem(title: "\(label): \(detail)", action: action, keyEquivalent: "")
            // An item with an action is enabled by AppKit; one without
            // has to say so, or it draws as though it were live.
            if action == nil {
                item.isEnabled = false
            } else {
                item.target = target
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if store.usagePollingStopped {
            menu.addItem(withTitle: "Retry", action: actions.retry, keyEquivalent: "")
                .target = target
        }

        if let refreshPending {
            let title = switch refreshPending {
            case .refreshing: "Refreshing…"
            case .rateLimited: "Waiting out the rate limit"
            }
            // No action, so AppKit disables it: the refresh is already
            // scheduled and asking again cannot bring it forward.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            menu.addItem(withTitle: "Refresh now", action: actions.refresh, keyEquivalent: "r")
                .target = target
        }
        menu.addItem(withTitle: "Settings…", action: actions.openSettings, keyEquivalent: ",")
            .target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MonoCl", action: actions.quit, keyEquivalent: "q")
            .target = target
    }

    /// The menu has room the tooltip does not, so it gives the reset
    /// both ways: the clock time to plan around, and the interval that
    /// answers "how long have I got" without arithmetic.
    private static func resetPhrase(_ date: Date, timeZone: TimeZone, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        // Every other word in this menu is hard-coded English, so a
        // weekday translated by the user's locale would read as the odd
        // one out; en_US_POSIX also makes the fixed pattern literal
        // rather than subject to the locale's own clock conventions.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Within the next 12 hours a bare time is unambiguous; beyond
        // that the weekday is needed for the weekly window to make sense.
        let near = date.timeIntervalSince(now) < 12 * 3600
        formatter.dateFormat = near ? "HH:mm" : "EEEE' at 'HH:mm"
        let when = formatter.string(from: date)
        // The countdown is counted through the same zone the weekday was
        // named in.  Leaving it to the current calendar lets one half of
        // this sentence disagree with the other whenever the two differ.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let remaining = RelativeTime.describe(date, from: now, calendar: calendar)
        return "\(near ? "at " : "on ")\(when) (in \(remaining))"
    }
}
