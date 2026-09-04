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
        openStatusPage: #selector(NSApplication.hide(_:)),
        quit: #selector(NSApplication.terminate(_:))
    )

    /// 2026-08-31 12:00:00 UTC, a Monday, so the weekday-bearing rows
    /// below read as Monday plus the offset under test.
    private let now = Date(timeIntervalSince1970: 1_788_177_600)

    private let utc = TimeZone(identifier: "UTC")!

    private func titles(_ store: IndicatorStore, refreshPending: PendingRefresh? = nil) -> [String] {
        items(store, refreshPending: refreshPending).map(\.title)
    }

    private func items(_ store: IndicatorStore, refreshPending: PendingRefresh? = nil) -> [NSMenuItem] {
        MenuBuilder.menu(
            store: store,
            target: NSApp,
            actions: actions,
            refreshPending: refreshPending,
            timeZone: utc,
            now: now
        ).items
    }

    /// A store holding usage samples MonoCl can vouch for at `now`.
    private func store(
        sessionPercent: Double,
        sessionResetsIn: TimeInterval,
        weekPercent: Double? = nil,
        weekResetsIn: TimeInterval = 0
    ) -> IndicatorStore {
        let store = IndicatorStore()
        store.apply(.samples(
            session: UsageSample(percent: sessionPercent, resetsAt: now.addingTimeInterval(sessionResetsIn)),
            week: weekPercent.map { UsageSample(percent: $0, resetsAt: now.addingTimeInterval(weekResetsIn)) },
            asOf: now,
            tokenExpiresAt: now.addingTimeInterval(7200)
        ))
        store.revalidate(now: now)
        return store
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

    @Test("A retained reading's note follows its reset time")
    func retainedRowCarriesNote() {
        let store = store(sessionPercent: 95, sessionResetsIn: 3600)
        store.apply(UsageOutcome.failure(.offline))
        store.revalidate(now: now)
        #expect(titles(store).contains("Session: 95%, resets at 13:00 (in 1 hour) · Offline"))
    }

    @Test("A usage row states the reset both as a clock time and as time remaining")
    func rowStatesResetBothWays() {
        // Within half a day the bare time is unambiguous, so no weekday
        // is spent on it.
        let store = store(sessionPercent: 25, sessionResetsIn: 2 * 3600)
        #expect(titles(store).contains("Session: 25%, resets at 14:00 (in 2 hours)"))
    }

    @Test("A reset beyond 12 hours names its weekday")
    func distantResetNamesItsWeekday() {
        // Past half a day a bare time no longer says which day it falls
        // on, which is precisely the question a weekly window raises.
        let store = store(sessionPercent: 25, sessionResetsIn: 3600, weekPercent: 20, weekResetsIn: 2 * 86_400)
        #expect(titles(store).contains("Week: 20%, resets on Wednesday at 12:00 (in 2 days)"))
    }

    @Test("The countdown is counted in the zone the weekday was named in")
    func countdownFollowsTheGivenZone() {
        // One pair of instants, read in two zones.  Europe/London springs
        // forward on 2026-03-29, so noon Saturday to noon Monday is two
        // calendar days there but only 47 hours; America/Denver, which
        // has already made its shift, sees the same 47 hours as one day.
        //
        // Asserting both is what makes this falsifiable anywhere: a
        // countdown taken from the machine's own calendar rather than
        // the given one would read the same in both rows, whatever
        // machine runs the test.
        let london = TimeZone(identifier: "Europe/London")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        let saturdayNoon = DateComponents(
            calendar: calendar, year: 2026, month: 3, day: 28, hour: 12
        ).date!
        let mondayNoon = DateComponents(
            calendar: calendar, year: 2026, month: 3, day: 30, hour: 12
        ).date!

        // The premise both rows rest on: 47 hours, spanning two Mondays
        // that are named differently in the two zones.
        #expect(mondayNoon.timeIntervalSince(saturdayNoon) == 47 * 3600)

        let store = IndicatorStore()
        store.apply(.samples(
            session: UsageSample(percent: 25, resetsAt: saturdayNoon.addingTimeInterval(3600)),
            week: UsageSample(percent: 20, resetsAt: mondayNoon),
            asOf: saturdayNoon,
            tokenExpiresAt: mondayNoon.addingTimeInterval(3600)
        ))
        store.revalidate(now: saturdayNoon)

        func weekRow(in timeZone: TimeZone) -> String? {
            MenuBuilder.menu(
                store: store,
                target: NSApp,
                actions: actions,
                refreshPending: nil,
                timeZone: timeZone,
                now: saturdayNoon
            ).items.map(\.title).first { $0.hasPrefix("Week:") }
        }

        #expect(weekRow(in: london) == "Week: 20%, resets on Monday at 12:00 (in 2 days)")
        #expect(
            weekRow(in: TimeZone(identifier: "America/Denver")!)
                == "Week: 20%, resets on Monday at 05:00 (in 1 day)"
        )
    }

    @Test("A row MonoCl cannot vouch for states no reset time")
    func unknownRowStatesNoReset() {
        let store = IndicatorStore()
        store.revalidate(now: now)
        let session = titles(store).first { $0.hasPrefix("Session:") }
        #expect(session == "Session: — no recent reading")
    }

    @Test("The platform row opens the status page; the usage rows stay inert")
    func platformRowOpensTheStatusPage() {
        let store = IndicatorStore()
        store.revalidate(now: .now)
        let rows = items(store)

        let platform = rows.first { $0.title.hasPrefix("Platform:") }
        #expect(platform?.action == #selector(NSApplication.hide(_:)))
        #expect(platform?.target === NSApp)

        // Session and Week report a number MonoCl already shows in full;
        // there is nowhere for them to lead, so they must not look as
        // though there is.
        for prefix in ["Session:", "Week:"] {
            let row = rows.first { $0.title.hasPrefix(prefix) }
            #expect(row?.action == nil)
            #expect(row?.isEnabled == false)
        }
    }
}
