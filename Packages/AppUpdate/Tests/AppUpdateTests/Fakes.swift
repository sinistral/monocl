import Foundation

@testable import AppUpdate

/// Counts calls so "the transport was used exactly once" can be
/// asserted positively rather than inferred from an absence.
final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    enum Outcome {
        case response(status: Int, body: String)
        case failure(any Error)
    }

    private(set) var callCount = 0
    private(set) var requested: URL?
    private let outcome: Outcome

    init(_ outcome: Outcome) { self.outcome = outcome }

    func get(_ url: URL) async throws -> (Data, Int) {
        callCount += 1
        requested = url
        switch outcome {
        case .response(let status, let body): return (Data(body.utf8), status)
        case .failure(let error): throw error
        }
    }
}
