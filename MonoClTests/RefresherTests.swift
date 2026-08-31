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
        let refresher = Refresher(interval: { base }) { await spy.tick() }

        refresher.start()
        await waitForTicks(4, from: spy.ticks)
        refresher.stop()

        #expect(spy.callCount >= 4)
    }

    @Test("Consecutive failures lengthen the interval, so fewer ticks land in a fixed window than a run of successes")
    func failuresLengthenTheInterval() async {
        let failing = TickSpy { false }
        let succeeding = TickSpy { true }
        let a = Refresher(interval: { base }) { await failing.tick() }
        let b = Refresher(interval: { base }) { await succeeding.tick() }

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
        let a = Refresher(interval: { base }) { await recovers.tick() }
        let b = Refresher(interval: { base }) { await staysFailed.tick() }

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
        let refreshed = Refresher(interval: { base }) { await refreshedSpy.tick() }
        let baseline = Refresher(interval: { base }) { await baselineSpy.tick() }

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

    @Test("stop cancels the loop")
    func stopCancels() async {
        let spy = TickSpy { true }
        let refresher = Refresher(interval: { base }) { await spy.tick() }

        refresher.start()
        await waitForTicks(2, from: spy.ticks)
        refresher.stop()
        let countAtStop = spy.callCount

        try? await Task.sleep(for: .seconds(base * 20))
        #expect(spy.callCount == countAtStop)
    }
}
