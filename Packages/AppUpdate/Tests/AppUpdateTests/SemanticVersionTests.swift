import Testing

@testable import AppUpdate

@Suite("Semantic version")
struct SemanticVersionTests {
    @Test(
        "Three-part versions parse, with or without the tag's v",
        arguments: [
            ("0.1.0", SemanticVersion(major: 0, minor: 1, patch: 0)),
            ("v0.2.0", SemanticVersion(major: 0, minor: 2, patch: 0)),
            ("10.20.30", SemanticVersion(major: 10, minor: 20, patch: 30)),
        ])
    func parses(text: String, expected: SemanticVersion) {
        #expect(SemanticVersion(text) == expected)
    }

    @Test(
        "Anything that is not three whole numbers fails to parse",
        arguments: [
            "1.2", "1.2.3.4", "1.2.x", "", "v", "1.2.3-beta", "1.2.3+build", " 1.2.3", "1.-2.3",
            // `Int("+1")` is 1 and `Int("-2")` is -2, so these parse
            // unless the digits are checked before Int sees them.
            "+1.2.3", "1.+2.3", "1.2.+3", "-1.2.3",
        ])
    func rejects(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test(
        "Ordering runs major, then minor, then patch",
        arguments: [
            ("0.1.0", "0.2.0"),
            ("0.9.9", "1.0.0"),
            ("1.0.0", "1.0.1"),
            // Not a string comparison: "1.10.0" sorts below "1.9.0"
            // lexically and above it numerically.
            ("1.9.0", "1.10.0"),
        ])
    func ordering(lower: String, higher: String) throws {
        let lower = try #require(SemanticVersion(lower))
        let higher = try #require(SemanticVersion(higher))
        #expect(lower < higher)
        #expect(higher > lower)
    }

    @Test("Equal versions compare equal")
    func equality() throws {
        #expect(
            try #require(SemanticVersion("1.2.3")) == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("A version describes itself in the form it was parsed from")
    func describes() {
        #expect(String(describing: SemanticVersion("v1.2.3")!) == "1.2.3")
    }
}
