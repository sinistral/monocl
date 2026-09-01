import Foundation
import Indicators
import OSLog

/// The platform's state at a point in time.  The description is
/// Anthropic's own wording, repeated verbatim.
public struct StatusSample: Sendable, Equatable {
    public let state: IndicatorState
    public let description: String

    public init(state: IndicatorState, description: String) {
        self.state = state
        self.description = description
    }
}

public enum StatusFailure: Error, Sendable, Equatable {
    case offline
    case unexpectedResponse

    public var menuText: String {
        switch self {
        case .offline: "Offline"
        case .unexpectedResponse: "Platform status unavailable"
        }
    }

    /// Whether the store should keep the last good sample rather than
    /// clear it.  No `default` arm: adding a case must fail to compile
    /// until someone decides whether it is sticky.
    public var retainsSample: Bool {
        switch self {
        case .offline: true
        case .unexpectedResponse: false
        }
    }
}

public enum StatusOutcome: Sendable, Equatable {
    case sample(StatusSample, asOf: Date)
    case failure(StatusFailure)
}

public protocol StatusFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct EphemeralStatusFetcher: StatusFetching {
    public init() {}

    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct PlatformStatusSource: Sendable {
    public static let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    private let http: any StatusFetching
    private let logger = Logger(subsystem: "net.sinistral.monocl", category: "status")

    public init(http: any StatusFetching = EphemeralStatusFetcher()) {
        self.http = http
    }

    public func fetch(now: Date) async -> StatusOutcome {
        do {
            let (data, status) = try await http.get(Self.endpoint)
            guard status == 200 else {
                logger.error("Statuspage returned \(status, privacy: .public)")
                return .failure(.unexpectedResponse)
            }
            let decoded = try JSONDecoder().decode(SummaryResponse.self, from: data)
            return .sample(
                StatusSample(
                    state: decoded.indicatorState,
                    description: decoded.status.description
                ),
                asOf: now
            )
        } catch is URLError {
            return .failure(.offline)
        } catch let error as DecodingError {
            // Safe to log in full: `SummaryResponse` decodes only the
            // public Statuspage summary (`status.indicator`,
            // `status.description`), and this fetch sends no
            // credential, so a `DecodingError` here can only name
            // those fields.
            logger.error("Status response did not decode: \(String(describing: error), privacy: .public)")
            return .failure(.unexpectedResponse)
        } catch {
            return .failure(.unexpectedResponse)
        }
    }
}
