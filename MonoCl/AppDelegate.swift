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
        credentials: KeychainCredentialReader(),
        http: EphemeralHTTPFetcher()
    )
    private let status = PlatformStatusSource()

    private var statusItem: NSStatusItem?
    private var usageRefresher: Refresher?
    private var statusRefresher: Refresher?
    private var lastRateLimitRetryAfter: TimeInterval?

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
            retryAfter: { [weak self] in self?.lastRateLimitRetryAfter }
        ) { [weak self] in
            await self?.pollUsage() ?? false
        }

        statusRefresher = Refresher(
            interval: { [preferences] in preferences.refreshInterval }
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
            lastRateLimitRetryAfter = retryAfter
        } else {
            lastRateLimitRetryAfter = nil
        }
        store.apply(outcome)
        render()
        if case .samples = outcome { return true }
        return false
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
    /// `statusItem.menu`: this is called from `menuNeedsUpdate(_:)` while
    /// the menu is on screen, and swapping in a new instance mid-tracking
    /// is not safe.
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
            )
        )
    }

    func settingsChanged() { render() }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Re-render before the menu is shown: the held reading may have
        // crossed its staleness budget since the last poll, whose cadence
        // stretches to the backoff cap.
        render()
        usageRefresher?.refreshNow()
        statusRefresher?.refreshNow()
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
                self.render()
                self.usageRefresher?.refreshNow()
                self.statusRefresher?.refreshNow()
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
    }

    @objc private func retryUsage() {
        store.retryUsage()
        usageRefresher?.refreshNow()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
