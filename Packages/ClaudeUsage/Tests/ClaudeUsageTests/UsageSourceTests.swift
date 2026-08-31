import Foundation
import Testing
@testable import ClaudeUsage

@Suite("Usage source orchestration")
struct UsageSourceTests {
    private let now = Date(timeIntervalSince1970: 1_767_000_000)
    private let bothWindows = """
    {"five_hour":{"utilization":47.0,"resets_at":"2026-08-31T17:50:00.568709+00:00"},
     "seven_day":{"utilization":62.0,"resets_at":"2026-09-04T15:00:00.568730+00:00"}}
    """

    private func source(
        credential result: Result<StoredCredential, CredentialError>,
        http: FakeHTTP
    ) -> UsageSource {
        UsageSource(credentials: FakeCredentialReader(result), http: http)
    }

    @Test("An expired token means no request is made at all")
    func expiredTokenIssuesNoRequest() async throws {
        let http = FakeHTTP(.response(status: 200, body: bothWindows, retryAfter: nil))
        let s = source(
            credential: .success(try credential(expiresAt: now.addingTimeInterval(-1))),
            http: http
        )
        let outcome = await s.fetch(now: now)
        #expect(outcome == .failure(.tokenExpired))
        #expect(http.callCount == 0)
    }

    @Test("A live token and a 200 yields both samples")
    func success() async throws {
        let expiry = now.addingTimeInterval(3600)
        let http = FakeHTTP(.response(status: 200, body: bothWindows, retryAfter: nil))
        let s = source(credential: .success(try credential(expiresAt: expiry)), http: http)

        let outcome = await s.fetch(now: now)
        guard case let .samples(session, week, asOf, tokenExpiresAt) = outcome else {
            Issue.record("expected samples, got \(outcome)")
            return
        }
        #expect(session?.percent == 47)
        #expect(week?.percent == 62)
        // A specific expected instant, with tolerance only for binary
        // floating-point representation of the microseconds — not a
        // "greater than zero" check, which would pass on any date at all.
        #expect(abs((session?.resetsAt.timeIntervalSince1970 ?? 0) - 1_788_198_600.568709) < 0.001)
        #expect(asOf == now)
        #expect(tokenExpiresAt == expiry)
        #expect(http.callCount == 1)
    }

    @Test("HTTP statuses map to failures", arguments: [
        (401, UsageFailure.authorizationRejected),
        (403, UsageFailure.accessRefused),
        (500, UsageFailure.unexpectedResponse),
    ])
    func statusMapping(status: Int, expected: UsageFailure) async throws {
        let http = FakeHTTP(.response(status: status, body: "{}", retryAfter: nil))
        let s = source(
            credential: .success(try credential(expiresAt: now.addingTimeInterval(3600))),
            http: http
        )
        #expect(await s.fetch(now: now) == .failure(expected))
    }

    @Test("429 carries Retry-After")
    func rateLimited() async throws {
        let http = FakeHTTP(.response(status: 429, body: "{}", retryAfter: 120))
        let s = source(
            credential: .success(try credential(expiresAt: now.addingTimeInterval(3600))),
            http: http
        )
        #expect(await s.fetch(now: now) == .failure(.rateLimited(retryAfter: 120)))
    }

    @Test("A transport error is offline")
    func offline() async throws {
        let http = FakeHTTP(.failure(URLError(.notConnectedToInternet)))
        let s = source(
            credential: .success(try credential(expiresAt: now.addingTimeInterval(3600))),
            http: http
        )
        #expect(await s.fetch(now: now) == .failure(.offline))
    }

    @Test("An undecodable 200 body is an unexpected response")
    func undecodable() async throws {
        let http = FakeHTTP(.response(status: 200, body: "<html>", retryAfter: nil))
        let s = source(
            credential: .success(try credential(expiresAt: now.addingTimeInterval(3600))),
            http: http
        )
        #expect(await s.fetch(now: now) == .failure(.unexpectedResponse))
    }

    @Test("Credential errors map through", arguments: [
        (CredentialError.notFound, UsageFailure.credentialsNotFound),
        (CredentialError.accessDenied, UsageFailure.keychainDenied),
        (CredentialError.unexpected(-25291), UsageFailure.keychainUnavailable),
        (CredentialError.malformed, UsageFailure.unexpectedResponse),
    ])
    func credentialErrors(error: CredentialError, expected: UsageFailure) async {
        let http = FakeHTTP(.response(status: 200, body: "{}", retryAfter: nil))
        let s = source(credential: .failure(error), http: http)
        #expect(await s.fetch(now: now) == .failure(expected))
        #expect(http.callCount == 0)
    }

    @Test("Only absence and denial stop the poller")
    func stopsPolling() {
        #expect(UsageFailure.credentialsNotFound.stopsPolling == true)
        #expect(UsageFailure.keychainDenied.stopsPolling == true)
        // A transient keychain failure may clear on its own, so it must
        // keep polling rather than waiting for a manual retry.
        #expect(UsageFailure.keychainUnavailable.stopsPolling == false)
        #expect(UsageFailure.tokenExpired.stopsPolling == false)
        #expect(UsageFailure.offline.stopsPolling == false)
        #expect(UsageFailure.accessRefused.stopsPolling == false)
    }
}
