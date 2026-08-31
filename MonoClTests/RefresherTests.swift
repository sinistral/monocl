// MonoClTests/RefresherTests.swift
import Foundation
import Testing
@testable import MonoCl

/// Small enough that every test in this file completes in well under a
/// second; large enough that the scheduler cannot plausibly reorder
/// ticks relative to it.
private let base: TimeInterval = 0.01

/// Signals each invocation over an `AsyncStream` so a test can await a
/// specific tick deterministically, rather than sleeping and hoping one
/// has happened.
@MainActor
private final class TickSpy {
    private let outcome: () -> Bool
    private(set) var callCount = 0
    private let continuation: AsyncStream<Int>.Continuation
    let ticks: AsyncStream<Int>

    init(_ outcome: @escaping () -> Bool) {
        self.outcome = outcome
        var continuation: AsyncStream<Int>.Continuation!
        ticks = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func tick() async -> Bool {
        callCount += 1
        let result = outcome()
        continuation.yield(callCount)
        return result
    }
}

@MainActor
@Suite("Refresher state machine")
struct RefresherTests {
    /// Consumes exactly `count` elements from `stream` and returns.  Each
    /// call makes a fresh iterator over the stream's shared storage, so
    /// sequential calls on the same stream pick up where the last left
    /// off rather than starting over.
    private func waitForTicks(_ count: Int, from stream: AsyncStream<Int>) async {
        var seen = 0
        for await _ in stream {
            seen += 1
            if seen >= count { break }
        }
    }

    @Test("Ticking continues across repeated failures")
    func ticksAcrossFailures() async {
        let spy = TickSpy { false }
        let refresher = Refresher(interval: { base }, minimumSpacing: 0) { await spy.tick() }

        refresher.start()
        await waitForTicks(4, from: spy.ticks)
        refresher.stop()

        #expect(spy.callCount >= 4)
    }

    @Test("Consecutive failures lengthen the interval, so fewer ticks land in a fixed window than a run of successes")
    func failuresLengthenTheInterval() async {
        let failing = TickSpy { false }
        let succeeding = TickSpy { true }
        let a = Refresher(interval: { base }, minimumSpacing: 0) { await failing.tick() }
        let b = Refresher(interval: { base }, minimumSpacing: 0) { await succeeding.tick() }

        a.start()
        b.start()
        try? await Task.sleep(for: .seconds(base * 30))
        a.stop()
        b.stop()

        #expect(succeeding.callCount > failing.callCount)
    }

    @Test("A success resets the count, recovering to the base pace")
    func successResetsCount() async {
        var attempt = 0
        let recovers = TickSpy { attempt += 1; return attempt > 3 }
        let staysFailed = TickSpy { false }
        let a = Refresher(interval: { base }, minimumSpacing: 0) { await recovers.tick() }
        let b = Refresher(interval: { base }, minimumSpacing: 0) { await staysFailed.tick() }

        a.start()
        b.start()
        try? await Task.sleep(for: .seconds(base * 30))
        a.stop()
        b.stop()

        // Both fail the first three attempts identically, so any excess
        // in the recovering one comes from its backoff resetting on the
        // fourth attempt's success while the other keeps compounding.
        #expect(recovers.callCount > staysFailed.callCount)
    }

    @Test("refreshNow clears the count and restarts immediately")
    func refreshNowClearsCount() async {
        let refreshedSpy = TickSpy { false }
        let baselineSpy = TickSpy { false }
        let refreshed = Refresher(interval: { base }, minimumSpacing: 0) { await refreshedSpy.tick() }
        let baseline = Refresher(interval: { base }, minimumSpacing: 0) { await baselineSpy.tick() }

        refreshed.start()
        baseline.start()
        // Both accumulate the same backoff from three identical failures.
        await waitForTicks(3, from: refreshedSpy.ticks)
        await waitForTicks(3, from: baselineSpy.ticks)

        refreshed.refreshNow()
        // The restarted loop ticks immediately, before any sleep.
        await waitForTicks(1, from: refreshedSpy.ticks)
        #expect(refreshedSpy.callCount == 4)

        try? await Task.sleep(for: .seconds(base * 30))
        refreshed.stop()
        baseline.stop()

        // The reset refresher recovers to the fast base pace; the
        // untouched baseline keeps compounding, so it ticks far less in
        // the same window.
        #expect(refreshedSpy.callCount > baselineSpy.callCount)
    }

    // MARK: - Minimum spacing

    /// Long enough that a burst of triggers cannot outrun it even on a
    /// loaded machine; short enough to keep these tests sub-second.
    private var spacing: TimeInterval { 0.3 }

    @Test("A burst of triggers produces one tick, because none may land inside the minimum spacing")
    func triggersCannotOutpaceTheSpacing() async {
        let spy = TickSpy { true }
        let refresher = Refresher(interval: { base }, minimumSpacing: spacing) {
            await spy.tick()
        }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // Every trigger that reaches an endpoint goes through start():
        // the menu opening, "Refresh now", and waking all do.
        refresher.refreshNow()
        refresher.refreshIfNotBackingOff()
        refresher.refreshNow()

        try? await Task.sleep(for: .seconds(spacing / 3))
        refresher.stop()

        #expect(spy.callCount == 1)
    }

    @Test("A trigger inside the spacing is deferred, not dropped")
    func deferredTriggerStillLands() async {
        let spy = TickSpy { true }
        // A base interval far longer than the test's lifetime, so the
        // second tick can only come from the deferred trigger.
        let refresher = Refresher(interval: { 100 }, minimumSpacing: spacing) {
            await spy.tick()
        }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        let firstTickAt = Date.now
        refresher.refreshNow()
        await waitForTicks(1, from: spy.ticks)
        let secondTickAt = Date.now
        refresher.stop()

        #expect(spy.callCount == 2)
        // Measured from after the first tick was observed rather than
        // from when it was issued, so the gap reads a hair short of the
        // spacing.  An unfloored trigger would read ~0 either way.
        #expect(secondTickAt.timeIntervalSince(firstTickAt) >= spacing * 0.9)
    }

    @Test("The spacing also floors the scheduled cadence, so a short interval cannot beat it")
    func spacingFloorsTheCadence() async {
        let spy = TickSpy { true }
        let refresher = Refresher(interval: { base }, minimumSpacing: spacing) {
            await spy.tick()
        }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // base is 0.01 s, so an unfloored loop would tick ~30 times here.
        try? await Task.sleep(for: .seconds(spacing / 3))
        refresher.stop()

        #expect(spy.callCount == 1)
    }

    @Test("A restart waits out a server's Retry-After, not merely the spacing")
    func restartHonoursRetryAfter() async {
        let spy = TickSpy { false }
        var retryAfter: TimeInterval?
        // No spacing and a long cadence, so the only thing that can hold
        // the restarted tick back is the Retry-After.
        let refresher = Refresher(
            interval: { 100 },
            minimumSpacing: 0,
            retryAfter: { retryAfter }
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)

        retryAfter = 0.3
        refresher.refreshNow()
        try? await Task.sleep(for: .seconds(0.1))
        refresher.stop()

        #expect(spy.callCount == 1)
    }

    @Test("refreshIfNotBackingOff produces no additional tick while backing off, unlike refreshNow")
    func refreshIfNotBackingOffRespectsBackoff() async {
        let noOpSpy = TickSpy { false }
        let resetSpy = TickSpy { false }
        let noOpRefresher = Refresher(interval: { base }, minimumSpacing: 0) { await noOpSpy.tick() }
        let resetRefresher = Refresher(interval: { base }, minimumSpacing: 0) { await resetSpy.tick() }

        noOpRefresher.start()
        resetRefresher.start()
        // Both accumulate the same backoff from three identical failures.
        await waitForTicks(3, from: noOpSpy.ticks)
        await waitForTicks(3, from: resetSpy.ticks)

        noOpRefresher.refreshIfNotBackingOff()
        resetRefresher.refreshNow()

        await waitForTicks(1, from: resetSpy.ticks)
        #expect(resetSpy.callCount == 4)

        // noOpRefresher's existing task was left untouched: its
        // accumulated backoff from three failures has not elapsed in
        // the near-instant it took resetRefresher's fresh task to tick,
        // so refreshIfNotBackingOff must not have produced an extra one.
        #expect(noOpSpy.callCount == 3)

        noOpRefresher.stop()
        resetRefresher.stop()
    }

    @Test("stop cancels the loop")
    func stopCancels() async {
        let spy = TickSpy { true }
        let refresher = Refresher(interval: { base }, minimumSpacing: 0) { await spy.tick() }

        refresher.start()
        await waitForTicks(2, from: spy.ticks)
        refresher.stop()
        let countAtStop = spy.callCount

        try? await Task.sleep(for: .seconds(base * 20))
        #expect(spy.callCount == countAtStop)
    }
}
