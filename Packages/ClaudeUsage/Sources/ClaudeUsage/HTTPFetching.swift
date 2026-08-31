import Foundation

public struct HTTPResult: Sendable {
    public let status: Int
    public let body: Data
    public let retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval?) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

public protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult
}

/// The real transport.
///
/// A fresh ephemeral session per call, rather than one retained session:
/// at one call a minute the cost is irrelevant, and an ephemeral
/// configuration guarantees no credential, cookie, or cache from the
/// request ever reaches disk.
public struct EphemeralHTTPFetcher: HTTPFetching {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return HTTPResult(status: http?.statusCode ?? 0, body: data, retryAfter: retryAfter)
    }
}
