import Foundation
import Testing
@testable import Indicators

@Suite("Backoff")
struct BackoffTests {
    @Test("No failures uses the base interval")
    func noFailures() {
        #expect(backoffInterval(base: 60, consecutiveFailures: 0) == 60)
    }

    @Test("Doubling", arguments: [
        (1, 60.0), (2, 120.0), (3, 240.0), (4, 480.0),
    ])
    func doubling(failures: Int, expected: Double) {
        #expect(backoffInterval(base: 60, consecutiveFailures: failures) == expected)
    }

    @Test("The cap holds")
    func capped() {
        #expect(backoffInterval(base: 60, consecutiveFailures: 20) == 900)
        #expect(backoffInterval(base: 60, consecutiveFailures: 5, cap: 300) == 300)
    }

    @Test("A larger Retry-After wins")
    func retryAfterWins() {
        #expect(backoffInterval(base: 60, consecutiveFailures: 1, retryAfter: 200) == 200)
    }

    @Test("A smaller Retry-After does not shorten the backoff")
    func retryAfterIgnoredWhenSmaller() {
        #expect(backoffInterval(base: 60, consecutiveFailures: 3, retryAfter: 10) == 240)
    }
}
