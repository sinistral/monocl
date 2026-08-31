import Testing
@testable import MonoCl

@Suite("Smoke")
struct SmokeTests {
    @Test("The test target is wired to the app target")
    func targetIsWired() {
        // Names a type from the app target, so this fails to compile if
        // the host-application link is broken.
        #expect(String(describing: AppDelegate.self) == "AppDelegate")
    }
}
