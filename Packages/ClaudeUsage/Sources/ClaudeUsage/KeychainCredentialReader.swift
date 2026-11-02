import Foundation
import Security

/// Reads Claude Code's login from the macOS login keychain.
///
/// Why the read goes through `/usr/bin/security`
/// ---
///
/// Claude Code saves every refreshed token with `security
/// add-generic-password -U`, and that update resets the item's partition
/// list to `apple-tool:` alone.  The partition list is where "Always
/// Allow" records its grant (as `cdhash:<hash>` for a build with no Team
/// ID), so each token refresh silently revoked MonoCl's permission, and
/// MonoCl's next poll raised the keychain dialog again — several times a
/// day.  Observed on Claude Code 2.1.316 and macOS 26, by diffing the
/// item's ACL around a grant and an update.
///
/// `/usr/bin/security` is the one reader every such write leaves in
/// place: it is on the item's application list and in the `apple-tool:`
/// partition, which is how Claude Code itself reads the item without a
/// prompt.  Running it rather than calling `SecItemCopyMatching` makes the
/// requesting process `security`, not MonoCl, so no grant is needed.
/// That widens nothing: any process running as the user could already
/// read the item this way.  The assumption that would invalidate this is
/// Claude Code changing how it writes the item.
///
/// Read-only by construction
/// ---
///
/// The only command run is `find-generic-password`.  MonoCl must never
/// refresh the token, because refresh tokens rotate and doing so would
/// invalidate the copy Claude Code holds.  The token travels over a pipe;
/// it never appears in an argument and never reaches disk.
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CredentialError.unexpected(exitStatus: nil)
        }
        // Drained before waiting: a child blocked on a full pipe would
        // otherwise never exit.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // A signal number is not an exit status, and must not be read as
        // one by the table below.
        guard process.terminationReason == .exit else {
            throw CredentialError.unexpected(exitStatus: nil)
        }
        return try Self.credential(exitStatus: process.terminationStatus, output: data)
    }

    /// Turns the tool's exit status and output into a credential or the
    /// error `UsageSource` acts on.
    ///
    /// `security` exits with the low byte of the failing `OSStatus`.  That
    /// was observed for `errSecItemNotFound` (-25300, exit 44); the denial
    /// statuses are derived by the same rule rather than observed, because
    /// provoking them means raising the dialog this reader exists to avoid.
    static func credential(exitStatus: Int32, output: Data) throws -> StoredCredential {
        switch exitStatus {
        case 0:
            do {
                return try JSONDecoder().decode(KeychainRecord.self, from: payload(from: output))
                    .claudeAiOauth
            } catch {
                throw CredentialError.malformed
            }
        case lowByte(errSecItemNotFound):
            throw CredentialError.notFound
        case let status where deniedStatuses.contains(status):
            // Sticky: retrying on a timer would raise a dialog every cycle.
            throw CredentialError.accessDenied
        default:
            // Transient or unknown.  Deliberately NOT accessDenied: see
            // CredentialError.unexpected.
            throw CredentialError.unexpected(exitStatus: exitStatus)
        }
    }

    /// The user declined, or the keychain cannot prompt.  The same three
    /// statuses the Security-framework reader treated as denial, kept so
    /// that changing the transport does not change the policy.
    private static let deniedStatuses: Set<Int32> = [
        lowByte(errSecAuthFailed),
        lowByte(errSecUserCanceled),
        lowByte(errSecInteractionNotAllowed),
    ]

    private static func lowByte(_ status: OSStatus) -> Int32 { status & 0xFF }

    /// The item's bytes, from what `security -w` printed.
    ///
    /// The tool prints the item as text, or as bare hex once any byte is
    /// not printable ASCII (non-ASCII UTF-8 included).  The two cannot be
    /// confused: Claude Code's record is a JSON object, which opens with
    /// `{`, and that is not a hex digit.
    private static func payload(from output: Data) -> Data {
        var text = String(decoding: output, as: UTF8.self)
        while text.last?.isNewline == true { text.removeLast() }
        guard !text.isEmpty, text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit)
        else { return output }

        let digits = Array(text.utf8)
        let bytes = stride(from: 0, to: digits.count, by: 2).compactMap {
            UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16)
        }
        return Data(bytes)
    }
}
