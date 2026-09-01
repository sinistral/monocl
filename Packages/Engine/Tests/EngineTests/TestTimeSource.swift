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

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Cancelled before registering: resume here, and leave
                // nothing for `wake` to find.  Registering first would
                // strand the continuation, since the cancellation
                // handler has already run by this point.
                guard !Task.isCancelled else { return continuation.resume() }
                sleepers.append(Sleeper(id: id, deadline: deadline, resume: continuation.resume))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id: id) }
        }
    }

    /// Moves the clock forward, resuming every sleeper whose deadline it
    /// passes, in deadline order.
    func advance(by duration: TimeInterval) async {
        let target = now.addingTimeInterval(duration)
        while let next = sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) {
            now = next.deadline
            wake(id: next.id)
            // Lets the woken task run far enough to register its next
            // sleep before the clock moves past that sleep's deadline.
            // A woken refresher performs a whole fetch before sleeping
            // again, so one yield is not enough.
            await settle()
        }
        now = target
        await settle()
    }

    private func wake(id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).resume()
    }
}
