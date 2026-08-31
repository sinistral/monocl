import Foundation
@testable import PlatformStatus

/// Counts calls so "the transport was used exactly once" can be
/// asserted positively rather than inferred from an absence.
final class FakeStatusFetcher: StatusFetching, @unchecked Sendable {
    enum Outcome {
        case response(status: Int, body: String)
        case failure(any Error)
    }

    private(set) var callCount = 0
    private let outcome: Outcome

    init(_ outcome: Outcome) { self.outcome = outcome }

    func get(_ url: URL) async throws -> (Data, Int) {
        callCount += 1
        switch outcome {
        case let .response(status, body): return (Data(body.utf8), status)
        case let .failure(error): throw error
        }
    }
}
