import AppKit
import ClaudeUsage
import Indicators
import Observation
import PlatformStatus

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonoCl"
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
        statusItem?.menu = MenuBuilder.menu(
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
