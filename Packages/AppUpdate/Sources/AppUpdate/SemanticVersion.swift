import Foundation

/// A three-part version, ordered.
///
/// Deliberately stricter than the semver grammar: a version carrying a
/// pre-release or build suffix does not parse at all.  MonoCl only ever
/// compares its own `CFBundleShortVersionString` against the tag of a
/// published release, and `/releases/latest` excludes pre-releases, so a
/// suffix here means the tag is not the shape this comparison assumes.
/// Failing to parse resolves to "no update offered", which is the right
/// answer to a tag MonoCl cannot reason about.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`, and `v1.2.3` for the tag spelling git conventions
    /// favour.  Returns nil for anything else.
    public init?(_ text: String) {
        let body = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        // Each part has to be digits and nothing else.  `Int.init` is not
        // that test and cannot stand in for it: measured against the
        // toolchain, `Int("+1")` is 1 and `Int("-2")` is -2, so leaving
        // the check to it would read "+1.2.3" and "1.-2.3" as versions.
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else {
            return nil
        }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
