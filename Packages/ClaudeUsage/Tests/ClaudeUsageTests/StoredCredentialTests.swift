import Foundation
import Testing

@testable import ClaudeUsage

@Suite("Stored credential decoding")
struct StoredCredentialTests {
    private func decode(_ json: String) throws -> StoredCredential {
        try JSONDecoder().decode(
            KeychainRecord.self, from: Data(json.utf8)
        ).claudeAiOauth
    }

    @Test("Decodes the two fields MonoCl needs and ignores the rest")
    func decodesMinimalFields() throws {
        let c = try decode(
            """
            {"claudeAiOauth":{"accessToken":"sk-test-abc",
              "refreshToken":"rt-should-be-ignored",
              "expiresAt":1767225600,
              "scopes":["user:profile"],
              "subscriptionType":"max"}}
            """)
        #expect(c.accessToken == "sk-test-abc")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("Milliseconds are recognized as milliseconds")
    func decodesMilliseconds() throws {
        let c = try decode(
            """
            {"claudeAiOauth":{"accessToken":"t","expiresAt":1767225600000}}
            """)
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("Seconds are recognized as seconds")
    func decodesSeconds() throws {
        let c = try decode(
            """
            {"claudeAiOauth":{"accessToken":"t","expiresAt":1767225600}}
            """)
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("A missing accessToken is a decoding error")
    func missingToken() {
        #expect(throws: DecodingError.self) {
            _ = try decode(
                """
                {"claudeAiOauth":{"expiresAt":1767225600}}
                """)
        }
    }

    @Test("The description redacts the token")
    func descriptionIsRedacted() throws {
        let c = try decode(
            """
            {"claudeAiOauth":{"accessToken":"sk-secret-value","expiresAt":1767225600}}
            """)
        let described = String(describing: c)
        #expect(described.contains("<redacted>"))
        #expect(described.contains("sk-secret-value") == false)
    }
}
