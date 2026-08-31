// MonoCl/MenuBuilder.swift
import AppKit
import Foundation
import Indicators

/// What the menu says in place of its refresh command.  One value
/// rather than a flag plus a reason: the menu has one row to fill, and
/// a pair of booleans admits a state where it is both.
enum PendingRefresh {
    /// A requested refresh has yet to land — waiting out the minimum
    /// spacing, or in flight.
    case refreshing
    /// Waiting out a `Retry-After` the endpoint supplied.  Distinguished
    /// because it can last an hour, and an hour of "Refreshing…" is a
    /// claim the app cannot support.
    case rateLimited
}

extension PendingRefresh {
    /// Derived from the rate limit FIRST, because that limit outlives
    /// any one request: the endpoint's `Retry-After` can run for an
    /// hour, and for that hour no refresh of usage can succeed whether
    /// or not anyone has clicked.  Keying the row on an outstanding
    /// request instead would leave a live command through most of the
    /// window, offering an action that cannot move the rows above it.
    static func forMenu(
        rateLimited: Bool,
        refreshesOutstanding: [Bool]
    ) -> PendingRefresh? {
        if rateLimited { return .rateLimited }
        return refreshesOutstanding.contains(true) ? .refreshing : nil
    }
}


@MainActor
enum MenuBuilder {
    /// Selectors are supplied by the delegate that owns the menu.
    struct Actions {
        let refresh: Selector
        let retry: Selector
        let openSettings: Selector
        let quit: Selector
    }

    static func menu(
        store: IndicatorStore,
        target: AnyObject,
        actions: Actions,
        refreshPending: PendingRefresh?
    ) -> NSMenu {
        let menu = NSMenu()
        populate(
            menu,
            store: store,
            target: target,
            actions: actions,
            refreshPending: refreshPending
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
        refreshPending: PendingRefresh?
    ) {
        menu.removeAllItems()

        for (label, reading) in [
            ("Session", store.session),
            ("Week", store.week),
            ("Platform", store.platform),
        ] {
            var detail = reading.state == .unknown ? "— \(reading.detail)" : reading.detail
            if let note = reading.note {
                detail += " · \(note)"
            }
            let item = NSMenuItem(title: "\(label): \(detail)", action: nil, keyEquivalent: "")
            item.isEnabled = false
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
}
