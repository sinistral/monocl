#if DEBUG
    import ClaudeUsage
    import Foundation
    import Security
    import Testing
    @testable import MonoCl

    @Suite("Fake credential reader")
    struct FakeCredentialReaderTests {
        private func read(_ outcome: FakeCredential) throws -> StoredCredential {
            try FakeCredentialReader(outcome: outcome).read()
        }

        @Test("The documented vocabulary is the accepted vocabulary")
        func vocabulary() {
            #expect(
                FakeCredential.allCases.map(\.rawValue) == [
                    "valid", "expired", "not-found", "denied", "malformed", "unexpected",
                ])
        }

        @Test("valid supplies a credential that has not expired")
        func validCredential() throws {
            let credential = try read(.valid)
            #expect(credential.accessToken == "fake-token")
            #expect(credential.expiresAt > Date())
        }

        @Test("expired supplies a credential whose expiry has passed")
        func expiredCredential() throws {
            let credential = try read(.expired)
            #expect(credential.accessToken == "fake-token")
            #expect(credential.expiresAt < Date())
        }

        @Test("not-found reports absence")
        func notFound() {
            #expect(throws: CredentialError.notFound) { try read(.notFound) }
        }

        @Test("denied reports the sticky denial")
        func denied() {
            #expect(throws: CredentialError.accessDenied) { try read(.denied) }
        }

        @Test("malformed reports an undecodable record")
        func malformed() {
            #expect(throws: CredentialError.malformed) { try read(.malformed) }
        }

        @Test("unexpected reports a keychain status, not a denial")
        func unexpected() {
            #expect(throws: CredentialError.unexpected(errSecNotAvailable)) {
                try read(.unexpected)
            }
        }

        @Test("An unset variable selects the keychain")
        func unsetSelectsKeychain() {
            #expect(resolvedCredentialReader(environment: [:]) is KeychainCredentialReader)
        }

        @Test("The variable selects the named fake")
        func variableSelectsFake() {
            let reader = resolvedCredentialReader(
                environment: [fakeCredentialVariable: "denied"]
            )
            #expect((reader as? FakeCredentialReader)?.outcome == .denied)
        }
    }
#endif
