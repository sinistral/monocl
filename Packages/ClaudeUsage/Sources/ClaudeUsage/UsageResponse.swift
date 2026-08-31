import Foundation

/// One rate-limit window as the endpoint reports it.
public struct UsageWindow: Sendable, Equatable, Decodable {
    /// Consumption as a percentage from 0 to 100.
    public let percent: Double
    public let resetsAt: Date

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Verified against the live endpoint on 2026-08-31: this field
        // is already a percentage from 0 to 100, so it is taken as-is.
        // Claude Code's status line multiplies by 100, but it does that
        // to its own normalised internal state, not to this response.
        percent = try c.decode(Double.self, forKey: .utilization)
        resetsAt = try Self.timestamp(
            from: c.decode(String.self, forKey: .resetsAt), at: c.codingPath
        )
    }

    /// The endpoint sends ISO-8601 with six fractional-second digits and
    /// an offset (`2026-08-31T17:50:00.568709+00:00`).  Both forms are
    /// accepted because the fractional part is not guaranteed.
    static func timestamp(from text: String, at path: [any CodingKey]) throws -> Date {
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: path,
            debugDescription: "resets_at is not an ISO-8601 timestamp: \(text)"
        ))
    }
}

/// The usage endpoint's response.  Each window is independently
/// optional: the endpoint omits a window it has nothing to say about,
/// and both being absent is a normal response, not an error.
public struct UsageResponse: Sendable, Equatable, Decodable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}
