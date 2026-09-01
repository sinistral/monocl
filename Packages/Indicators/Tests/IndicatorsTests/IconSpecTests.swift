import Foundation
import Testing
@testable import Indicators

@Suite("Icon specification")
struct IconSpecTests {
    private func reading(_ state: IndicatorState, percent: Double? = nil) -> Reading {
        Reading(state: state, detail: "", percent: percent, asOf: Date(timeIntervalSince1970: 0))
    }

    private func spec(
        session: IndicatorState = .nominal, sessionPercent: Double? = 10,
        week: IndicatorState = .nominal, weekPercent: Double? = 20,
        platform: IndicatorState = .nominal
    ) -> IconSpec {
        iconSpec(
            session: reading(session, percent: sessionPercent),
            week: reading(week, percent: weekPercent),
            platform: reading(platform)
        )
    }

    @Test("No breach means a template image")
    func templateWhenQuiet() {
        #expect(spec().isTemplate == true)
        #expect(spec(session: .unknown, sessionPercent: nil, platform: .unknown).isTemplate == true)
    }

    @Test("Any breach means a non-template image")
    func nonTemplateWhenBreached() {
        #expect(spec(session: .warning, sessionPercent: 78).isTemplate == false)
        #expect(spec(platform: .critical).isTemplate == false)
    }

    @Test("A gauge's fraction is its percentage over one hundred")
    func fractionFollowsPercent() {
        let s = spec(sessionPercent: 62, weekPercent: 5)
        #expect(s.session.fraction == 0.62)
        #expect(s.week.fraction == 0.05)
    }

    @Test("A reading with no percentage has no fraction")
    func unknownHasNoFraction() {
        // Nil, not zero: a track with no sweep is a different picture
        // from a sweep of length zero, and only one of them is honest
        // about not knowing.
        let s = spec(session: .unknown, sessionPercent: nil)
        #expect(s.session.fraction == nil)
    }

    @Test("A percentage beyond one hundred clamps to a full sweep")
    func fractionClamps() {
        // 104% would otherwise sweep 374 degrees and wrap past twelve,
        // drawing a nearly empty gauge for a completely full window.
        #expect(spec(session: .critical, sessionPercent: 104).session.fraction == 1)
    }

    @Test("Breach marks count severity on the gauges")
    func gaugeBreachMarks() {
        #expect(spec(sessionPercent: 10).session.breachMarks == 0)
        #expect(spec(session: .unknown, sessionPercent: nil).session.breachMarks == 0)
        #expect(spec(session: .warning, sessionPercent: 78).session.breachMarks == 1)
        #expect(spec(session: .critical, sessionPercent: 94).session.breachMarks == 2)
    }

    @Test("Breach marks count severity on the platform dot too")
    func platformBreachMarks() {
        #expect(spec(platform: .nominal).platform.breachMarks == 0)
        #expect(spec(platform: .warning).platform.breachMarks == 1)
        #expect(spec(platform: .critical).platform.breachMarks == 2)
    }

    @Test("Tints follow state")
    func tints() {
        let s = spec(session: .unknown, sessionPercent: nil,
                     week: .warning, weekPercent: 78, platform: .critical)
        #expect(s.session.tint == .dimmed)
        #expect(s.week.tint == .amber)
        #expect(s.platform.tint == .red)
        #expect(spec().session.tint == .monochrome)
    }

    @Test("The platform dot is a ring when quiet and a disc when not")
    func platformFill() {
        #expect(spec(platform: .unknown).platform.fill == .ring(faint: true))
        #expect(spec(platform: .nominal).platform.fill == .ring(faint: false))
        #expect(spec(platform: .warning).platform.fill == .filled)
        #expect(spec(platform: .critical).platform.fill == .filled)
    }
}
