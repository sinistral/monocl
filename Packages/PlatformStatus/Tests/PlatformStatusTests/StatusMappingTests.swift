import Foundation
import Indicators
import Testing

@testable import PlatformStatus

@Suite("Platform status mapping")
struct StatusMappingTests {
    private func fixture(_ name: String) throws -> SummaryResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures"
            ))
        return try JSONDecoder().decode(SummaryResponse.self, from: Data(contentsOf: url))
    }

    @Test(
        "Indicators map to states",
        arguments: [
            ("status-none", IndicatorState.nominal, "All Systems Operational"),
            ("status-minor", IndicatorState.warning, "Elevated error rates on the API"),
            ("status-major", IndicatorState.critical, "Claude is unavailable"),
        ])
    func mapping(name: String, expected: IndicatorState, description: String) throws {
        let r = try fixture(name)
        #expect(r.indicatorState == expected)
        #expect(r.status.description == description)
    }

    @Test("critical maps to critical")
    func criticalIndicator() throws {
        let data = Data(#"{"status":{"indicator":"critical","description":"Total outage"}}"#.utf8)
        let r = try JSONDecoder().decode(SummaryResponse.self, from: data)
        #expect(r.indicatorState == .critical)
    }

    @Test("An unrecognized indicator is unknown, not a crash")
    func unknownIndicator() throws {
        #expect(try fixture("status-unknown-indicator").indicatorState == .unknown)
    }

    @Test("Malformed JSON throws")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SummaryResponse.self, from: Data("nope".utf8))
        }
    }
}
