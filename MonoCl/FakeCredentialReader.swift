import ClaudeUsage
import Foundation
import OSLog

#if DEBUG
    import Security

    /// The states `FakeCredentialReader` can be asked to present.  Raw
    /// values are the vocabulary of `MONOCL_FAKE_CREDENTIAL`.
    enum FakeCredential: String, CaseIterable {
        case valid
        case expired
        case notFound = "not-found"
        case denied
        case malformed
        case unexpected
    }

    /// Supplies a credential, or a specific `CredentialError`, without
    /// touching the keychain.
    ///
    /// Why this exists
    /// ---
    ///
    /// A keychain grant is bound to the requesting binary's signature.
    /// MonoCl is signed with a stable certificate, so the grant now
    /// survives a rebuild -- but it still has to be given once, and an
    /// unattended run has nobody to answer the dialog that asks for it.
    /// A launch that only needs the app to *hold* a credential can be
    /// handed one from here instead.
    ///
    /// It also reaches states the real keychain reaches only after manual
    /// work in Keychain Access — a denial above all, which is the
    /// behaviour MonoCl most needs to get right and the one nobody
    /// produces by accident.
    ///
    /// Read-only, like the reader it stands in for: it never writes.
    struct FakeCredentialReader: CredentialReading {
        let outcome: FakeCredential

        func read() throws -> StoredCredential {
            switch outcome {
            case .valid:
                // Recomputed per read, so a long-running session does not
                // drift into expiry while it is meant to be showing the
                // healthy case.
                return try credential(expiringAt: Date().addingTimeInterval(3600))
            case .expired:
                return try credential(expiringAt: Date().addingTimeInterval(-60))
            case .notFound:
                throw CredentialError.notFound
            case .denied:
                throw CredentialError.accessDenied
            case .malformed:
                throw CredentialError.malformed
            case .unexpected:
                throw CredentialError.unexpected(errSecNotAvailable)
            }
        }

        private func credential(expiringAt date: Date) throws -> StoredCredential {
            let json = """
                {"accessToken":"fake-token","expiresAt":\(Int(date.timeIntervalSince1970))}
                """
            return try JSONDecoder().decode(StoredCredential.self, from: Data(json.utf8))
        }
    }

    let fakeCredentialVariable = "MONOCL_FAKE_CREDENTIAL"
#endif

/// Picks the credential source the app will poll.
///
/// Release builds have no environment hook at all: the keychain is the
/// only source.
func resolvedCredentialReader(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> any CredentialReading {
    #if DEBUG
        guard let raw = environment[fakeCredentialVariable] else {
            return KeychainCredentialReader()
        }
        guard let fake = FakeCredential(rawValue: raw) else {
            // Deliberately fatal rather than falling back to the keychain:
            // a silent fallback would raise the very dialog the variable
            // was set to avoid, and would do so after the run had already
            // been left unattended.
            let accepted = FakeCredential.allCases.map(\.rawValue).joined(separator: ", ")
            fatalError("\(fakeCredentialVariable)=\(raw) is not one of: \(accepted)")
        }
        // Logged because the silent case is the confusing one: a variable
        // that failed to reach the process — `open -a` starts the app
        // from launchd, which does not carry the shell's environment — is
        // otherwise indistinguishable from one never set, and the keychain
        // dialog it produces looks like the fake having no effect.
        Logger(subsystem: "net.sinistral.monocl", category: "credentials")
            .notice("Using fake credential: \(fake.rawValue, privacy: .public)")
        return FakeCredentialReader(outcome: fake)
    #else
        _ = environment
        return KeychainCredentialReader()
    #endif
}
