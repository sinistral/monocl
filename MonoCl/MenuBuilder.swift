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

        // Only the platform row leads anywhere.  Session and Week report
        // a number MonoCl already shows in full, so an enabled row would
        // promise detail that does not exist; the platform summary is one
        // line standing in for an incident page, and that page is where a
        // reader who wants more has to go.
        for (label, reading, action) in [
            ("Session", store.session, nil),
            ("Week", store.week, nil),
            ("Platform", store.platform, actions.openStatusPage),
        ] {
            var detail = reading.state == .unknown ? "— \(reading.detail)" : reading.detail
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
}
