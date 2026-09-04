import AppKit
import Testing

@testable import MonoCl

@MainActor
@Suite("Settings window")
struct SettingsWindowTests {
    private static let title = "MonoCl Settings"

    /// Scoped to windows actually on screen, not every window the
    /// application has ever made: a closed settings window stays in
    /// `NSApp.windows` while its owner holds it, so an unscoped filter
    /// would see the previous test's leftovers.
    private var settingsWindows: [NSWindow] {
        NSApp.windows.filter { $0.title == Self.title && $0.isVisible }
    }

    @Test("Choosing Settings puts a settings window on screen")
    func opensAWindow() {
        let delegate = AppDelegate()
        defer { for window in settingsWindows { window.close() } }

        delegate.openSettings()

        #expect(settingsWindows.count == 1)
        #expect(settingsWindows.first?.isVisible == true)
    }

    @Test("The window is tall enough to show the form, not just a title bar")
    func showsTheForm() {
        let delegate = AppDelegate()
        defer { for window in settingsWindows { window.close() } }

        delegate.openSettings()

        // The form is a fixed 380 points wide and runs to three
        // sections, so a window sized to it is taller than it is wide.
        // A hosting controller that reports no preferred size yields a
        // title bar alone, which this figure excludes.
        let content = settingsWindows.first?.contentLayoutRect.size
        #expect(content?.width == 380)
        #expect((content?.height ?? 0) > 300)
    }

    @Test("Choosing Settings twice reuses the one window")
    func reusesTheWindow() throws {
        let delegate = AppDelegate()
        defer { for window in settingsWindows { window.close() } }

        delegate.openSettings()
        let first = try #require(settingsWindows.first)
        delegate.openSettings()
        let second = try #require(settingsWindows.first)

        #expect(settingsWindows.count == 1)
        #expect(second.isVisible)
        #expect(second === first)
    }

    /// Asserted on the window's own behaviour flag because the effect
    /// -- the window following the user to whichever Space they chose
    /// Settings from -- needs a second Space to observe, which a unit
    /// test has no way to arrange.
    @Test("The window follows the user to the Space they are on")
    func followsTheActiveSpace() throws {
        let delegate = AppDelegate()
        defer { for window in settingsWindows { window.close() } }

        delegate.openSettings()

        let window = try #require(settingsWindows.first)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    @Test("Settings can be closed and chosen again")
    func survivesAClose() {
        let delegate = AppDelegate()
        defer { for window in settingsWindows { window.close() } }

        delegate.openSettings()
        for window in settingsWindows { window.close() }
        delegate.openSettings()

        #expect(settingsWindows.count == 1)
        #expect(settingsWindows.first?.isVisible == true)
    }

    /// Reads the menu off `NSApp`, not off the function that builds it:
    /// the behaviour is the installation, and a menu that is built and
    /// never installed leaves the shortcuts just as dead.  The test
    /// bundle is hosted by the app, so the real delegate has already
    /// finished launching by the time this runs.
    @Test("The keyboard can close the window and quit the app")
    func installsKeyEquivalents() {
        let items = NSApp.mainMenu?.items.first?.submenu?.items ?? []
        let shortcuts = Set(
            items.map { "\($0.keyEquivalent):\($0.action.map(NSStringFromSelector) ?? "")" })

        // Containment rather than equality: AppKit adds a hidden
        // option-W "Close All" of its own to any menu carrying a Close,
        // and that addition is not this app's contract to pin.
        #expect(shortcuts.contains("w:performClose:"))
        #expect(shortcuts.contains("q:terminate:"))
    }
}
