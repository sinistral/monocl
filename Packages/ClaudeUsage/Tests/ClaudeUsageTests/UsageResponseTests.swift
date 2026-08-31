import Foundation
import Testing
@testable import ClaudeUsage

@Suite("Usage response decoding")
struct UsageResponseTests {
    private func fixture(_ name: String) throws -> UsageResponse {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(UsageResponse.self, from: Data(contentsOf: url))
    }

    @Test("Both windows decode, and unknown keys are ignored")
    func bothWindows() throws {
        let r = try fixture("usage-both-windows")
        let session = try #require(r.fiveHour)
        let week = try #require(r.sevenDay)
        // The endpoint reports 0-100 already; percent is utilization
        // unchanged.  A stray *100 here would read 4700%.
        #expect(session.percent == 47)
        #expect(week.percent == 62)

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31
        components.hour = 17
        components.minute = 50
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        // Fractional seconds are dropped by the comparison window, not
        // by the parser; a whole second of tolerance is enough to pin
        // the timestamp without asserting on microseconds.
        #expect(abs(session.resetsAt.timeIntervalSince(expected)) < 1)
    }

    @Test("A Z-suffixed timestamp without fractional seconds decodes")
    func sessionOnly() throws {
        let r = try fixture("usage-session-only")
        #expect(r.fiveHour?.percent == 3)
        #expect(r.sevenDay == nil)
        #expect(r.fiveHour?.resetsAt != nil)
    }

    @Test("A response with no windows decodes to two absences")
    func noWindows() throws {
        let r = try fixture("usage-no-windows")
        #expect(r.fiveHour == nil)
        #expect(r.sevenDay == nil)
    }

    @Test("An unparseable timestamp throws rather than yielding a wrong date")
    func badTimestamp() throws {
        let url = try #require(Bundle.module.url(
            forResource: "usage-bad-timestamp", withExtension: "json", subdirectory: "Fixtures"
        ))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(UsageResponse.self, from: Data(contentsOf: url))
        }
    }

    @Test("Malformed JSON throws")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(UsageResponse.self, from: Data("not json".utf8))
        }
    }
}
