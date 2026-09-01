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
        return MenuBarIcon.image(for: spec)
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

    // MARK: - What the pixels show

    /// Where the glyph is centred horizontally, in points: the 2pt
    /// inset plus half the 20pt glyph box.  Recomputed here rather than
    /// read from the renderer, so that a sample cannot follow the
    /// drawing wherever it moves.
    private let glyphCentreX = 12.0

    private func bitmap(of icon: NSImage) throws -> NSBitmapImageRep {
        // The renderer resolves its colours against whatever appearance
        // is current when the image is drawn, so rasterising has to name
        // one for the samples below to be deterministic.
        var data: Data?
        appearance.performAsCurrentDrawingAppearance { data = icon.tiffRepresentation }
        let tiff = try #require(data)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        // One pixel per point, so that the sample coordinates below —
        // which are all in points — address the pixels they name.
        #expect(rep.pixelsWide == 34)
        return rep
    }

    /// Alpha at the point `radius` out from the glyph centre, on the
    /// bearing a gauge uses for `percent`.
    ///
    /// The bearing is spelled out here rather than borrowed from the
    /// renderer.  A sample sharing the renderer's own arithmetic would
    /// follow a mirrored or rotated gauge wherever it went, and pin
    /// nothing about which way round the sweep runs.
    private func alpha(_ rep: NSBitmapImageRep, atPercent percent: Double,
                       radius: Double) throws -> Double {
        let radians = (90 - percent / 100 * 360) * .pi / 180
        let x = glyphCentreX + cos(radians) * radius
        let y = Double(rep.pixelsHigh) / 2 + sin(radians) * radius
        // Row zero of the bitmap is the top edge; the drawing used a
        // bottom-left origin.
        let colour = try #require(rep.colorAt(x: Int(x.rounded(.down)),
                                              y: rep.pixelsHigh - 1 - Int(y.rounded(.down))))
        return Double(colour.alphaComponent)
    }

    /// The faintest pixel within two degrees of a bearing.
    ///
    /// A 1pt slot is a single pixel at 1x and lands between two of them
    /// at most bearings, so the pixel the bearing rounds to is not
    /// reliably the cut one.
    private func faintestAlpha(_ rep: NSBitmapImageRep, aroundPercent percent: Double,
                               radius: Double) throws -> Double {
        let halfWindow = 2.0 / 3.6
        return try stride(from: percent - halfWindow, through: percent + halfWindow, by: 0.05)
            .map { try alpha(rep, atPercent: $0, radius: radius) }
            .min() ?? 1
    }

    @Test("The session is the outer ring, and it sweeps clockwise")
    func sessionSweepsClockwiseOnTheRing() throws {
        let rep = try bitmap(of: image(session: .nominal, sessionPercent: 30,
                                       week: .unknown, weekPercent: nil))
        // 30% consumed runs from twelve o'clock to three, so three
        // o'clock is inside the sweep and nine o'clock is bare track.
        // Anticlockwise, or the ring drawn from the week, and the two
        // swap.
        #expect(try alpha(rep, atPercent: 25, radius: 8.5) > 0.5)
        let unswept = try alpha(rep, atPercent: 75, radius: 8.5)
        #expect(unswept > 0 && unswept < 0.3)
    }

    @Test("The week is the inner wedge, and it sweeps clockwise")
    func weekSweepsClockwiseOnThePie() throws {
        let rep = try bitmap(of: image(session: .unknown, sessionPercent: nil,
                                       week: .nominal, weekPercent: 30))
        #expect(try alpha(rep, atPercent: 25, radius: 3) > 0.5)
        let unswept = try alpha(rep, atPercent: 75, radius: 3)
        #expect(unswept > 0 && unswept < 0.3)
    }

    @Test("Two breach slots are cut out of a critical ring, at the mark bearings")
    func breachSlotsAreCutFromTheRing() throws {
        let rep = try bitmap(of: image(session: .critical, sessionPercent: 94,
                                       week: .unknown, weekPercent: nil))
        // A 94% ring is solid everywhere the slots are not, so the
        // control reads fully opaque and each slot reads as a distinct
        // loss of it.  A cut painted in a colour rather than composited
        // with `.clear` would leave the control's opacity behind, and a
        // slot at the wrong bearing — or a second one never drawn at
        // all — would leave its window at the control's value too.
        #expect(try alpha(rep, atPercent: 50, radius: 8.5) > 0.9)
        #expect(try faintestAlpha(rep, aroundPercent: 73, radius: 8.5) < 0.7)
        #expect(try faintestAlpha(rep, aroundPercent: 88, radius: 8.5) < 0.7)
    }

    // MARK: - Appearance

    /// Draws an already-built image into a fresh 1x bitmap under a
    /// named appearance, and reads one pixel of it.
    ///
    /// Drawing the *same* image twice is the whole point: it is what
    /// AppKit does to the status item's image when the menu bar's
    /// effective appearance changes, and the only way to observe
    /// whether the second draw picks the new appearance's colours up.
    private func redraw(_ icon: NSImage, under named: NSAppearance.Name,
                        atPercent percent: Double, radius: Double) throws -> NSColor {
        let width = Int(icon.size.width)
        let height = Int(icon.size.height)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        try #require(NSAppearance(named: named)).performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(origin: .zero, size: icon.size))
        }
        NSGraphicsContext.restoreGraphicsState()

        let radians = (90 - percent / 100 * 360) * .pi / 180
        let x = glyphCentreX + cos(radians) * radius
        let y = Double(height) / 2 + sin(radians) * radius
        return try #require(rep.colorAt(x: Int(x.rounded(.down)),
                                        y: height - 1 - Int(y.rounded(.down))))
            .usingColorSpace(.deviceRGB)!
    }

    @Test("Redrawing one image under a new appearance repaints it in that appearance's colours")
    func redrawFollowsTheAppearance() throws {
        // A critical session makes the image non-template, which is the
        // case that bites: a template image is tinted by the system and
        // follows the menu bar for free, whereas this one is painted in
        // colours the renderer resolved itself.  The sample is the
        // week's monochrome wedge, drawn in opaque `labelColor` — near
        // black under Aqua and near white under Dark Aqua.
        let icon = image(session: .critical, sessionPercent: 94,
                         week: .nominal, weekPercent: 30)
        #expect(icon.isTemplate == false)

        let light = try redraw(icon, under: .aqua, atPercent: 25, radius: 3)
        let dark = try redraw(icon, under: .darkAqua, atPercent: 25, radius: 3)
        #expect(light.redComponent < 0.2)
        #expect(dark.redComponent > 0.8)
    }
}
