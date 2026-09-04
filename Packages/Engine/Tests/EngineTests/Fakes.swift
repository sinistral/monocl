import ClaudeUsage
import Foundation
import Indicators
import PlatformStatus
import Synchronization
import Testing

@testable import Engine

/// Yields until `condition` holds, then settles the main actor.
///
/// `settle()` alone counts main-actor turns, which carries anything
/// that stays on the main actor.  A source's fetch does not:
/// `UsageSource.fetch` is nonisolated, so decoding a usage response —
/// two `DateFormatter`s and a `JSONDecoder` — runs off the main actor
/// and lands on another thread's schedule.  Measured here, that took
/// around 180 turns, so any fixed count is a race waiting to be lost.
/// Spinning on the outcome waits for exactly the work in question, and
/// records an issue rather than letting the next assertion read a
/// half-applied poll.
///
/// The trailing `settle()` is what makes the clock safe to move again:
/// the refresher registers its next sleep in the main-actor turns after
/// the outcome is applied.
@MainActor
func settle(until condition: () -> Bool, limit: Int = 10_000) async {
    for _ in 0..<limit {
        if condition() { return await settle() }
        await Task.yield()
    }
    Issue.record("the condition never held after \(limit) turns")
}

/// Waits for a usage poll's outcome to reach the store. Every outcome
/// these tests produce — a failure, or a trusted `.samples` — replaces
/// the store's initial detail; an untrusted sample would not, but none
/// of these scripts produces one. Named rather than inlined so a test
/// waits on the poll having landed, not on the value it is about to
/// assert.
@MainActor
func awaitUsageOutcome(_ engine: Engine) async {
    await settle(until: { engine.store.session.detail != IndicatorStore.noReading })
}

/// A call counter shared across actors.
///
/// The fakes below are reached from `UsageSource.fetch` and
/// `PlatformStatusSource.fetch`, both nonisolated, while the tests read
/// the counts from the main actor — including inside `settle(until:)`,
/// which spins on them.  Holding the count here rather than in a `var`
/// is what lets those fakes be plainly `Sendable`, so the compiler
/// checks the claim instead of being asked to take it on trust.
final class Counter: Sendable {
    private let value = Mutex(0)

    /// The count before this call.
    @discardableResult
    func increment() -> Int {
        value.withLock { count in
            defer { count += 1 }
            return count
        }
    }

    var count: Int { value.withLock { $0 } }
}

/// A transport that answers from a script and counts its calls.
///
/// The last entry repeats once the script runs out, so a test states
/// only the answers it cares about and the loop can keep polling.
final class ScriptedHTTP: HTTPFetching, Sendable {
    enum Answer {
        case response(status: Int, body: String, retryAfter: TimeInterval?)
        case offline
    }

    private let answers: [Answer]
    private let calls = Counter()

    var callCount: Int { calls.count }

    init(_ answers: [Answer]) {
        precondition(!answers.isEmpty, "a script needs at least one answer")
        self.answers = answers
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult {
        let answer = answers[min(calls.increment(), answers.count - 1)]
        switch answer {
        case .response(let status, let body, let retryAfter):
            return HTTPResult(status: status, body: Data(body.utf8), retryAfter: retryAfter)
        case .offline:
            throw URLError(.notConnectedToInternet)
        }
    }
}

final class ScriptedStatusFetcher: StatusFetching, Sendable {
    private let body: String
    private let calls = Counter()

    var callCount: Int { calls.count }

    init(body: String = statusBody) { self.body = body }

    func get(_ url: URL) async throws -> (Data, Int) {
        calls.increment()
        return (Data(body.utf8), 200)
    }
}

/// Supplies a credential, or the error the keychain would have raised.
///
/// Counts its reads because that is where a stopped usage poll shows:
/// `UsageSource` reads the credential before it reaches the transport,
/// so a poll that should not have happened at all still leaves the
/// transport's own count at zero.
final class StubCredentials: CredentialReading, Sendable {
    private let result: Result<StoredCredential, CredentialError>
    private let reads = Counter()

    var readCount: Int { reads.count }

    init(_ result: Result<StoredCredential, CredentialError>) { self.result = result }

    func read() throws -> StoredCredential {
        reads.increment()
        return try result.get()
    }
}

/// `StoredCredential` is deliberately decode-only, so a test builds one
/// the way the keychain does.
func storedCredential(expiresAt: Date) throws -> StoredCredential {
    let seconds = Int(expiresAt.timeIntervalSince1970)
    return try JSONDecoder().decode(
        StoredCredential.self,
        from: Data(#"{"accessToken":"t","expiresAt":\#(seconds)}"#.utf8)
    )
}

/// A credential that outlives every advance these tests make, so trust
/// is governed by the staleness budget rather than by expiry.
func validCredential() throws -> StubCredentials {
    StubCredentials(.success(try storedCredential(expiresAt: origin.addingTimeInterval(86_400))))
}

/// Session 47%, week 62%, both windows resetting well after `origin`.
let usageBody = """
    {
      "five_hour": { "utilization": 47.0, "resets_at": "2026-08-31T17:50:00.568709+00:00" },
      "seven_day": { "utilization": 62.0, "resets_at": "2026-09-04T15:00:00.568730+00:00" }
    }
    """

let statusBody = #"{ "status": { "indicator": "none", "description": "All Systems Operational" } }"#

/// Matches the app's own defaults (`Preferences`: 300s cadence, 900s
/// budget), so these tests exercise the cadence and budget MonoCl
/// actually ships with.
let defaultSettings = EngineSettings(
    thresholds: .default,
    refreshInterval: 300,
    staleAfter: 900
)
