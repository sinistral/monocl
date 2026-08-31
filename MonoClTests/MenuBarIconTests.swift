import AppKit
import Indicators
import Testing
@testable import MonoCl

@MainActor
@Suite("Menu bar icon")
struct MenuBarIconTests {
    private let appearance = NSAppearance(named: .aqua)!

    @Test("The template flag reaches the image")
    func templateFlagPropagates() {
        let quiet = iconSpec(for: [.nominal, .nominal, .nominal],
                            differentiateWithoutColor: false)
        #expect(MenuBarIcon.image(for: quiet, appearance: appearance).isTemplate == true)

        let breached = iconSpec(for: [.critical, .nominal, .nominal],
                               differentiateWithoutColor: false)
        #expect(MenuBarIcon.image(for: breached, appearance: appearance).isTemplate == false)
    }

    @Test("Geometry matches the menu bar and the dot layout")
    func geometry() {
        let spec = iconSpec(for: [.nominal, .nominal, .nominal],
                            differentiateWithoutColor: false)
        let image = MenuBarIcon.image(for: spec, appearance: appearance)
        #expect(image.size.height == NSStatusBar.system.thickness)
        // Three 8pt dots, two 4pt gaps, 2pt inset each side.  The exact
        // number rather than a lower bound: a bound written in terms of
        // the implementation's own constants cannot fail when the layout
        // formula changes, which is the one thing worth being told about.
        #expect(image.size.width == 36)
    }

    @Test("The accessibility description names each dot by position")
    func accessibilityDescriptionNamesDots() {
        let spec = iconSpec(for: [.critical, .nominal, .warning],
                            differentiateWithoutColor: false)
        let image = MenuBarIcon.image(for: spec, appearance: appearance)
        #expect(image.accessibilityDescription == "Session critical, week normal, platform warning")
    }

    @Test("A dot count other than three does not crash")
    func accessibilityDescriptionSurvivesAMismatchedCount() {
        let dots = [DotSpec(fill: .filled, tint: .amber), DotSpec(fill: .filled, tint: .red)]
        let spec = IconSpec(dots: dots, isTemplate: false)
        let image = MenuBarIcon.image(for: spec, appearance: appearance)
        // The three-dot guarantee lives elsewhere; here a mismatch is
        // absorbed as a shorter description rather than an out-of-range
        // crash.
        #expect(image.accessibilityDescription == "Session warning, week critical")
    }

    @Test("The drawing handler produces a bitmap")
    func drawable() throws {
        let spec = iconSpec(for: [.unknown, .warning, .critical],
                            differentiateWithoutColor: true)
        let image = MenuBarIcon.image(for: spec, appearance: appearance)
        // The `#require`s are the assertion: `tiffRepresentation` is nil
        // if the drawing handler produced nothing.  Asserting a size
        // greater than zero would pass on an image that never drew,
        // since the size is set at construction rather than by drawing.
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.size == image.size)
    }
}
