import Foundation
import Indicators
import Testing

@testable import PlatformStatus

@Suite("Platform status source")
struct PlatformStatusSourceTests {
    private let now = Date(timeIntervalSince1970: 1_788_198_600)

    private func source(_ outcome: FakeStatusFetcher.Outcome)
        -> (PlatformStatusSource, FakeStatusFetcher)
    {
        let http = FakeStatusFetcher(outcome)
        return (PlatformStatusSource(http: http), http)
    }

    @Test("A 200 with a known indicator yields a sample")
    func success() async {
        let (subject, http) = source(
            .response(
                status: 200,
                body: #"{"status":{"indicator":"none","description":"All Systems Operational"}}"#
            ))
        let outcome = await subject.fetch(now: now)
        #expect(
            outcome
                == .sample(
                    StatusSample(state: .nominal, description: "All Systems Operational"),
                    asOf: now
                ))
        #expect(http.callCount == 1)
    }

    @Test("A transport failure is offline")
    func offline() async {
        let (subject, _) = source(.failure(URLError(.notConnectedToInternet)))
        #expect(await subject.fetch(now: now) == .failure(.offline))
    }

    @Test("An undecodable body is an unexpected response")
    func undecodable() async {
        let (subject, _) = source(.response(status: 200, body: "<html>"))
        #expect(await subject.fetch(now: now) == .failure(.unexpectedResponse))
    }

    @Test("A non-200 status is an unexpected response")
    func nonOK() async {
        let (subject, _) = source(
            .response(status: 503, body: #"{"status":{"indicator":"none","description":"x"}}"#))
        #expect(await subject.fetch(now: now) == .failure(.unexpectedResponse))
    }

    @Test("The page offered to the reader is the one the endpoint speaks for")
    func pageMatchesEndpoint() {
        // Sending a reader somewhere other than the host MonoCl polled
        // would let the two disagree, which is the one thing a "see for
        // yourself" link must not do.
        #expect(PlatformStatusSource.page == URL(string: "https://status.claude.com/"))
        #expect(PlatformStatusSource.page.host() == PlatformStatusSource.endpoint.host())
    }
}
