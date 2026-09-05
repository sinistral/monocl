// MonoClTests/UpdateCheckerTests.swift
import AppUpdate
import Foundation
import Testing

@testable import MonoCl

@MainActor
@Suite("Update checker")
struct UpdateCheckerTests {
    /// Counts notifications so "the menu was told once" can be asserted
    /// positively rather than inferred from an absence.
    private final class Changes {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// Hands back a scripted sequence of outcomes, one per check, so a
    /// test can describe what a run of checks establishes over time.
    private final class Answers: @unchecked Sendable {
        private var remaining: [UpdateCheckOutcome]
        init(_ answers: [UpdateCheckOutcome]) { remaining = answers }
        func next() -> UpdateCheckOutcome {
            guard !remaining.isEmpty else { return .indeterminate }
            return remaining.removeFirst()
        }
    }

    private let update = AvailableUpdate(
        version: SemanticVersion(major: 0, minor: 2, patch: 0),
        page: URL(string: "https://github.com/sinistral/monocl/releases/tag/v0.2.0")!
    )

    private func checker(_ changes: Changes, answering answers: Answers) -> UpdateChecker {
        UpdateChecker(check: { answers.next() }, onChange: { changes.record() })
    }

    @Test("A check that finds a release publishes it and says so")
    func publishesWhatItFound() async {
        let changes = Changes()
        let subject = checker(changes, answering: Answers([.available(update)]))
        #expect(await subject.checkNow())
        #expect(subject.available == update)
        #expect(changes.count == 1)
    }

    @Test("An unchanged answer is not announced a second time")
    func announcesOnlyChanges() async {
        let changes = Changes()
        let subject = checker(
            changes, answering: Answers([.available(update), .available(update)]))
        await subject.checkNow()
        await subject.checkNow()
        #expect(subject.available == update)
        #expect(changes.count == 1)
    }

    @Test("A settled check that finds nothing publishes nothing and stays quiet")
    func findsNothing() async {
        let changes = Changes()
        let subject = checker(changes, answering: Answers([.nothingToOffer]))
        #expect(await subject.checkNow())
        #expect(subject.available == nil)
        #expect(changes.count == 0)
    }

    @Test("An update withdrawn upstream is retracted, and the retraction announced")
    func retractsAWithdrawnUpdate() async {
        let changes = Changes()
        // A release deleted between checks: the row must go away, not
        // linger pointing at a page that no longer exists.
        let subject = checker(
            changes, answering: Answers([.available(update), .nothingToOffer]))
        await subject.checkNow()
        await subject.checkNow()
        #expect(subject.available == nil)
        #expect(changes.count == 2)
    }

    @Test("A check that did not complete leaves a known update standing")
    func keepsWhatItKnewWhenTheCheckFails() async {
        let changes = Changes()
        // The case this distinction exists for: one check without a
        // network must not retract a release that is still published.
        let subject = checker(
            changes, answering: Answers([.available(update), .indeterminate]))
        await subject.checkNow()
        #expect(await subject.checkNow() == false)
        #expect(subject.available == update)
        #expect(changes.count == 1)
    }

    @Test("A check that did not complete announces nothing at all")
    func staysQuietWhenTheCheckFails() async {
        let changes = Changes()
        let subject = checker(changes, answering: Answers([.indeterminate]))
        #expect(await subject.checkNow() == false)
        #expect(subject.available == nil)
        #expect(changes.count == 0)
    }

    /// Polls `condition` until it holds or the budget runs out.  The
    /// intervals under test are milliseconds against seconds, so a
    /// generous budget still fails decisively when the wrong one is
    /// used.
    private func holds(
        within budget: Duration = .milliseconds(2000),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("An unsettled check is retried on the short interval, not the long one")
    func retriesSoonAfterAnUnsettledCheck() async {
        let changes = Changes()
        // A login item starting before the network is up: the first
        // check establishes nothing, and the update must not wait a
        // whole interval to be found.
        let answers = Answers([.indeterminate, .available(update)])
        let subject = UpdateChecker(
            interval: .seconds(60),
            retryInterval: .milliseconds(5),
            check: { answers.next() },
            onChange: { changes.record() }
        )
        defer { subject.stop() }
        subject.start()
        #expect(await holds { subject.available == self.update })
        #expect(changes.count == 1)
    }

    @Test("A settled check waits the long interval before asking again")
    func waitsAfterASettledCheck() async {
        let changes = Changes()
        // The mirror of the case above: having been told there is
        // nothing, MonoCl must not then poll every few milliseconds.
        let answers = Answers([.nothingToOffer, .available(update)])
        let subject = UpdateChecker(
            interval: .seconds(60),
            retryInterval: .milliseconds(5),
            check: { answers.next() },
            onChange: { changes.record() }
        )
        defer { subject.stop() }
        subject.start()
        // Long enough that the short interval would have fired many
        // times over, and far short of the long one.
        _ = await holds(within: .milliseconds(300)) { false }
        #expect(subject.available == nil)
        #expect(changes.count == 0)
    }

    @Test("The check is switched off by the variable the test scheme sets")
    func honoursTheSkipVariable() {
        #expect(UpdateChecker.isEnabled(environment: [:]))
        #expect(UpdateChecker.isEnabled(environment: ["UNRELATED": "1"]) == true)
        #expect(UpdateChecker.isEnabled(environment: [skipUpdateCheckVariable: "1"]) == false)
    }
}
