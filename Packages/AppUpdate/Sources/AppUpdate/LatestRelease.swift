import Foundation

/// The subset of GitHub's release representation MonoCl reads.
public struct LatestRelease: Sendable, Equatable, Decodable {
    public let tagName: String
    public let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(tagName: String, htmlURL: URL) {
        self.tagName = tagName
        self.htmlURL = htmlURL
    }
}
