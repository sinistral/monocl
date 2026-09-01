// Packages/Engine/Tests/EngineTests/PendingRefreshTests.swift
import Testing
@testable import Engine

/// `Engine` passes one entry per poller, and the menu has one row for
/// however many of them exist, so the cases that matter are the counts:
/// none, some, all.  Exercised directly because a pure function's whole
/// truth table costs less here than the engine setup each case would
/// otherwise need.
@Suite("PendingRefresh.forMenu")
struct PendingRefreshTests {
    @Test("No outstanding refresh leaves the command in place")
    func noneOutstanding() {
        #expect(
            PendingRefresh.forMenu(rateLimited: false, refreshesOutstanding: [false, false]) == nil
        )
    }

    @Test("One outstanding refresh withdraws the command for both rows")
    func oneOutstanding() {
        #expect(
            PendingRefresh.forMenu(rateLimited: false, refreshesOutstanding: [true, false])
                == .refreshing
        )
        #expect(
            PendingRefresh.forMenu(rateLimited: false, refreshesOutstanding: [false, true])
                == .refreshing
        )
    }

    @Test("Both outstanding still reads as one refresh")
    func bothOutstanding() {
        #expect(
            PendingRefresh.forMenu(rateLimited: false, refreshesOutstanding: [true, true])
                == .refreshing
        )
    }

    @Test("A rate limit outranks any number of outstanding refreshes")
    func rateLimitWins() {
        #expect(
            PendingRefresh.forMenu(rateLimited: true, refreshesOutstanding: [false, false])
                == .rateLimited
        )
        #expect(
            PendingRefresh.forMenu(rateLimited: true, refreshesOutstanding: [true, false])
                == .rateLimited
        )
    }
}
