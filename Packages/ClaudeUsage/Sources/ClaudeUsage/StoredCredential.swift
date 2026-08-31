import Foundation

/// The keychain item's outer shape.  Claude Code stores a JSON object
/// whose `claudeAiOauth` member holds the subscription login.
struct KeychainRecord: Decodable {
    let claudeAiOauth: StoredCredential
}

/// The two fields MonoCl needs from Claude Code's credential.
///
/// Deliberately not `Encodable`: there is no legitimate reason for
/// MonoCl to serialise this, and making it impossible is cheaper than
/// remembering not to.
public struct StoredCredential: Sendable, Decodable {
    public let accessToken: String
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        let raw = try container.decode(Double.self, forKey: .expiresAt)
        expiresAt = Self.date(fromEpoch: raw)
    }

    /// Claude Code has written this field as both epoch seconds and epoch
    /// milliseconds across versions, and the unit is not documented.
    /// Values past this threshold cannot plausibly be seconds — 10^11
    /// seconds is the year 5138 — so they are milliseconds.
    static func date(fromEpoch raw: Double) -> Date {
        raw > 100_000_000_000 ? Date(timeIntervalSince1970: raw / 1000)
                              : Date(timeIntervalSince1970: raw)
    }

}

extension StoredCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "StoredCredential(expiresAt: \(expiresAt), accessToken: <redacted>)"
    }

    public var debugDescription: String { description }
}
