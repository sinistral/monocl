// MonoCl/MenuBuilder.swift
import AppKit
import Indicators

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
        actions: Actions
    ) -> NSMenu {
        let menu = NSMenu()

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

        menu.addItem(withTitle: "Refresh now", action: actions.refresh, keyEquivalent: "r")
            .target = target
        menu.addItem(withTitle: "Settings…", action: actions.openSettings, keyEquivalent: ",")
            .target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MonoCl", action: actions.quit, keyEquivalent: "q")
            .target = target

        return menu
    }
}
