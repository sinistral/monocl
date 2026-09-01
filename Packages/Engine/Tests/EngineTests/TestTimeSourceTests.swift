import Foundation
import Testing
@testable import Engine

@MainActor
@Suite("Virtual clock")
struct TestTimeSourceTests {
    @Test("Sleepers wake in deadline order, each seeing its own deadline")
    func wakesInOrder() async {
        let time = TestTimeSource(now: origin)
        var observed: [Date] = []

        let first = Task { await time.sleep(for: 120, tolerance: 0); observed.append(time.now) }
        let second = Task { await time.sleep(for: 60, tolerance: 0); observed.append(time.now) }
        await Task.yield()

        await time.advance(by: 130)
        _ = await first.value
        _ = await second.value

        #expect(observed == [
            origin.addingTimeInterval(60),
            origin.addingTimeInterval(120),
        ])
        #expect(time.now == origin.addingTimeInterval(130))
    }

    @Test("A sleeper whose deadline is past the target stays asleep")
    func staysAsleep() async {
        let time = TestTimeSource(now: origin)
        var woke = false

        let sleeper = Task { await time.sleep(for: 600, tolerance: 0); woke = true }
        await Task.yield()

        await time.advance(by: 599)
        #expect(woke == false)
        #expect(time.now == origin.addingTimeInterval(599))

        sleeper.cancel()
        _ = await sleeper.value
    }

    @Test("Cancelling a sleep resumes it without advancing the clock")
    func cancellationResumes() async {
        let time = TestTimeSource(now: origin)
        let sleeper = Task { await time.sleep(for: 3600, tolerance: 0); return time.now }
        await Task.yield()

        sleeper.cancel()
        let observed = await sleeper.value

        #expect(observed == origin)
        #expect(time.now == origin)
    }
}
