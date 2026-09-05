import Foundation
import OSLog

/// A published release newer than the one running.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: SemanticVersion
    public let page: URL

    public init(version: SemanticVersion, page: URL) {
        self.version = version
        self.page = page
    }
}

/// What one check established.
///
/// The third case is the point of the type: a check that did not
/// complete has established nothing, and must not be mistaken for one
/// that established there is nothing to offer.  Collapsing the two would
/// let a moment without a network erase a row that is still true.
public enum UpdateCheckOutcome: Sendable, Equatable {
    /// A newer release exists.
    case available(AvailableUpdate)

    /// There is no newer release MonoCl can offer.  Settled: it will not
    /// change until GitHub's answer does.
    case nothingToOffer

    /// The check did not complete.  Whatever was last known still
    /// stands, because nothing has contradicted it.
    case indeterminate
}

public protocol ReleaseFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct EphemeralReleaseFetcher: ReleaseFetching {
    public init() {}

    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        // GitHub rejects an API request that does not identify itself,
        // and names the version it serves through the Accept header.
        request.setValue("MonoCl", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Asks GitHub whether a release newer than the running build exists.
///
/// Nothing here is ever reported to the reader as a fault.  MonoCl's own
/// health has no place in a menu that is otherwise entirely about
/// Claude, so the worst any failure produces is the absence of a row.
///
/// What it does distinguish is a settled answer from an unsettled one.
/// A 404, or a tag that does not parse, is settled -- GitHub has
/// answered, and asking again shortly would get the same reply.  Being
/// offline or rate-limited is not, and is reported as `indeterminate` so
/// the caller can keep what it already knew.
public struct UpdateSource: Sendable {
    public static let endpoint = URL(
        string: "https://api.github.com/repos/sinistral/monocl/releases/latest")!

    private let http: any ReleaseFetching
    private let logger = Logger(subsystem: "net.sinistral.monocl", category: "update")

    public init(http: any ReleaseFetching = EphemeralReleaseFetcher()) {
        self.http = http
    }

    public func check(against current: SemanticVersion) async -> UpdateCheckOutcome {
        do {
            let (data, status) = try await http.get(Self.endpoint)
            // 404 is the ordinary answer for a repository that has never
            // published a release -- the state this one is in until the
            // first release is cut -- so it settles the question.  Every
            // other unusable status is transient as far as MonoCl can
            // tell: a rate limit lifts, a 5xx passes.
            guard status == 200 else {
                logger.info("GitHub returned \(status, privacy: .public)")
                return status == 404 ? .nothingToOffer : .indeterminate
            }
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)
            guard let version = SemanticVersion(release.tagName) else {
                logger.info("Tag \(release.tagName, privacy: .public) is not a three-part version")
                return .nothingToOffer
            }
            // Checked where the value is parsed rather than where it is
            // opened: `NSWorkspace` honours whatever scheme it is handed,
            // so a non-https page reaching the menu row would be one
            // click from launching something that is not a web page.
            // Case-folded: `URL` does not normalise the scheme, so an
            // "HTTPS://" page would fail a literal comparison.
            guard release.htmlURL.scheme?.lowercased() == "https" else {
                logger.error("Release page is not https")
                return .nothingToOffer
            }
            guard version > current else { return .nothingToOffer }
            return .available(AvailableUpdate(version: version, page: release.htmlURL))
        } catch let error as DecodingError {
            // Safe to log in full: `LatestRelease` decodes only the
            // public `tag_name` and `html_url`, and this fetch sends no
            // credential, so the error can only name those fields.
            logger.error(
                "Release response did not decode: \(String(describing: error), privacy: .public)")
            // Unsettled, despite a 200: the likeliest cause of a body
            // that will not decode is not GitHub changing its schema but
            // a captive portal answering on its behalf, which is exactly
            // the transient case the reader should not lose a row over.
            // The cost of being wrong is a check every fifteen minutes
            // instead of every day -- 96 unauthenticated requests
            // against a limit of 60 an hour.
            return .indeterminate
        } catch {
            logger.info("Release check did not complete: \(error.localizedDescription)")
            return .indeterminate
        }
    }
}
