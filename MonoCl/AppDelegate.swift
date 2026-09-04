import AppKit
import ClaudeUsage
import Engine
import Indicators
import PlatformStatus
import SwiftUI

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
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonoCl"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        NSApp.mainMenu = Self.makeMainMenu()
        observeSystemNotifications()
        engine.start()
    }

    /// An accessory app shows no menu bar of its own, so this menu is
    /// never seen.  It is installed for its key equivalents: those are
    /// offered to `NSApp.mainMenu` first, and a window has no fallback
    /// of its own, so without it the settings window cannot be closed
    /// from the keyboard and the app cannot be quit from it.
    ///
    /// It deliberately omits the standard Edit menu, which costs the
    /// app every editing shortcut -- Cut, Copy, Paste, Select All,
    /// Undo.  That is free only while Settings holds nothing editable:
    /// it is steppers throughout.  A text field added there would need
    /// this menu to grow an Edit submenu, or the field would silently
    /// ignore the shortcuts everyone expects of it.
    private static func makeMainMenu() -> NSMenu {
        let items = NSMenu()
        items.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        items.addItem(
            withTitle: "Quit MonoCl", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let application = NSMenuItem()
        application.submenu = items
        let menu = NSMenu()
        menu.addItem(application)
        return menu
    }

    // MARK: - Rendering

    private func render() {
        renderIcon()
        renderMenu()
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        let spec = iconSpec(
            session: engine.store.session,
            week: engine.store.week,
            platform: engine.store.platform
        )
        button.image = MenuBarIcon.image(for: spec)
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
                openStatusPage: #selector(openStatusPage),
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
    }

    // MARK: - Menu actions

    @objc private func refreshNow() { engine.refreshNow() }

    @objc private func retryUsage() { engine.retryUsage() }

    /// Opens the page the platform reading was taken from, so what the
    /// reader sees in the browser cannot disagree with the row they
    /// clicked.  No activation call: the page opens in the browser,
    /// which comes forward on its own.
    @objc private func openStatusPage() {
        NSWorkspace.shared.open(PlatformStatusSource.page)
    }

    /// Activating first is what makes the window come forward: clicking
    /// a status item does not activate an accessory app, so an ordered
    /// window would otherwise open behind whatever the user was using,
    /// and never take the keyboard.
    ///
    /// `ignoringOtherApps` is deprecated in favour of the bare
    /// `activate()`, but on macOS 26 the replacement does not activate
    /// this app: measured from inside the app after choosing Settings,
    /// `activate()` leaves `NSApp.isActive` and `isKeyWindow` false a
    /// second later, as does `NSRunningApplication.current.activate`,
    /// while this call makes both true.
    @objc func openSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let content = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                onChange: { [weak self] in self?.settingsChanged() }
            )
        )
        let window = NSWindow(contentViewController: content)
        window.title = "MonoCl Settings"
        // Set before the content is sized: a window keeps its frame
        // across a style change and rederives its content rect from it,
        // so sizing first would leave the measurement at the mercy of
        // whether the dropped styles alter the titlebar metrics.
        window.styleMask = [.titled, .closable]
        // A window built from a hosting controller does not adopt the
        // SwiftUI view's size: without this it opens 380 x 32, a bare
        // title bar with the form laid out behind nothing.  Measuring
        // the view and sizing to it opens the window at its final size.
        window.setContentSize(content.view.fittingSize)
        // The delegate keeps the window across closes so reopening
        // returns the same one; releasing it on close would leave that
        // reference dangling.
        window.isReleasedWhenClosed = false
        // The status item is on every Space, so Settings can be chosen
        // from any of them, but a window keeps the Space it was first
        // ordered onto.  Without this, choosing Settings from a second
        // Space switches the user away to the first rather than
        // bringing the window to them.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        return window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
