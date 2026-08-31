import AppKit
import ClaudeUsage
import Indicators
import Observation
import PlatformStatus

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preferences = Preferences()
    private lazy var store = IndicatorStore(
        thresholds: preferences.thresholds,
        staleAfter: preferences.staleAfter
    )

    private let usage = UsageSource(
        credentials: resolvedCredentialReader(),
        http: EphemeralHTTPFetcher()
    )
    private let status = PlatformStatusSource()

    private var statusItem: NSStatusItem?
    private var usageRefresher: Refresher?
    private var statusRefresher: Refresher?
    /// When the endpoint's last `Retry-After` elapses, held as an
    /// instant rather than a duration.  Scheduling only: what the MENU
    /// says about a rate limit comes from `store.isUsageRateLimited`,
    /// because a 429 need not supply a deadline at all.  Every trigger restarts the
    /// poller, and a duration would be re-armed in full each time: a
    /// menu opened every few minutes during a 15-minute `Retry-After`
    /// would push the deadline out indefinitely, and a wake after hours
    /// asleep would wait the whole period again before the fetch that
    /// matters most.
    private var rateLimitedUntil: Date?

    /// Fires once a retained reading's trust would otherwise lapse
    /// unnoticed.  Independent of `Refresher`'s cadence on purpose: that
    /// cadence stretches to the 15-minute backoff cap, and folding this
    /// in would defeat the backoff's whole purpose.
    private var expiryTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonoCl"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        usageRefresher = Refresher(
            interval: { [preferences] in preferences.refreshInterval },
            minimumSpacing: Preferences.minimumRefreshInterval,
            retryAfter: { [weak self] in self?.rateLimitRemaining(now: .now) }
        ) { [weak self] in
            await self?.pollUsage() ?? false
        }

        statusRefresher = Refresher(
            interval: { [preferences] in preferences.refreshInterval },
            minimumSpacing: Preferences.minimumRefreshInterval
        ) { [weak self] in
            await self?.pollStatus() ?? false
        }

        usageRefresher?.start()
        statusRefresher?.start()

        observeSystemNotifications()
        render()
    }

    // MARK: - Polling

    private func pollUsage() async -> Bool {
        guard !store.usagePollingStopped else { return true }
        let outcome = await usage.fetch(now: .now)
        if case let .failure(.rateLimited(retryAfter)) = outcome {
            rateLimitedUntil = retryAfter.map { Date.now.addingTimeInterval($0) }
        } else {
            rateLimitedUntil = nil
        }
        store.apply(outcome)
        render()
        if case .samples = outcome { return true }
        return false
    }

    private func rateLimitRemaining(now: Date) -> TimeInterval? {
        guard let rateLimitedUntil else { return nil }
        let remaining = rateLimitedUntil.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    private func pollStatus() async -> Bool {
        let outcome = await status.fetch(now: .now)
        store.apply(outcome)
        render()
        if case .sample = outcome { return true }
        return false
    }

    // MARK: - Rendering

    private func render() {
        store.thresholds = preferences.thresholds
        store.staleAfter = preferences.staleAfter
        store.revalidate(now: .now)
        renderIcon()
        renderMenu()
        armExpiryTimer()
    }

    /// Cancels and re-arms the expiry timer for the earliest instant any
    /// currently-trusted reading stops being trusted. A retained reading
    /// can outlive the poll that produced it, so nothing else would
    /// revalidate it before the next poll — which, under backoff, may be
    /// up to 15 minutes away.
    private func armExpiryTimer() {
        expiryTask?.cancel()
        expiryTask = nil
        let now = Date.now
        guard let expiry = store.nextTrustExpiry(now: now), expiry > now else { return }
        let wait = expiry.timeIntervalSince(now)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(wait * 0.1))
            guard let self, !Task.isCancelled else { return }
            self.render()
        }
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        let spec = iconSpec(
            for: store.states,
            differentiateWithoutColor: NSWorkspace.shared
                .accessibilityDisplayShouldDifferentiateWithoutColor
        )
        button.image = MenuBarIcon.image(for: spec, appearance: button.effectiveAppearance)
        button.toolTip = TooltipComposer.tooltip(
            session: store.session,
            week: store.week,
            platform: store.platform,
            sessionResetsAt: store.sessionResetsAt,
            weekResetsAt: store.weekResetsAt
        )
    }

    /// Rebuilds the menu's items in place rather than reassigning
    /// `statusItem.menu`: this avoids reassigning it from inside the
    /// menu's own delegate callback (`menuNeedsUpdate(_:)`). Populating
    /// items does not re-fire `menuNeedsUpdate`, so there is no
    /// recursion.
    private func renderMenu() {
        guard let menu = statusItem?.menu else { return }
        MenuBuilder.populate(
            menu,
            store: store,
            target: self,
            actions: .init(
                refresh: #selector(refreshNow),
                retry: #selector(retryUsage),
                openSettings: #selector(openSettings),
                quit: #selector(quit)
            ),
            refreshPending: pendingRefresh
        )
    }

    /// The menu carries one refresh command for two pollers, so it
    /// needs one answer, and ANY poller waiting takes the command away.
    ///
    /// The alternative — keeping the command while either poller could
    /// still act — was tried and is worse.  Only usage is ever rate
    /// limited, so for the hour a `Retry-After` can last, that rule
    /// leaves a live "Refresh now" that cannot move the two rows the
    /// user came to read.  It would still refresh the platform row, so
    /// it is a partial command rather than a dead one, but partial in
    /// exactly the half nobody opened the menu for.
    ///
    /// The cost of this rule is that platform status cannot be
    /// refreshed BY HAND while usage is rate limited.  It keeps polling
    /// on its own cadence throughout, so nothing goes stale; only the
    /// button is unavailable, and only until usage next gets an answer
    /// that is not a refusal.
    private var pendingRefresh: PendingRefresh? {
        PendingRefresh.forMenu(
            rateLimited: store.isUsageRateLimited,
            refreshesOutstanding: [
                usageRefresher?.isRefreshPending == true,
                statusRefresher?.isRefreshPending == true,
            ]
        )
    }

    func settingsChanged() { render() }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Re-render before the menu is shown: the held reading may have
        // crossed its staleness budget since the last poll, and the
        // staleness rule is what keeps the displayed value honest.
        //
        // Opening the menu deliberately does NOT fetch.  It is how the
        // user reaches Quit and Settings, so a fetch here would put the
        // request rate in the hands of a gesture made for unrelated
        // reasons — up to one request a minute against a five-minute
        // cadence.  A user who wants a fresh number has "Refresh now"
        // one click away.
        render()
    }

    // MARK: - System notifications

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The held reading may describe a moment hours ago.
                self.store.clearOnWake(now: .now)
                // Rendered after the refreshes, as at the other
                // deliberate call sites: they are what set the pending
                // state the render displays.
                self.usageRefresher?.refreshNow()
                self.statusRefresher?.refreshNow()
                self.render()
            }
        }

        center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    // MARK: - Menu actions

    @objc private func refreshNow() {
        usageRefresher?.refreshNow()
        statusRefresher?.refreshNow()
        render()
    }

    @objc private func retryUsage() {
        store.retryUsage()
        usageRefresher?.refreshNow()
        render()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
