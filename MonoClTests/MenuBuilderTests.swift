// MonoClTests/MenuBuilderTests.swift
import AppKit
import ClaudeUsage
import Engine
import Indicators
import Testing
@testable import MonoCl

@MainActor
@Suite("Menu builder")
struct MenuBuilderTests {
    private let actions = MenuBuilder.Actions(
        refresh: #selector(NSApplication.terminate(_:)),
        retry: #selector(NSApplication.terminate(_:)),
        openSettings: #selector(NSApplication.terminate(_:)),
        quit: #selector(NSApplication.terminate(_:))
    )

    private func titles(_ store: IndicatorStore, refreshPending: PendingRefresh? = nil) -> [String] {
        items(store, refreshPending: refreshPending).map(\.title)
    }

    private func items(_ store: IndicatorStore, refreshPending: PendingRefresh? = nil) -> [NSMenuItem] {
        MenuBuilder.menu(
            store: store,
            target: NSApp,
            actions: actions,
            refreshPending: refreshPending
        ).items
    }

    @Test("A pending refresh replaces the Refresh now command with a disabled progress row")
    func pendingRefreshRow() {
        let store = IndicatorStore()

        let idle = titles(store)
        #expect(idle.contains("Refresh now"))
        #expect(idle.contains("Refreshing…") == false)

        let pending = items(store, refreshPending: .refreshing)
        #expect(pending.map(\.title).contains("Refreshing…"))
        #expect(pending.map(\.title).contains("Refresh now") == false)

        let row = pending.first { $0.title == "Refreshing…" }
        #expect(row?.action == nil)
    }

    @Test("The row shows the rate limit for as long as it lasts, whether or not anyone asked to refresh")
    func rowFollowsTheRateLimitNotTheRequest() {
        // The endpoint's limit outlives any one request, so the row must
        // not depend on somebody having clicked.
        #expect(
            PendingRefresh.forMenu(rateLimited: true, refreshesOutstanding: [false, false])
                == .rateLimited
        )
        #expect(
            PendingRefresh.forMenu(rateLimited: true, refreshesOutstanding: [true, false])
                == .rateLimited
        )
    }

    @Test("Any outstanding refresh takes the command away; none leaves it")
    func rowFollowsAnyOutstandingRefresh() {
        #expect(
            PendingRefresh.forMenu(rateLimited: false, refreshesOutstanding: [false, true])
                == .refreshing
        )
        #expect(
            PendingRefresh.forMenu(rateLimited: false, refreshesOutstanding: [false, false])
                == nil
        )
    }

    @Test("A refresh held by the rate limit says so, rather than claiming to be fetching")
    func rateLimitedRow() {
        let store = IndicatorStore()
        let t = titles(store, refreshPending: .rateLimited)
        #expect(t.contains("Waiting out the rate limit"))
        #expect(t.contains("Refreshing…") == false)
        #expect(t.contains("Refresh now") == false)
    }

    @Test("The standard items are present")
    func standardItems() {
        let store = IndicatorStore()
        let t = titles(store)
        #expect(t.contains("Refresh now"))
        #expect(t.contains("Settings…"))
        #expect(t.contains("Quit MonoCl"))
    }

    @Test("Retry appears only when polling has stopped")
    func retryVisibility() {
        let store = IndicatorStore()
        #expect(titles(store).contains("Retry") == false)

        store.apply(UsageOutcome.failure(.keychainDenied))
        #expect(titles(store).contains("Retry") == true)

        store.retryUsage()
        #expect(titles(store).contains("Retry") == false)
    }

    @Test("Each indicator gets a labelled row")
    func indicatorRows() {
        let store = IndicatorStore()
        store.revalidate(now: .now)
        let t = titles(store)
        #expect(t.contains { $0.hasPrefix("Session:") })
        #expect(t.contains { $0.hasPrefix("Week:") })
        #expect(t.contains { $0.hasPrefix("Platform:") })
    }

    @Test("A retained reading's row carries its note")
    func retainedRowCarriesNote() {
        let store = IndicatorStore()
        store.apply(.samples(
            session: UsageSample(percent: 95, resetsAt: Date().addingTimeInterval(3600)),
            week: nil,
            asOf: .now,
            tokenExpiresAt: Date().addingTimeInterval(7200)
        ))
        store.revalidate(now: .now)
        store.apply(UsageOutcome.failure(.offline))
        store.revalidate(now: .now)
        #expect(titles(store).contains("Session: 95% · Offline"))
    }
}
