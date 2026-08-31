import Foundation

public enum CredentialError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed
}

/// One method wide, so the orchestration in `UsageSource` can be tested
/// without a keychain.  This is not a pluggability seam: there is one
/// real implementation and no second one planned.
public protocol CredentialReading: Sendable {
    func read() throws -> StoredCredential
}
