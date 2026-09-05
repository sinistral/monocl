import Foundation
import Testing

@testable import AppUpdate

@Suite("Update source")
struct UpdateSourceTests {
    private let current = SemanticVersion(major: 0, minor: 1, patch: 0)

    private func source(_ outcome: FakeReleaseFetcher.Outcome)
        -> (UpdateSource, FakeReleaseFetcher)
    {
        let http = FakeReleaseFetcher(outcome)
        return (UpdateSource(http: http), http)
    }

    private func body(tag: String, page: String = "https://github.com/sinistral/monocl/releases")
        -> String
    {
        #"{"tag_name":"\#(tag)","html_url":"\#(page)"}"#
    }

    @Test("A newer release is offered, with the page that describes it")
    func newer() async {
        let page = "https://github.com/sinistral/monocl/releases/tag/v0.2.0"
        let (subject, http) = source(.response(status: 200, body: body(tag: "v0.2.0", page: page)))
        let outcome = await subject.check(against: current)
        #expect(
            outcome
                == .available(
                    AvailableUpdate(
                        version: SemanticVersion(major: 0, minor: 2, patch: 0),
                        page: URL(string: page)!
                    )))
        #expect(http.callCount == 1)
        #expect(http.requested == UpdateSource.endpoint)
    }

    @Test(
        "A release that is not newer settles the question with nothing to offer",
        arguments: ["v0.1.0", "v0.0.9"])
    func notNewer(tag: String) async {
        let (subject, _) = source(.response(status: 200, body: body(tag: tag)))
        #expect(await subject.check(against: current) == .nothingToOffer)
    }

    @Test("A repository with no release yet settles the question")
    func noReleases() async {
        let (subject, _) = source(.response(status: 404, body: #"{"message":"Not Found"}"#))
        #expect(await subject.check(against: current) == .nothingToOffer)
    }

    @Test("A tag MonoCl cannot read as a version settles the question")
    func unparsableTag() async {
        let (subject, _) = source(.response(status: 200, body: body(tag: "release-2026-09")))
        #expect(await subject.check(against: current) == .nothingToOffer)
    }

    @Test("An uppercase https scheme is still https")
    func uppercaseHTTPSPage() async {
        // `URL` does not normalise the scheme, so a literal comparison
        // would refuse this and hide the release permanently.
        let (subject, _) = source(
            .response(
                status: 200,
                body: body(tag: "v9.9.9", page: "HTTPS://github.com/sinistral/monocl/releases")))
        guard case .available(let update) = await subject.check(against: current) else {
            Issue.record("expected an available update")
            return
        }
        #expect(update.version == SemanticVersion(major: 9, minor: 9, patch: 9))
    }

    @Test("A release page that is not https is refused")
    func nonHTTPSPage() async {
        // `NSWorkspace` opens whatever scheme it is handed, so a page
        // that is not a web page must not reach the menu row.
        let (subject, _) = source(
            .response(status: 200, body: body(tag: "v9.9.9", page: "file:///Applications")))
        #expect(await subject.check(against: current) == .nothingToOffer)
    }

    @Test(
        "A check that did not complete says so, rather than claiming there is nothing",
        arguments: [403, 500, 502])
    func unusableStatusIsIndeterminate(status: Int) async {
        let (subject, _) = source(.response(status: status, body: #"{"message":"nope"}"#))
        #expect(await subject.check(against: current) == .indeterminate)
    }

    @Test("Being offline is indeterminate")
    func offline() async {
        let (subject, _) = source(.failure(URLError(.notConnectedToInternet)))
        #expect(await subject.check(against: current) == .indeterminate)
    }

    @Test("An undecodable body is indeterminate")
    func undecodable() async {
        let (subject, _) = source(.response(status: 200, body: "<html>"))
        #expect(await subject.check(against: current) == .indeterminate)
    }

    @Test("A captured GitHub release decodes past the fields MonoCl ignores")
    func decodesRealPayload() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "latest-release", withExtension: "json", subdirectory: "Fixtures"
            ))
        let captured = try String(contentsOf: url, encoding: .utf8)
        let (subject, _) = source(.response(status: 200, body: captured))
        guard case .available(let update) = await subject.check(against: current) else {
            Issue.record("expected an available update")
            return
        }
        #expect(update.version == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(
            update.page
                == URL(string: "https://github.com/sinistral/monocl/releases/tag/v0.2.0"))
    }
}
