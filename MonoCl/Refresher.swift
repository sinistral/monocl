// MonoCl/Refresher.swift
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
/// Every trigger MonoCl has — the scheduled loop, opening the menu,
/// "Refresh now", waking — reaches the endpoint by calling `start()`.
/// `minimumSpacing` is enforced here so that adding a
/// trigger cannot raise the request rate: no tick may land sooner than
/// that after the previous one, whatever asked for it.  The backoff is
/// a separate mechanism and only ever lengthens the wait further; it
/// reacts to failures, so on its own it bounds nothing while everything
/// succeeds.
@MainActor
final class Refresher {
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// Survives `stop()` deliberately: it records when the endpoint was
    /// last touched, which a restart does not undo.
    private var lastTickAt: Date?

    private let interval: () -> TimeInterval
    private let minimumSpacing: TimeInterval
    private let tick: () async -> Bool
    private let retryAfter: () -> TimeInterval?

    /// - Parameter tick: performs one fetch; returns whether it succeeded.
    init(
        interval: @escaping () -> TimeInterval,
        minimumSpacing: TimeInterval,
        retryAfter: @escaping () -> TimeInterval? = { nil },
        tick: @escaping () async -> Bool
    ) {
        self.interval = interval
        self.minimumSpacing = minimumSpacing
        self.retryAfter = retryAfter
        self.tick = tick
    }

    func start() {
        stop()
        let firstWait = firstTickWait(now: .now)
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
                    self.spacingRemaining(now: .now)
                )
                isFirstTick = false

                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(wait * 0.1))
                    guard !Task.isCancelled else { return }
                }

                self.lastTickAt = .now
                let succeeded = await self.tick()

                // A tick cancelled mid-flight reports failure because
                // the request was torn down, not because the endpoint
                // misbehaved.  Counting it would hand that phantom
                // failure to whichever loop start() has since created,
                // since the count lives on the refresher rather than on
                // the task.
                guard !Task.isCancelled else { return }
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

    func stop() {
        task?.cancel()
        task = nil
    }

    func refreshNow() {
        consecutiveFailures = 0
        start()
    }

    /// Requests a tick without disturbing the backoff.  Like every
    /// other trigger it still waits out the minimum spacing.
    ///
    /// Used by incidental triggers such as opening the menu: clearing the
    /// failure count there would let a gesture the user makes to reach
    /// Quit collapse an accumulated backoff to the base interval.
    func refreshIfNotBackingOff() {
        guard consecutiveFailures == 0 else { return }
        start()
    }
}
