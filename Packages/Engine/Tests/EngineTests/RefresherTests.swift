// Packages/Engine/Tests/EngineTests/RefresherTests.swift
import Foundation
import Testing
@testable import Engine

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

/// Holds a tick open until the test lets it finish, so "a fetch is
/// in flight" is a fact the test controls rather than a duration it
/// hopes is long enough.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
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

    /// A base interval at the backoff's 900-second cap, so the scheduled
    /// cadence is a flat 900 seconds — further than any test using it
    /// advances the clock, leaving a trigger as the only thing that can
    /// produce a second tick.
    private var beyondTheWindow: TimeInterval { 900 }

    @Test("Ticking continues across repeated failures")
    func ticksAcrossFailures() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { false }
        let refresher = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // Backoff doubles from 300 until the 900-second cap bites on the
        // third wait, so the next three ticks fall at +300, +900 and
        // +1800 from the first, and the fourth would not fall until
        // +2700.
        await time.advance(by: 2100)
        await waitForTicks(3, from: spy.ticks)
        refresher.stop()

        #expect(spy.callCount == 4)
    }

    @Test("Consecutive failures lengthen the interval, so fewer ticks land in a fixed window than a run of successes")
    func failuresLengthenTheInterval() async {
        let time = TestTimeSource(now: origin)
        let failing = TickSpy { false }
        let succeeding = TickSpy { true }
        let a = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await failing.tick() }
        let b = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await succeeding.tick() }

        a.start()
        b.start()
        // Both tick at once on starting; the clock cannot move until
        // those first ticks have registered the sleeps that follow them.
        await waitForTicks(1, from: failing.ticks)
        await waitForTicks(1, from: succeeding.ticks)
        await time.advance(by: 3000)
        a.stop()
        b.stop()

        // The successes hold the flat 300-second cadence, so they land on
        // every multiple of it out to the end of the window.  The
        // failures compound to 300, 600 and then the 900-second cap,
        // putting their ticks at +0, +300, +900, +1800 and +2700.
        #expect(succeeding.callCount == 11)
        #expect(failing.callCount == 5)
        #expect(succeeding.callCount > failing.callCount)
    }

    @Test("A success resets the count, recovering to the base pace")
    func successResetsCount() async {
        let time = TestTimeSource(now: origin)
        var attempt = 0
        let recovers = TickSpy { attempt += 1; return attempt > 3 }
        let staysFailed = TickSpy { false }
        let a = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await recovers.tick() }
        let b = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await staysFailed.tick() }

        a.start()
        b.start()
        await waitForTicks(1, from: recovers.ticks)
        await waitForTicks(1, from: staysFailed.ticks)
        await time.advance(by: 3000)
        a.stop()
        b.stop()

        // Both fail the first three attempts identically, so both reach
        // +1800 having ticked four times.  From there the recovering one
        // succeeds and drops back to the flat 300-second cadence — +2100,
        // +2400, +2700, +3000 — while the other stays on the 900-second
        // cap and manages only +2700.
        #expect(recovers.callCount == 8)
        #expect(staysFailed.callCount == 5)
        #expect(recovers.callCount > staysFailed.callCount)
    }

    @Test("refreshNow clears the count and restarts immediately")
    func refreshNowClearsCount() async {
        let time = TestTimeSource(now: origin)
        let refreshedSpy = TickSpy { false }
        let baselineSpy = TickSpy { false }
        let refreshed = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await refreshedSpy.tick() }
        let baseline = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await baselineSpy.tick() }

        refreshed.start()
        baseline.start()
        // Both accumulate the same backoff from three identical failures,
        // at +0, +300 and +900.
        await waitForTicks(1, from: refreshedSpy.ticks)
        await waitForTicks(1, from: baselineSpy.ticks)
        await time.advance(by: 900)
        await waitForTicks(2, from: refreshedSpy.ticks)
        await waitForTicks(2, from: baselineSpy.ticks)

        refreshed.refreshNow()
        // The restarted loop ticks immediately, before any sleep.
        await waitForTicks(1, from: refreshedSpy.ticks)
        #expect(refreshedSpy.callCount == 4)

        await time.advance(by: 3000)
        refreshed.stop()
        baseline.stop()

        // The reset refresher starts its backoff over from 300, so it
        // fits four more ticks into the remaining window; the untouched
        // baseline keeps compounding and fits two.
        #expect(refreshedSpy.callCount == 8)
        #expect(baselineSpy.callCount == 6)
        #expect(refreshedSpy.callCount > baselineSpy.callCount)
    }

    // MARK: - Minimum spacing

    /// The shipping floor between requests, so the spacing tests measure
    /// the rate the app actually enforces.
    private var spacing: TimeInterval { 300 }

    @Test("A burst of triggers produces one tick, whichever of the two rules discards each one")
    func triggersCannotOutpaceTheSpacing() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { 60 }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // Every trigger that reaches an endpoint goes through start():
        // "Refresh now" and waking both do.  The first is held by the
        // spacing; the rest are dropped as already served.  The point
        // is the count, not which rule caught which.
        refresher.refreshNow()
        refresher.refreshNow()
        refresher.refreshNow()

        // A restarted loop computes its wait from the clock as it stands
        // when start() is called, but only registers that wait once it
        // runs.  Letting it run first is what makes the advance below
        // measure the deferral rather than move the goalposts.
        await settle()
        await time.advance(by: spacing / 3)
        refresher.stop()

        #expect(spy.callCount == 1)
    }

    @Test("A trigger inside the spacing is deferred, not dropped")
    func deferredTriggerStillLands() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        // A base interval far longer than the window this test advances
        // through, so the second tick can only come from the deferred
        // trigger.
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        refresher.refreshNow()
        await settle()

        // A second short of the spacing the trigger is still held; a
        // second later it lands.  An unfloored trigger would have ticked
        // before either point.
        await time.advance(by: spacing - 1)
        #expect(spy.callCount == 1)

        await time.advance(by: 1)
        await waitForTicks(1, from: spy.ticks)
        refresher.stop()

        #expect(spy.callCount == 2)
    }

    @Test("The spacing also floors the scheduled cadence, so a short interval cannot beat it")
    func spacingFloorsTheCadence() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { 60 }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // An unfloored loop would tick at +60, +120, +180 and +240.
        await time.advance(by: spacing - 1)
        refresher.stop()

        #expect(spy.callCount == 1)
    }

    // MARK: - Pending refresh

    @Test("A start announces the fetch it is about to make, so a second click cannot cancel it")
    func startAnnouncesItsFetch() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        // Nothing defers this one — it is the first — but it is still a
        // fetch somebody asked for, and it is about to be in flight.
        refresher.start()
        #expect(refresher.isRefreshPending == true)

        await waitForTicks(1, from: spy.ticks)
        #expect(refresher.isRefreshPending == false)
        refresher.stop()
    }

    @Test("A trigger inside the spacing reports a pending refresh")
    func deferredTriggerIsPending() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        refresher.refreshNow()

        #expect(refresher.isRefreshPending == true)
        refresher.stop()
    }

    @Test("The pending refresh clears once the deferred tick lands")
    func pendingClearsOnTick() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        refresher.refreshNow()
        await settle()
        await time.advance(by: spacing)
        await waitForTicks(1, from: spy.ticks)

        #expect(refresher.isRefreshPending == false)
        refresher.stop()
    }

    @Test("stop clears the pending refresh, since the deferred tick will never land")
    func stopClearsPending() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        refresher.refreshNow()
        refresher.stop()

        #expect(refresher.isRefreshPending == false)
    }

    @Test("The pending refresh lasts until the fetch it announced returns")
    func pendingCoversTheFetch() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        // Signals the moment each fetch BEGINS, so the assertion below
        // lands mid-fetch without a sleep timed to guess at it.
        var signal: AsyncStream<Int>.Continuation!
        let fetchStarts = AsyncStream<Int> { signal = $0 }
        var started = 0
        let gate = Gate()
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) {
            started += 1
            signal.yield(started)
            // The first fetch runs straight through; the announced one is
            // held so the assertion below lands while it is in flight.
            if started > 1 { await gate.wait() }
            return await spy.tick()
        }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        refresher.refreshNow()
        await settle()
        await time.advance(by: spacing)

        await waitForTicks(2, from: fetchStarts)
        // The announced fetch is in flight.  The row must still be
        // showing, or the user can click "Refresh now" again and cancel
        // the request that is seconds from landing.
        #expect(refresher.isRefreshPending == true)

        gate.open()
        await waitForTicks(1, from: spy.ticks)
        #expect(refresher.isRefreshPending == false)
        refresher.stop()
    }

    @Test("A second request cannot cancel the fetch the first one started")
    func secondRequestDoesNotCancelTheFirst() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        var signal: AsyncStream<Int>.Continuation!
        let fetchStarts = AsyncStream<Int> { signal = $0 }
        var started = 0
        let gate = Gate()
        let refresher = Refresher(
            interval: { beyondTheWindow }, minimumSpacing: spacing, time: time
        ) {
            started += 1
            signal.yield(started)
            if started > 1 { await gate.wait() }
            return await spy.tick()
        }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // Pinned, not assumed: refreshNow() is dropped outright while a
        // refresh is outstanding, so a test that reached here with one
        // still pending would wedge on the wait below instead of
        // failing.
        #expect(refresher.isRefreshPending == false)
        refresher.refreshNow()
        await settle()
        await time.advance(by: spacing)
        await waitForTicks(2, from: fetchStarts)

        // A second click, while the announced fetch is in flight.  It
        // must be ignored: restarting would tear that fetch down and
        // defer its replacement by a whole spacing.
        refresher.refreshNow()
        await time.advance(by: spacing)
        #expect(started == 2)

        // Letting the held fetch finish shows it was never torn down: it
        // completes as the second fetch, not as a third replacing it.
        gate.open()
        await waitForTicks(1, from: spy.ticks)
        refresher.stop()

        #expect(started == 2)
    }

    // MARK: - Retry-After

    @Test("A restart waits out a server's Retry-After, not merely the spacing")
    func restartHonoursRetryAfter() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { false }
        var retryAfter: TimeInterval?
        // No spacing and a long cadence, so the only thing that can hold
        // the restarted tick back is the Retry-After.
        let refresher = Refresher(
            interval: { beyondTheWindow },
            minimumSpacing: 0,
            time: time,
            retryAfter: { retryAfter }
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)

        retryAfter = 600
        refresher.refreshNow()
        await settle()
        // With no spacing to serve, an unhonoured Retry-After would have
        // ticked the instant refreshNow() was called.
        await time.advance(by: 599)
        #expect(spy.callCount == 1)

        await time.advance(by: 1)
        await waitForTicks(1, from: spy.ticks)
        refresher.stop()

        #expect(spy.callCount == 2)
    }

    @Test("stop cancels the loop")
    func stopCancels() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { true }
        let refresher = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        await time.advance(by: 300)
        await waitForTicks(1, from: spy.ticks)
        refresher.stop()

        await time.advance(by: 6000)
        #expect(spy.callCount == 2)
    }
}
