import Foundation
import Security

public enum CredentialError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed

    /// Any keychain status that is not a recognised absence or denial.
    ///
    /// Kept distinct from `accessDenied` because denial is sticky — it
    /// stops polling until the user asks for a retry — and a transient
    /// failure such as a locked keychain during login would otherwise
    /// halt the lights permanently for a condition that has since
    /// cleared, while reporting "access denied", which would be untrue.
    case unexpected(OSStatus)
}

/// One method wide, so the orchestration in `UsageSource` can be tested
/// without a keychain.  This is not a pluggability seam: there is one
/// real implementation and no second one planned.
public protocol CredentialReading: Sendable {
    func read() throws -> StoredCredential
}
