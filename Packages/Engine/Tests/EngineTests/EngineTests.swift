import ClaudeUsage
import Foundation
import Indicators
import PlatformStatus
import Testing
@testable import Engine

@MainActor
@Suite("Engine")
struct EngineSuite {
    /// Builds an engine on a virtual clock, with a valid credential that
    /// outlives every advance these tests make.
    private func makeEngine(
        usage: ScriptedHTTP,
        status: ScriptedStatusFetcher = ScriptedStatusFetcher(),
        credentials: StubCredentials? = nil,
        settings: @escaping () -> EngineSettings = { defaultSettings },
        time: TestTimeSource,
        onChange: @escaping () -> Void = {}
    ) throws -> Engine {
        Engine(
            usage: UsageSource(credentials: try credentials ?? validCredential(), http: usage),
            status: PlatformStatusSource(http: status),
            settings: settings,
            time: time,
            onChange: onChange
        )
    }

    @Test("A Retry-After holds usage off for exactly its duration")
    func honoursRetryAfter() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([
            .response(status: 429, body: "", retryAfter: 900),
            .response(status: 200, body: usageBody, retryAfter: nil),
        ])
        let statusHTTP = ScriptedStatusFetcher()
        let engine = try makeEngine(usage: http, status: statusHTTP, time: time)
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        await awaitUsageOutcome(engine)
        #expect(http.callCount == 1)
        #expect(engine.store.isUsageRateLimited == true)

        await time.advance(by: 899)
        #expect(http.callCount == 1)

        await time.advance(by: 2)
        await settle(until: { !engine.store.isUsageRateLimited })
        #expect(http.callCount == 2)
        #expect(engine.store.session.detail == "47%")

        // The platform poller is untouched by usage's rate limit: it
        // ticks at 0, 300, 600 and 900.
        #expect(statusHTTP.callCount == 4)
    }

    @Test("A retained reading blanks when its staleness budget expires")
    func retainedReadingExpires() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([
            .response(status: 200, body: usageBody, retryAfter: nil),
            .offline,
        ])
        // A 420s cadence against the shipped 900s budget, so the instant
        // trust lapses falls between two platform polls (840 and 1260)
        // rather than on one.  With the two aligned, the poll's own
        // re-derivation would mask whether the expiry timer works at
        // all.  Both values are ones Settings offers: its interval
        // stepper runs 60...900 in steps of 60, and its budget floor is
        // twice the interval.
        let offGridCadence = EngineSettings(
            thresholds: .default,
            refreshInterval: 420,
            staleAfter: 900
        )
        var changes = 0
        let engine = try makeEngine(
            usage: http, settings: { offGridCadence }, time: time
        ) { changes += 1 }
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        await awaitUsageOutcome(engine)
        #expect(engine.store.session.state == .nominal)

        // The next poll fails and the sample is retained, so the lights
        // stay lit until the budget itself runs out at +900.
        await time.advance(by: 420)
        await settle(until: { engine.store.usageFailure != nil })
        #expect(engine.store.session.detail == "47%")
        #expect(engine.store.session.note == "Offline")

        let fetchesBefore = http.callCount
        let changesBefore = changes
        await time.advance(by: 480)

        #expect(engine.store.session.state == .unknown)
        #expect(engine.store.session.detail == "Offline")
        #expect(engine.store.week.state == .unknown)
        // The expiry timer, not a poll, is what re-derived: usage is
        // next due at 1680 under backoff and the platform at 1260, so
        // the only thing that ran at 900 was the timer.
        #expect(changes > changesBefore)
        #expect(http.callCount == fetchesBefore + 1)
    }

    @Test("Waking blanks every reading and asks for a refresh")
    func wakeClearsAndRefetches() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([.response(status: 200, body: usageBody, retryAfter: nil)])
        let engine = try makeEngine(usage: http, time: time)
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        await awaitUsageOutcome(engine)
        #expect(engine.store.session.state == .nominal)

        engine.systemDidWake()
        #expect(engine.store.states == [.unknown, .unknown, .unknown])
        #expect(engine.pendingRefresh == .refreshing)

        // The restarted pollers compute their wait from the clock as it
        // stands but register it only once their tasks run, so the clock
        // must not move until they have.
        await settle()

        // The spacing floor is `EngineSettings.minimumRefreshInterval`,
        // 60s, and the last tick was at `origin`.
        await time.advance(by: 60)
        await awaitUsageOutcome(engine)
        #expect(engine.store.session.detail == "47%")
        #expect(engine.pendingRefresh == nil)
    }

    @Test("A denied keychain stops usage polling until a retry")
    func stickyFailureStopsPolling() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([.response(status: 200, body: usageBody, retryAfter: nil)])
        let credentials = StubCredentials(.failure(.accessDenied))
        let engine = try makeEngine(usage: http, credentials: credentials, time: time)
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        await awaitUsageOutcome(engine)
        #expect(engine.store.usagePollingStopped == true)
        #expect(engine.store.session.detail == "Keychain access denied")

        // An hour of ticks later, the one read is still the launch
        // read: the loop keeps turning, but each turn returns before it
        // asks for a credential.  The transport was never reached at
        // all, since the credential read comes first.
        await time.advance(by: 3600)
        #expect(credentials.readCount == 1)
        #expect(http.callCount == 0)
    }

    @Test("A threshold edit re-derives the lights without fetching")
    func settingsChangeRederivesWithoutFetching() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([.response(status: 200, body: usageBody, retryAfter: nil)])
        var settings = defaultSettings
        let engine = try makeEngine(usage: http, settings: { settings }, time: time)
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        await awaitUsageOutcome(engine)
        #expect(engine.store.session.state == .nominal)

        let fetchesBefore = http.callCount
        settings = EngineSettings(
            thresholds: Thresholds(warning: 40, critical: 90),
            refreshInterval: 300,
            staleAfter: 900
        )
        engine.settingsChanged()

        #expect(engine.store.session.state == .warning)
        #expect(http.callCount == fetchesBefore)
    }

    @Test("A rate limit outranks an outstanding request in the refresh row")
    func pendingRefreshPolicy() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([.response(status: 429, body: "", retryAfter: 900)])
        let engine = try makeEngine(usage: http, time: time)
        defer { engine.stop() }

        // Before the first tick lands, both pollers have a refresh
        // outstanding.
        engine.start()
        #expect(engine.pendingRefresh == .refreshing)

        // Both have since answered, so nothing is outstanding; the row
        // reports the rate limit rather than falling silent.
        await time.advance(by: 0)
        await awaitUsageOutcome(engine)
        #expect(engine.pendingRefresh == .rateLimited)
    }
}
