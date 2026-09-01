import AppKit
import Foundation
import Indicators
import Testing
@testable import MonoCl

@MainActor
@Suite("Menu bar icon")
struct MenuBarIconTests {
    private let appearance = NSAppearance(named: .aqua)!

    private func reading(_ state: IndicatorState, percent: Double? = nil) -> Reading {
        Reading(state: state, detail: "", percent: percent, asOf: Date(timeIntervalSince1970: 0))
    }

    private func image(
        session: IndicatorState = .nominal, sessionPercent: Double? = 10,
        week: IndicatorState = .nominal, weekPercent: Double? = 20,
        platform: IndicatorState = .nominal
    ) -> NSImage {
        let spec = iconSpec(
            session: reading(session, percent: sessionPercent),
            week: reading(week, percent: weekPercent),
            platform: reading(platform)
        )
        return MenuBarIcon.image(for: spec, appearance: appearance)
    }

    @Test("The template flag reaches the image")
    func templateFlagPropagates() {
        #expect(image().isTemplate == true)
        #expect(image(session: .critical, sessionPercent: 94).isTemplate == false)
    }

    @Test("Geometry matches the menu bar and the glyph layout")
    func geometry() {
        let icon = image()
        #expect(icon.size.height == NSStatusBar.system.thickness)
        // 2pt inset, a 20pt glyph box, a 6pt gap, the platform disc's
        // 4pt radius, 2pt inset.  The exact number rather than a lower
        // bound: a bound written in terms of the implementation's own
        // constants cannot fail when the layout formula changes, which
        // is the one thing worth being told about.
        #expect(icon.size.width == 34)
    }

    @Test("The accessibility description carries both magnitudes and all three states")
    func accessibilityDescriptionCarriesMagnitudes() {
        let icon = image(session: .critical, sessionPercent: 94,
                         week: .nominal, weekPercent: 40,
                         platform: .warning)
        #expect(icon.accessibilityDescription
                == "Session 94 percent critical, week 40 percent normal, platform warning")
    }

    @Test("An unknown gauge is described as unknown, not as zero")
    func accessibilityDescriptionForUnknown() {
        let icon = image(session: .unknown, sessionPercent: nil,
                         week: .nominal, weekPercent: 40)
        #expect(icon.accessibilityDescription
                == "Session unknown, week 40 percent normal, platform normal")
    }

    @Test("The drawing handler produces a bitmap")
    func drawable() throws {
        let icon = image(session: .unknown, sessionPercent: nil,
                         week: .warning, weekPercent: 78,
                         platform: .critical)
        // The `#require`s are the assertion: `tiffRepresentation` is nil
        // if the drawing handler produced nothing.  Asserting a size
        // greater than zero would pass on an image that never drew,
        // since the size is set at construction rather than by drawing.
        let data = try #require(icon.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.size == icon.size)
    }
}
