import Foundation
@testable import ClaudeUsage

final class FakeCredentialReader: CredentialReading, @unchecked Sendable {
    let result: Result<StoredCredential, CredentialError>
    init(_ result: Result<StoredCredential, CredentialError>) { self.result = result }
    func read() throws -> StoredCredential { try result.get() }
}

final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    enum Outcome {
        case response(status: Int, body: String, retryAfter: TimeInterval?)
        case failure(any Error)
    }

    private(set) var callCount = 0
    private let outcome: Outcome
    init(_ outcome: Outcome) { self.outcome = outcome }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult {
        callCount += 1
        switch outcome {
        case let .response(status, body, retryAfter):
            return HTTPResult(status: status, body: Data(body.utf8), retryAfter: retryAfter)
        case let .failure(error):
            throw error
        }
    }
}

/// Builds a credential without going through JSON, for tests that care
/// about expiry rather than decoding.
func credential(expiresAt: Date, token: String = "t") throws -> StoredCredential {
    let ms = Int(expiresAt.timeIntervalSince1970)
    return try JSONDecoder().decode(
        KeychainRecord.self,
        from: Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(ms)}}"#.utf8)
    ).claudeAiOauth
}
