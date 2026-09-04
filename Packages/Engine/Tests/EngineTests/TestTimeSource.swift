import Foundation

@testable import Engine

/// A fixed origin, so every expectation in the suite is an offset from
/// a known instant rather than from whenever the tests happened to run.
/// 2026-08-31T12:00:00Z, chosen to sit before the reset timestamps in
/// the canned usage response.
let origin = Date(timeIntervalSince1970: 1_788_177_600)

/// Yields enough times for an engine tick — several awaits deep, across
/// the refresher's loop, the source's fetch and the store's apply — to
/// run to completion.
///
/// A single yield does not reliably carry it that far.  The count is a
/// bound, not a timing assumption: too few yields makes an assertion
/// fail loudly rather than pass on stale state, which is the failure
/// mode worth having.
@MainActor
func settle(_ times: Int = 20) async {
    for _ in 0..<times { await Task.yield() }
}

/// A clock that only moves when a test moves it.
///
/// `advance` walks stepwise rather than jumping: it stops at each due
/// deadline in turn so a loop that re-sleeps immediately registers its
/// next wait before the clock moves on.  A single jump would collapse
/// five minutes of one-minute ticks into one.
///
/// Tolerance is ignored — virtual time has nothing to coalesce with.
/// That is the only behavioural difference from `SystemTimeSource`.
@MainActor
final class TestTimeSource: TimeSource {
    private struct Sleeper {
        let id: Int
        /// Which task is waiting, so `advance` can wait for THAT task to
        /// sleep again rather than for any sleep at all.  Several tasks
        /// share this clock — a refresher per source, plus the engine's
        /// one-shot expiry timer — and a registration by one of the
        /// others says nothing about the one just woken.
        let taskID: Int?
        let deadline: Date
        let resume: () -> Void
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    init(now: Date) { self.now = now }

    func sleep(for duration: TimeInterval, tolerance: TimeInterval) async {
        guard duration > 0 else { return }
        let id = nextID
        nextID += 1
        let deadline = now.addingTimeInterval(duration)
        // Identifies the waiting task by hash, since the
        // `UnsafeCurrentTask` itself must not escape its closure.
        let taskID = withUnsafeCurrentTask { $0?.hashValue }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Cancelled before registering: resume here, and leave
                // nothing for `wake` to find.  Registering first would
                // strand the continuation, since the cancellation
                // handler has already run by this point.
                guard !Task.isCancelled else { return continuation.resume() }
                sleepers.append(
                    Sleeper(id: id, taskID: taskID, deadline: deadline, resume: continuation.resume)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id: id) }
        }
    }

    /// Moves the clock forward, resuming every sleeper whose deadline it
    /// passes, in deadline order.
    func advance(by duration: TimeInterval) async {
        let target = now.addingTimeInterval(duration)
        while let next = sleepers.filter({ $0.deadline <= target }).min(by: {
            $0.deadline < $1.deadline
        }) {
            now = next.deadline
            wake(id: next.id)
            await awaitReregistration(by: next.taskID, after: next.id)
        }
        now = target
        await settle()
    }

    /// Yields until the task just woken has registered its next sleep,
    /// or until `limit` turns have passed.
    ///
    /// The clock must not move on before that deadline is fixed: a sleep
    /// registered against a later `now` lands later than the tick the
    /// test is counting, so a step taken too early can push a deadline
    /// clean out of the window under test.  What makes the wait safe is
    /// therefore the registration itself, not a number of turns — a
    /// woken refresher performs a whole fetch before sleeping again, and
    /// part of that fetch resumes off the main actor (see
    /// `settle(until:)` in `Fakes`), so how many main-actor turns it
    /// occupies is a property of the machine rather than of the code.
    ///
    /// The registration must be attributed to the woken task, which is
    /// why a sleeper carries a `taskID`: several tasks share this clock,
    /// and the engine re-arms its expiry timer — a new task, and so a
    /// new sleep — every time a poll leaves a reading whose trust will
    /// lapse later.  An earlier version of this wait accepted any new
    /// sleep and failed one run in thirty, the clock having moved on
    /// while a platform poll's fetch was still in flight.  `id` orders
    /// registrations, so requiring one above the woken sleeper's own
    /// rules out the sleep being replaced.
    ///
    /// Reaching the limit is not a failure, and deliberately records no
    /// issue.  A woken sleeper need not sleep again — a `Refresher` that
    /// was stopped or cancelled, a loop that has exited, a one-shot
    /// timer — and the sleeper set cannot tell that apart from work
    /// still in flight.  The limit is what bounds the wait in that
    /// legitimate case, and sits far above the ~180 turns a fetch was
    /// measured to need, so a step that will register does so long
    /// before reaching it.
    private func awaitReregistration(by taskID: Int?, after id: Int, limit: Int = 1_000) async {
        for _ in 0..<limit {
            if sleepers.contains(where: { $0.taskID == taskID && $0.id > id }) { return }
            await Task.yield()
        }
    }

    private func wake(id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).resume()
    }
}
