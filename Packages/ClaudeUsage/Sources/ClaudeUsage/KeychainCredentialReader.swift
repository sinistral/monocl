import Foundation
import Security

/// Reads Claude Code's login from the macOS login keychain.
///
/// Read-only by construction: this file contains no `SecItemAdd`,
/// `SecItemUpdate`, or `SecItemDelete`.  MonoCl must never refresh the
/// token, because refresh tokens rotate and doing so would invalidate
/// the copy Claude Code holds.
public struct KeychainCredentialReader: CredentialReading {
    private let service: String
    private let account: String

    public init(
        service: String = "Claude Code-credentials",
        account: String = NSUserName()
    ) {
        self.service = service
        self.account = account
    }

    public func read() throws -> StoredCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CredentialError.malformed }
            do {
                return try JSONDecoder().decode(KeychainRecord.self, from: data).claudeAiOauth
            } catch {
                throw CredentialError.malformed
            }
        case errSecItemNotFound:
            throw CredentialError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw CredentialError.accessDenied
        default:
            throw CredentialError.accessDenied
        }
    }
}
