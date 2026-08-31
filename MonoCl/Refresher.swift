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
@MainActor
final class Refresher {
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    private let interval: () -> TimeInterval
    private let tick: () async -> Bool
    private let retryAfter: () -> TimeInterval?

    /// - Parameter tick: performs one fetch; returns whether it succeeded.
    init(
        interval: @escaping () -> TimeInterval,
        retryAfter: @escaping () -> TimeInterval? = { nil },
        tick: @escaping () async -> Bool
    ) {
        self.interval = interval
        self.retryAfter = retryAfter
        self.tick = tick
    }

    func start() {
        stop()
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                let succeeded = await self.tick()
                self.consecutiveFailures = succeeded ? 0 : self.consecutiveFailures + 1
                let wait = backoffInterval(
                    base: self.interval(),
                    consecutiveFailures: self.consecutiveFailures,
                    retryAfter: self.retryAfter()
                )
                try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(wait * 0.1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refreshNow() {
        consecutiveFailures = 0
        start()
    }

    /// Requests a tick without disturbing the backoff.
    ///
    /// Used by incidental triggers such as opening the menu: clearing the
    /// failure count there would let a gesture the user makes to reach
    /// Quit collapse an accumulated backoff to the base interval.
    func refreshIfNotBackingOff() {
        guard consecutiveFailures == 0 else { return }
        start()
    }
}
