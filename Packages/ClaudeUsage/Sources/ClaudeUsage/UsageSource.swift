import Foundation
import OSLog

/// One window's consumption at a point in time.  Deliberately carries no
/// `IndicatorState`: thresholds are applied by the store, so changing a
/// threshold re-renders immediately instead of waiting for the next poll.
public struct UsageSample: Sendable, Equatable {
    public let percent: Double
    public let resetsAt: Date

    public init(percent: Double, resetsAt: Date) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public enum UsageFailure: Error, Sendable, Equatable {
    case credentialsNotFound
    case keychainDenied
    /// A keychain failure that is neither absence nor denial, so it may
    /// clear on its own and must not stop polling.
    case keychainUnavailable
    /// The stored credential could not be decoded.  The fault is local,
    /// so it is not reported as an endpoint problem, and it is sticky:
    /// Claude Code will not rewrite the record in response to MonoCl
    /// polling it, so retrying to the backoff cap achieves nothing.
    case credentialsUnreadable
    case tokenExpired
    case offline
    case authorizationRejected
    case accessRefused
    case rateLimited(retryAfter: TimeInterval?)
    case unexpectedResponse

    /// Whether this failure means polling should stop until the user asks
    /// for a retry.  No `default` arm: adding a case must fail to compile
    /// until someone decides whether it is sticky.
    public var stopsPolling: Bool {
        switch self {
        case .credentialsNotFound, .keychainDenied, .credentialsUnreadable:
            true
        case .keychainUnavailable, .tokenExpired, .offline,
             .authorizationRejected, .accessRefused, .rateLimited,
             .unexpectedResponse:
            false
        }
    }

    /// Whether the store should keep the last good sample rather than
    /// clear it.  Only a network error or a rate limit qualifies: a
    /// single dropped packet must not grey every light for a minute and
    /// back.  No `default` arm, for the same reason as `stopsPolling`.
    public var retainsSample: Bool {
        switch self {
        case .offline, .rateLimited:
            true
        case .credentialsNotFound, .keychainDenied, .keychainUnavailable,
             .credentialsUnreadable, .tokenExpired, .authorizationRejected,
             .accessRefused, .unexpectedResponse:
            false
        }
    }

    public var menuText: String {
        switch self {
        case .credentialsNotFound: "Claude Code credentials not found"
        case .keychainDenied: "Keychain access denied"
        case .keychainUnavailable: "Keychain unavailable"
        case .credentialsUnreadable: "Claude Code credentials unreadable"
        case .tokenExpired: "Run Claude Code to refresh"
        case .offline: "Offline"
        case .authorizationRejected: "Authorization rejected"
        case .accessRefused: "Access refused by Anthropic"
        case .rateLimited: "Rate limited"
        case .unexpectedResponse: "Unexpected response"
        }
    }
}

public enum UsageOutcome: Sendable, Equatable {
    case samples(
        session: UsageSample?,
        week: UsageSample?,
        asOf: Date,
        tokenExpiresAt: Date
    )
    case failure(UsageFailure)
}

public struct UsageSource: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentials: any CredentialReading
    private let http: any HTTPFetching
    private let logger = Logger(subsystem: "net.sinistral.monocl", category: "usage")

    public init(credentials: any CredentialReading, http: any HTTPFetching) {
        self.credentials = credentials
        self.http = http
    }

    public func fetch(now: Date) async -> UsageOutcome {
        let credential: StoredCredential
        do {
            credential = try credentials.read()
        } catch let error as CredentialError {
            switch error {
            case .notFound: return .failure(.credentialsNotFound)
            case .accessDenied: return .failure(.keychainDenied)
            case .unexpected: return .failure(.keychainUnavailable)
            case .malformed: return .failure(.credentialsUnreadable)
            }
        } catch {
            return .failure(.unexpectedResponse)
        }

        // Gate on expiry rather than discovering it via a 401.  Cheaper,
        // and it never exercises the refresh path MonoCl must not use.
        guard credential.expiresAt > now else { return .failure(.tokenExpired) }

        let result: HTTPResult
        do {
            // Verified 2026-08-31: the endpoint returns 200 with and
            // without `anthropic-beta: oauth-2025-04-20`, so MonoCl does
            // not send a beta identifier it does not need.
            result = try await http.get(Self.endpoint, headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "Content-Type": "application/json",
            ])
        } catch is URLError {
            return .failure(.offline)
        } catch {
            return .failure(.unexpectedResponse)
        }

        switch result.status {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(UsageResponse.self, from: result.body)
                return .samples(
                    session: decoded.fiveHour.map {
                        UsageSample(percent: $0.percent, resetsAt: $0.resetsAt)
                    },
                    week: decoded.sevenDay.map {
                        UsageSample(percent: $0.percent, resetsAt: $0.resetsAt)
                    },
                    asOf: now,
                    tokenExpiresAt: credential.expiresAt
                )
            } catch {
                logger.error("Usage response did not decode")
                return .failure(.unexpectedResponse)
            }
        case 401: return .failure(.authorizationRejected)
        case 403: return .failure(.accessRefused)
        case 429: return .failure(.rateLimited(retryAfter: result.retryAfter))
        default:
            logger.error("Usage endpoint returned \(result.status, privacy: .public)")
            return .failure(.unexpectedResponse)
        }
    }
}
