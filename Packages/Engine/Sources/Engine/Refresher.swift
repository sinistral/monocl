// Packages/Engine/Sources/Engine/Refresher.swift
import ClaudeUsage
import Foundation
import Indicators
import PlatformStatus

/// Drives one source on a timer.
///
/// `Task.sleep` carries a tolerance so the system can coalesce these
/// wake-ups with other timers, per Apple's energy guidance — an idle Mac
/// should stay idle.
///
/// Request rate is a property of this object, not of its callers
/// ---
///
/// Off the scheduled cadence, only a deliberate act reaches the
/// endpoint: launching, "Refresh now", and waking, all by calling
/// `start()`.  `minimumSpacing` is enforced here so that adding a
/// trigger cannot raise the request rate: no tick may land sooner than
/// that after the previous one, whatever asked for it.  The backoff is
/// a separate mechanism and only ever lengthens the wait further; it
/// reacts to failures, so on its own it bounds nothing while everything
/// succeeds.
@MainActor
public final class Refresher {
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// Whether a requested refresh has yet to land.  One fact, not a
    /// reason: WHY a refresh cannot happen is the rate limit, and the
    /// rate limit is known to `AppDelegate`, which owns the deadline.
    /// This object only schedules.
    ///
    /// Every `start()` sets it and the ordinary cadence never does,
    /// which is the same distinction: `start()` is only ever called for
    /// a fetch in its own right — launching, "Refresh now", waking —
    /// never for the next turn of the loop.
    public private(set) var isRefreshPending = false

    /// Survives `stop()` deliberately: it records when the endpoint was
    /// last touched, which a restart does not undo.
    private var lastTickAt: Date?

    private let interval: () -> TimeInterval
    private let minimumSpacing: TimeInterval
    private let time: any TimeSource
    private let tick: () async -> Bool
    private let retryAfter: () -> TimeInterval?

    /// - Parameter tick: performs one fetch; returns whether it succeeded.
    public init(
        interval: @escaping () -> TimeInterval,
        minimumSpacing: TimeInterval,
        time: any TimeSource,
        retryAfter: @escaping () -> TimeInterval? = { nil },
        tick: @escaping () async -> Bool
    ) {
        self.interval = interval
        self.minimumSpacing = minimumSpacing
        self.time = time
        self.retryAfter = retryAfter
        self.tick = tick
    }

    public func start() {
        stop()
        let firstWait = firstTickWait(now: time.now)
        isRefreshPending = true
        task = Task { [weak self] in
            // A restart's first tick has no cadence to serve — whoever
            // called start() wants it now — so only the spacing and any
            // Retry-After hold it back.  Every later tick waits for the
            // cadence as well.
            var isFirstTick = true
            while let self, !Task.isCancelled {
                let wait = isFirstTick ? firstWait : max(
                    backoffInterval(
                        base: self.interval(),
                        consecutiveFailures: self.consecutiveFailures,
                        retryAfter: self.retryAfter()
                    ),
                    self.spacingRemaining(now: self.time.now)
                )
                isFirstTick = false

                if wait > 0 {
                    await self.time.sleep(for: wait, tolerance: wait * 0.1)
                    guard !Task.isCancelled else { return }
                }

                self.lastTickAt = self.time.now
                let succeeded = await self.tick()

                // A tick cancelled mid-flight reports failure because
                // the request was torn down, not because the endpoint
                // misbehaved.  Counting it would hand that phantom
                // failure to whichever loop start() has since created,
                // since the count lives on the refresher rather than on
                // the task.  The same goes for the pending flag, which
                // that newer loop now owns.
                guard !Task.isCancelled else { return }
                self.isRefreshPending = false
                self.consecutiveFailures = succeeded ? 0 : self.consecutiveFailures + 1
            }
        }
    }

    /// What must elapse before a restarted loop's first tick.  The
    /// spacing is MonoCl's own politeness; `Retry-After` is the server
    /// stating a limit, and a trigger that skipped it would walk
    /// straight back into the 429 that produced it.
    private func firstTickWait(now: Date) -> TimeInterval {
        max(spacingRemaining(now: now), retryAfter() ?? 0)
    }

    private func spacingRemaining(now: Date) -> TimeInterval {
        guard let lastTickAt else { return 0 }
        return max(0, minimumSpacing - now.timeIntervalSince(lastTickAt))
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRefreshPending = false
    }

    /// Ignored while a requested refresh is still outstanding: that
    /// request is already being served, and restarting would tear down
    /// the fetch it began.  The menu withdraws "Refresh now" for the
    /// same reason, so this guard is what covers the commands it does
    /// not withdraw — "Retry" above all.
    ///
    /// It does NOT cover a fetch the cadence started: the flag marks
    /// requested refreshes only, so a click landing during a scheduled
    /// fetch still cancels it, costing a spacing and a flashed
    /// "Offline".  The window is one fetch every five minutes and the
    /// alternative is tracking in-flight state a restart would race on,
    /// which is more machinery than the fault is worth.
    public func refreshNow() {
        guard !isRefreshPending else { return }
        consecutiveFailures = 0
        start()
    }
}
