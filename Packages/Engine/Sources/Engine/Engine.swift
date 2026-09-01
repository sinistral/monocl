import ClaudeUsage
import Foundation
import PlatformStatus

/// Drives MonoCl's state: polls both sources, applies what comes back,
/// re-derives the readings, and says when something changed.
///
/// Knows nothing about how any of it is drawn.  `onChange` is a
/// notification, not a payload — the UI samples `store` when it fires.
@MainActor
public final class Engine {
    public let store: IndicatorStore

    private let usage: UsageSource
    private let status: PlatformStatusSource
    private let settings: () -> EngineSettings
    private let time: any TimeSource
    private let onChange: () -> Void

    /// One instance each for the engine's whole life.  Rebuilding a
    /// refresher would discard the instant of its last tick, which is
    /// what `minimumSpacing` measures from, so a second `start()` would
    /// be free to reach the endpoint immediately after the first.
    ///
    /// `lazy` because both tick closures capture `self`, which an
    /// initialiser may not do before its last stored property is set.
    /// Building them on first use rather than in `init` changes nothing
    /// that matters: `Refresher.init` only stores closures, and every
    /// path that observes one goes through the same properties.
    private lazy var usageRefresher = Refresher(
        interval: { [settings] in settings().refreshInterval },
        minimumSpacing: EngineSettings.minimumRefreshInterval,
        time: time,
        retryAfter: { [weak self] in
            guard let self else { return nil }
            return self.rateLimitRemaining(now: self.time.now)
        }
    ) { [weak self] in
        await self?.pollUsage() ?? false
    }

    private lazy var statusRefresher = Refresher(
        interval: { [settings] in settings().refreshInterval },
        minimumSpacing: EngineSettings.minimumRefreshInterval,
        time: time
    ) { [weak self] in
        await self?.pollStatus() ?? false
    }

    /// When the endpoint's last `Retry-After` elapses, held as an
    /// instant rather than a duration.  Scheduling only: what the MENU
    /// says about a rate limit comes from `store.isUsageRateLimited`,
    /// because a 429 need not supply a deadline at all.  Every trigger
    /// restarts the poller, and a duration would be re-armed in full
    /// each time: a menu opened every few minutes during a 15-minute
    /// `Retry-After` would push the deadline out indefinitely, and a
    /// wake after hours asleep would wait the whole period again before
    /// the fetch that matters most.
    private var rateLimitedUntil: Date?

    /// Fires once a retained reading's trust would otherwise lapse
    /// unnoticed.  Independent of `Refresher`'s cadence on purpose: that
    /// cadence stretches to the 15-minute backoff cap, and folding this
    /// in would defeat the backoff's whole purpose.
    private var expiryTask: Task<Void, Never>?

    public init(
        usage: UsageSource,
        status: PlatformStatusSource,
        settings: @escaping () -> EngineSettings,
        time: any TimeSource = SystemTimeSource(),
        onChange: @escaping () -> Void
    ) {
        self.usage = usage
        self.status = status
        self.settings = settings
        self.time = time
        self.onChange = onChange
        let initial = settings()
        store = IndicatorStore(thresholds: initial.thresholds, staleAfter: initial.staleAfter)
    }

    // MARK: - Lifecycle

    public func start() {
        usageRefresher.start()
        statusRefresher.start()
        refreshState()
    }

    /// Stops both pollers and the expiry timer.  The app never calls
    /// this — it only ever exits — but a test that leaves a poller
    /// running leaks it into the next test.
    public func stop() {
        usageRefresher.stop()
        statusRefresher.stop()
        expiryTask?.cancel()
        expiryTask = nil
    }

    // MARK: - Triggers

    public func refreshNow() {
        usageRefresher.refreshNow()
        statusRefresher.refreshNow()
        refreshState()
    }

    public func retryUsage() {
        store.retryUsage()
        usageRefresher.refreshNow()
        refreshState()
    }

    public func settingsChanged() { refreshState() }

    public func systemDidWake() {
        // The held reading may describe a moment hours ago.
        store.clearOnWake(now: time.now)
        // Refreshed before the state is published, as at the other
        // deliberate call sites: the refreshes are what set the pending
        // state the UI displays.
        usageRefresher.refreshNow()
        statusRefresher.refreshNow()
        refreshState()
    }

    /// Re-derives before the menu is shown: the held reading may have
    /// crossed its staleness budget since the last poll, and the
    /// staleness rule is what keeps the displayed value honest.
    ///
    /// Opening the menu deliberately does NOT fetch.  It is how the user
    /// reaches Quit and Settings, so a fetch here would put the request
    /// rate in the hands of a gesture made for unrelated reasons — up to
    /// one request a minute against a five-minute cadence.  A user who
    /// wants a fresh number has "Refresh now" one click away.
    public func menuWillOpen() { refreshState() }

    /// The menu carries one refresh command for two pollers, so it needs
    /// one answer, and ANY poller waiting takes the command away.
    ///
    /// The alternative — keeping the command while either poller could
    /// still act — was tried and is worse.  Only usage is ever rate
    /// limited, so for the hour a `Retry-After` can last, that rule
    /// leaves a live "Refresh now" that cannot move the two rows the
    /// user came to read.  It would still refresh the platform row, so
    /// it is a partial command rather than a dead one, but partial in
    /// exactly the half nobody opened the menu for.
    ///
    /// The cost of this rule is that platform status cannot be refreshed
    /// BY HAND while usage is rate limited.  It keeps polling on its own
    /// cadence throughout, so nothing goes stale; only the button is
    /// unavailable, and only until usage next gets an answer that is not
    /// a refusal.
    public var pendingRefresh: PendingRefresh? {
        PendingRefresh.forMenu(
            rateLimited: store.isUsageRateLimited,
            refreshesOutstanding: [
                usageRefresher.isRefreshPending,
                statusRefresher.isRefreshPending,
            ]
        )
    }

    // MARK: - Polling

    private func pollUsage() async -> Bool {
        guard !store.usagePollingStopped else { return true }
        let outcome = await usage.fetch(now: time.now)
        if case let .failure(.rateLimited(retryAfter)) = outcome {
            rateLimitedUntil = retryAfter.map { time.now.addingTimeInterval($0) }
        } else {
            rateLimitedUntil = nil
        }
        store.apply(outcome)
        refreshState()
        if case .samples = outcome { return true }
        return false
    }

    private func pollStatus() async -> Bool {
        let outcome = await status.fetch(now: time.now)
        store.apply(outcome)
        refreshState()
        if case .sample = outcome { return true }
        return false
    }

    private func rateLimitRemaining(now: Date) -> TimeInterval? {
        guard let rateLimitedUntil else { return nil }
        let remaining = rateLimitedUntil.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Derivation

    /// Applies the current settings, re-derives the readings, re-arms
    /// the expiry timer, and announces the change.  Settings are applied
    /// here rather than at poll time so moving a threshold updates the
    /// lights immediately.
    private func refreshState() {
        let current = settings()
        store.thresholds = current.thresholds
        store.staleAfter = current.staleAfter
        store.revalidate(now: time.now)
        armExpiryTimer()
        onChange()
    }

    /// Cancels and re-arms the expiry timer for the earliest instant any
    /// currently-trusted reading stops being trusted.  A retained
    /// reading can outlive the poll that produced it, so nothing else
    /// would re-derive it before the next poll — which, under backoff,
    /// may be up to 15 minutes away.
    private func armExpiryTimer() {
        expiryTask?.cancel()
        expiryTask = nil
        let now = time.now
        guard let expiry = store.nextTrustExpiry(now: now), expiry > now else { return }
        let wait = expiry.timeIntervalSince(now)
        // `self` is captured only after the sleep: `refreshState()`
        // arms another one of these tasks, so a strong capture would let
        // a released engine keep itself, and both pollers, alive.
        expiryTask = Task { [weak self, time] in
            await time.sleep(for: wait, tolerance: wait * 0.1)
            guard let self, !Task.isCancelled else { return }
            self.refreshState()
        }
    }
}
