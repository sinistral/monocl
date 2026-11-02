import Foundation

public enum CredentialError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed

    /// Any outcome that is not a recognised absence or denial.
    ///
    /// `exitStatus` is the `security` tool's exit status, or nil when the
    /// tool could not be launched or was ended by a signal.
    ///
    /// Kept distinct from `accessDenied` because denial is sticky — it
    /// stops polling until the user asks for a retry — and a transient
    /// failure such as a locked keychain during login would otherwise
    /// halt the lights permanently for a condition that has since
    /// cleared, while reporting "access denied", which would be untrue.
    case unexpected(exitStatus: Int32?)
}

/// One method wide, so the orchestration in `UsageSource` can be tested
/// without a keychain.  This is not a pluggability seam: there is one
/// real implementation and no second one planned.
public protocol CredentialReading: Sendable {
    func read() throws -> StoredCredential
}
