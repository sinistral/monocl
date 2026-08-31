import Testing
@testable import Indicators

@Suite("Icon specification")
struct IconSpecTests {
    @Test("No breach means a template image")
    func templateWhenQuiet() {
        #expect(iconSpec(for: [.nominal, .nominal, .nominal],
                         differentiateWithoutColor: false).isTemplate == true)
        #expect(iconSpec(for: [.unknown, .nominal, .unknown],
                         differentiateWithoutColor: false).isTemplate == true)
    }

    @Test("Any breach means a non-template image")
    func nonTemplateWhenBreached() {
        #expect(iconSpec(for: [.warning, .nominal, .nominal],
                         differentiateWithoutColor: false).isTemplate == false)
        #expect(iconSpec(for: [.nominal, .nominal, .critical],
                         differentiateWithoutColor: false).isTemplate == false)
    }

    @Test("Tints follow state")
    func tints() {
        let spec = iconSpec(for: [.unknown, .warning, .critical],
                            differentiateWithoutColor: false)
        #expect(spec.dots.map(\.tint) == [.dimmed, .amber, .red])
    }

    @Test("Nominal is monochrome")
    func nominalTint() {
        let spec = iconSpec(for: [.nominal, .nominal, .nominal],
                            differentiateWithoutColor: false)
        #expect(spec.dots.allSatisfy { $0.tint == .monochrome })
    }

    @Test("Shapes collapse when color is available")
    func shapesWithColor() {
        let spec = iconSpec(for: [.unknown, .warning, .critical],
                            differentiateWithoutColor: false)
        #expect(spec.dots.map(\.fill) == [.ring(faint: true), .filled, .filled])
    }

    @Test("Critical gains a distinct shape when differentiating without color")
    func shapesWithoutColor() {
        let spec = iconSpec(for: [.nominal, .warning, .critical],
                            differentiateWithoutColor: true)
        #expect(spec.dots.map(\.fill) == [.ring(faint: false), .filled, .notched])
    }

    @Test("Dot order is preserved")
    func order() {
        let spec = iconSpec(for: [.critical, .nominal, .unknown],
                            differentiateWithoutColor: false)
        #expect(spec.dots.map(\.tint) == [.red, .monochrome, .dimmed])
    }
}
