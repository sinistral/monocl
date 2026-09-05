import AppKit
import AppUpdate
import ClaudeUsage
import Engine
import Indicators
import PlatformStatus
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSViewToolTipOwner {
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

    /// Nil when the check is switched off, or when
    /// `CFBundleShortVersionString` does not parse as a version, which
    /// leaves nothing to compare a release against.
    private lazy var updateChecker: UpdateChecker? = {
        guard UpdateChecker.isEnabled() else { return nil }
        guard let current = UpdateChecker.runningVersion else { return nil }
        let source = UpdateSource()
        return UpdateChecker(
            check: { await source.check(against: current) },
            onChange: { [weak self] in self?.renderMenu() }
        )
    }()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    /// Held so the registration can be undone: the default centre keeps
    /// a block-based observer until it is handed back this token.
    private var buttonGeometryObserver: (any NSObjectProtocol)?

    /// The bounds the current tooltip rect describes, so a registration
    /// that would change nothing can be skipped.
    private var registeredTooltipRect: NSRect?

    /// The readings the two surfaces render.  Exposed for the tests that
    /// seed a delegate and read back what it would display.
    var store: IndicatorStore { engine.store }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        NSApp.mainMenu = Self.makeMainMenu()
        observeSystemNotifications()
        observeButtonGeometry(item.button)
        engine.start()
        updateChecker?.start()
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
        renderIcon(on: button)
    }

    /// Takes the button rather than reaching for the status item's, so a
    /// test can watch what is done to it.
    func renderIcon(on button: NSButton) {
        let spec = iconSpec(
            session: engine.store.session,
            week: engine.store.week,
            platform: engine.store.platform
        )
        button.image = MenuBarIcon.image(for: spec)

        registerTooltip(on: button)

        // `NSView` derives accessibility help from the `toolTip`
        // property, and a tooltip rect does not feed it -- measured on
        // macOS 26: with the property, `accessibilityHelp()` is the
        // string; with a rect and no property, nil.  So the readings
        // have to be stated outright, or a VoiceOver user would be left
        // with nothing where they previously had the whole hover text.
        //
        // Pushed on each render, and so as stale between polls as the
        // property it replaces was.  The pull that keeps the countdown
        // live is a tooltip mechanism; there is no equivalent hook here
        // to hang it on.
        button.setAccessibilityHelp(tooltipText())
    }

    /// Points AppKit at this delegate for the button's hover text.
    ///
    /// A tooltip rect rather than the `toolTip` property because the
    /// text contains a countdown: a pushed string is only as fresh as
    /// the render that pushed it, whereas AppKit asks the owner for the
    /// text as the tooltip is about to appear.
    ///
    /// The rect is the button's own bounds, so every caller has to have
    /// those settled first, and it has to be re-taken whenever they
    /// change.  A variable-length status button is sized to its content:
    /// measured on macOS 26 it is 16pt bare and 50pt once it holds the
    /// 34pt glyph, taking that width on the assignment rather than at
    /// some later layout pass.  Hence the two callers — after the image
    /// in `renderIcon(on:)`, and from `observeButtonGeometry` for the
    /// resizes no render is watching for.
    ///
    /// Nothing happens unless the bounds actually moved.  Tearing the
    /// rect down and rebuilding it drops any tooltip currently on screen,
    /// and AppKit will not put it back until the pointer leaves and
    /// returns — so re-registering unconditionally would snatch the text
    /// away from a reader mid-hover every time a poll landed, which is
    /// the one moment this whole mechanism exists to serve.  It also
    /// collapses the double registration a render would otherwise do,
    /// the image's resize having already prompted one.
    private func registerTooltip(on button: NSButton) {
        guard registeredTooltipRect != button.bounds else { return }
        button.removeAllToolTips()
        button.addToolTip(button.bounds, owner: self, userData: nil)
        registeredTooltipRect = button.bounds
    }

    /// The hover text, composed on demand.
    ///
    /// The icon and the percentages can only change when a poll lands,
    /// but the countdown beside them changes continuously and costs
    /// nothing to recompute — so it is taken from the clock at the moment
    /// the reader asks, while the utilisation stays exactly what the last
    /// poll reported.  Mixed freshness, deliberately: one of the two can
    /// be known for free and the other cannot.
    func tooltipText(now: Date = .now) -> String {
        TooltipComposer.tooltip(
            session: store.session,
            week: store.week,
            platform: store.platform,
            sessionResetsAt: store.sessionResetsAt,
            weekResetsAt: store.weekResetsAt,
            now: now
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
                openReleasePage: #selector(openReleasePage),
                quit: #selector(quit)
            ),
            refreshPending: engine.pendingRefresh,
            availableUpdate: updateChecker?.available
        )
    }

    func settingsChanged() { engine.settingsChanged() }

    // MARK: - NSViewToolTipOwner

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        tooltipText()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.menuWillOpen()
    }

    // MARK: - System notifications

    /// Re-registers the tooltip whenever `button`'s frame changes —
    /// resizes a render would not otherwise hear about, the menu bar's
    /// thickness following the display among them.  Why the rect has to
    /// follow the bounds at all is on `registerTooltip(on:)`.
    ///
    /// Takes the button rather than reaching for the status item's, so a
    /// test can resize its own and watch what follows.
    ///
    /// On the main queue, which `MainActor.assumeIsolated` below requires
    /// — that call traps rather than warns, so a block reached from any
    /// other thread would take the app down.  It costs nothing: a
    /// notification posted from the main queue runs its block inline
    /// there, so the rect is re-taken as the resize happens rather than a
    /// turn later.
    ///
    /// Replaces any previous registration.  This is reachable more than
    /// once, and two observers on one button would re-register the rect
    /// twice on every resize.
    func observeButtonGeometry(_ button: NSButton?) {
        guard let button else { return }
        stopObservingButtonGeometry()
        button.postsFrameChangedNotifications = true
        buttonGeometryObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: button, queue: .main
        ) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                self.registerTooltip(on: button)
            }
        }
    }

    /// Hands the observer back to the notification centre.
    ///
    /// The app never calls this — it observes for as long as it runs —
    /// but a test that registers and does not unregister leaves a block
    /// in the process-wide centre outliving the test that made it.
    func stopObservingButtonGeometry() {
        guard let buttonGeometryObserver else { return }
        NotificationCenter.default.removeObserver(buttonGeometryObserver)
        self.buttonGeometryObserver = nil
    }

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

    /// Opens the release the update row names, which is where what
    /// changed is written down.  MonoCl installs nothing itself: the
    /// build is a local one, and an updater that replaced it would be
    /// replacing a bundle the reader compiled.
    @objc private func openReleasePage() {
        guard let page = updateChecker?.available?.page else { return }
        NSWorkspace.shared.open(page)
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
