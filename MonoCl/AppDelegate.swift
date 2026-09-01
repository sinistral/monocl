import AppKit
import ClaudeUsage
import Engine
import Indicators
import PlatformStatus

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preferences = Preferences()

    private lazy var engine = Engine(
        usage: UsageSource(
            credentials: resolvedCredentialReader(),
            http: EphemeralHTTPFetcher()
        ),
        status: PlatformStatusSource(),
        settings: { [preferences] in
            EngineSettings(
                thresholds: preferences.thresholds,
                refreshInterval: preferences.refreshInterval,
                staleAfter: preferences.staleAfter
            )
        },
        onChange: { [weak self] in self?.render() }
    )

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonoCl"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        observeSystemNotifications()
        engine.start()
    }

    // MARK: - Rendering

    private func render() {
        renderIcon()
        renderMenu()
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        let spec = iconSpec(
            for: engine.store.states,
            differentiateWithoutColor: NSWorkspace.shared
                .accessibilityDisplayShouldDifferentiateWithoutColor
        )
        button.image = MenuBarIcon.image(for: spec, appearance: button.effectiveAppearance)
        button.toolTip = TooltipComposer.tooltip(
            session: engine.store.session,
            week: engine.store.week,
            platform: engine.store.platform,
            sessionResetsAt: engine.store.sessionResetsAt,
            weekResetsAt: engine.store.weekResetsAt
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
            store: engine.store,
            target: self,
            actions: .init(
                refresh: #selector(refreshNow),
                retry: #selector(retryUsage),
                openSettings: #selector(openSettings),
                quit: #selector(quit)
            ),
            refreshPending: engine.pendingRefresh
        )
    }

    func settingsChanged() { engine.settingsChanged() }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.menuWillOpen()
    }

    // MARK: - System notifications

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.systemDidWake() }
        }

        center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Nothing about the readings changed — only how they are
            // drawn — so this never reaches the engine.
            MainActor.assumeIsolated { self?.renderIcon() }
        }
    }

    // MARK: - Menu actions

    @objc private func refreshNow() { engine.refreshNow() }

    @objc private func retryUsage() { engine.retryUsage() }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
