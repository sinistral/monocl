import Foundation
import Security
import Testing

@testable import ClaudeUsage

/// Runs `/usr/bin/security` with output discarded, as the fixture writer.
///
/// The fixtures are written by `security` because that is how Claude Code
/// writes the real item, and the item's access control is whatever its
/// writer leaves behind.  A fixture created through the Security framework
/// would carry a different ACL and test a situation that never occurs.
@discardableResult
private func runSecurity(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func hex(_ string: String) -> String {
    Data(string.utf8).map { String(format: "%02x", $0) }.joined()
}

/// Exercises the reader against the real login keychain.
///
/// Each test gets its own suite instance, so its own uniquely named item,
/// and `deinit` deletes that item whether or not the test passed.
///
/// Keychain UI is switched off for this process for the duration of each
/// test.  That is what makes "without a dialog" checkable by machine for
/// a read made in-process, the regression this suite guards against: such
/// a read that would have prompted fails at once with
/// `errSecInteractionNotAllowed` instead of waiting for a human, who
/// might click Allow and pass a broken reader.  The switch is per
/// process, so it does not reach the `security` child the reader runs.
/// It is process-wide state, hence `.serialized` and the restore in
/// `deinit`.
@Suite("Keychain credential reader, against the login keychain", .serialized)
final class KeychainCredentialReaderTests {
    private let service = "net.sinistral.monocl.tests.\(UUID().uuidString)"
    private let account = "monocl-tests"

    init() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    deinit {
        _ = try? runSecurity(["delete-generic-password", "-s", service, "-a", account])
        SecKeychainSetUserInteractionAllowed(true)
    }

    private var reader: KeychainCredentialReader {
        KeychainCredentialReader(service: service, account: account)
    }

    /// Writes the item exactly as Claude Code 2.1.316 does when it saves a
    /// refreshed token: `add-generic-password -U` with a hex payload.
    private func writeAsClaudeCode(_ payload: String) throws {
        let status = try runSecurity([
            "add-generic-password", "-U", "-a", account, "-s", service, "-X", hex(payload),
        ])
        try #require(status == 0)
    }

    // The test process holds no grant on the item, so a reader that asked
    // the Security framework directly would need the keychain dialog, and
    // with UI switched off it fails instead.  The rewrite matters too:
    // Claude Code's `-U` update resets the item's partition list, which is
    // what erased "Always Allow" grants several times a day.
    @Test("Reads an item Claude Code wrote and then rewrote, without a dialog")
    func readsRewrittenItemSilently() throws {
        try writeAsClaudeCode(#"{"claudeAiOauth":{"accessToken":"first","expiresAt":1767225600}}"#)
        try writeAsClaudeCode(
            #"{"claudeAiOauth":{"accessToken":"second","expiresAt":1767229200000}}"#)

        let credential = try reader.read()

        #expect(credential.accessToken == "second")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_767_229_200))
    }

    // `security -w` prints the item as bare hex, not text, once any byte
    // is not printable ASCII — so one accented character anywhere in
    // Claude Code's record would otherwise read as malformed on every poll.
    @Test("Reads a record with a non-ASCII byte, which the tool prints as hex")
    func readsHexPrintedRecord() throws {
        try writeAsClaudeCode(
            #"{"claudeAiOauth":{"accessToken":"café","expiresAt":1767225600}}"#)

        let credential = try reader.read()

        #expect(credential.accessToken == "café")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("An absent item reads as not found")
    func absentItem() {
        #expect(throws: CredentialError.notFound) { try self.reader.read() }
    }

    @Test("An item that is not Claude Code's record reads as malformed")
    func malformedItem() throws {
        try writeAsClaudeCode("not json")
        #expect(throws: CredentialError.malformed) { try self.reader.read() }
    }
}

/// The exit-status decision table, pinned to the numbers `security`
/// actually returns.  The reader derives them from `OSStatus` constants by
/// taking the low byte; literals here catch a wrong derivation.  44 was
/// observed from `security`; the denial statuses follow the same rule.
@Suite("Keychain credential reader, exit-status mapping")
struct KeychainExitStatusTests {
    @Test(
        "Failure statuses map to the error UsageSource acts on",
        arguments: [
            (Int32(44), CredentialError.notFound),  // errSecItemNotFound
            (Int32(51), CredentialError.accessDenied),  // errSecAuthFailed
            (Int32(128), CredentialError.accessDenied),  // errSecUserCanceled
            (Int32(36), CredentialError.accessDenied),  // errSecInteractionNotAllowed
            // Not denial: denial is sticky, and an unknown status may clear.
            (Int32(1), CredentialError.unexpected(exitStatus: 1)),
        ])
    func failureStatuses(status: Int32, expected: CredentialError) {
        #expect(throws: expected) {
            try KeychainCredentialReader.credential(exitStatus: status, output: Data())
        }
    }

    @Test("Success with Claude Code's record yields the credential")
    func success() throws {
        let output = Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1767225600}}"#.utf8)
        let credential = try KeychainCredentialReader.credential(exitStatus: 0, output: output)
        #expect(credential.accessToken == "t")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    // Bare hex is the form `security -w` takes once any byte is not
    // printable ASCII; `readsHexPrintedRecord` shows the tool producing it.
    @Test("Hex output from the tool is decoded before the record is read")
    func hexOutput() throws {
        let record = #"{"claudeAiOauth":{"accessToken":"café","expiresAt":1767225600}}"#
        let output = Data((hex(record) + "\n").utf8)
        let credential = try KeychainCredentialReader.credential(exitStatus: 0, output: output)
        #expect(credential.accessToken == "café")
    }

    // `security -w` ends its output with a newline; the decoder must take
    // it as trailing whitespace rather than reject the record.
    @Test("A trailing newline from the tool is accepted")
    func trailingNewline() throws {
        let output = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"t\",\"expiresAt\":1767225600}}\n".utf8)
        let credential = try KeychainCredentialReader.credential(exitStatus: 0, output: output)
        #expect(credential.accessToken == "t")
    }
}
