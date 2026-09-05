// MonoCl/UpdateChecker.swift
import AppUpdate
import Foundation

/// Asks, on a slow cadence, whether a newer release has been published,
/// and holds the answer for the menu to draw.
///
/// Separate from `Engine` on purpose.  Engine's subject is Claude — it
/// polls the two sources, derives readings from thresholds, and ages
/// them out.  An available update is none of those things: it has no
/// utilisation, no threshold, and no staleness, and folding it in would
/// widen Engine's subject from "what Claude is doing" to "anything
/// MonoCl wants to mention".
@MainActor
final class UpdateChecker {
    /// The newest release worth telling the reader about, or nil when
    /// the last settled check found none.  A check that did not complete
    /// leaves this alone rather than clearing it.
    private(set) var available: AvailableUpdate?

    private let check: @Sendable () async -> UpdateCheckOutcome
    private let interval: Duration
    private let retryInterval: Duration
    private let onChange: () -> Void
    private var task: Task<Void, Never>?

    /// A closure rather than an injected `UpdateSource`, because the
    /// only thing this type does with the source is call it once per
    /// interval; a protocol would describe a relationship that is not
    /// there.
    init(
        interval: Duration = .seconds(24 * 60 * 60),
        retryInterval: Duration = .seconds(15 * 60),
        check: @escaping @Sendable () async -> UpdateCheckOutcome,
        onChange: @escaping () -> Void
    ) {
        self.interval = interval
        self.retryInterval = retryInterval
        self.check = check
        self.onChange = onChange
    }

    /// Whether to check at all.
    ///
    /// The test bundle is hosted by the app, so
    /// `applicationDidFinishLaunching` runs before any test does, and an
    /// unguarded checker would put a live request to api.github.com in
    /// every `xcodebuild test`.  The suites are offline by construction
    /// -- that is why the fixture drift check is a separate, deliberate
    /// script -- and a suite that reaches the network is flaky and
    /// rate-limitable.  The same reason `MONOCL_FAKE_CREDENTIAL` exists,
    /// for the same reader.
    ///
    /// Release builds have no environment hook at all, as with the
    /// credential: the check is always on.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
            return environment[skipUpdateCheckVariable] == nil
        #else
            _ = environment
            return true
        #endif
    }

    /// The running build's version, or nil if it does not parse — in
    /// which case no check is ever made, since there is nothing to
    /// compare a release against.
    static var runningVersion: SemanticVersion? {
        guard
            let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String
        else { return nil }
        return SemanticVersion(text)
    }

    /// Checks immediately, then once per `interval` -- or once per
    /// `retryInterval` after a check that did not complete.  The launch
    /// check is the one that most often fails: a login item starts before
    /// the network is up, and waiting a full day to try again would leave
    /// the reader a day behind for the sake of one unlucky moment.
    ///
    /// Replaces any previous loop.  A check already in flight when this
    /// is called runs to completion -- cancellation is cooperative, and
    /// the only cancellation point is the sleep -- so two checks can
    /// briefly overlap even though two loops cannot persist.  Reachable
    /// only if `start()` is called twice, which today it is not.
    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let settled = await self.checkNow()
                do {
                    try await Task.sleep(for: settled ? self.interval : self.retryInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// One check.  Separate from the cadence that drives it so the
    /// publishing rule can be tested without waiting out an interval.
    ///
    /// Returns whether the check settled the question, which is what the
    /// caller needs to choose how long to wait before the next one.
    ///
    /// A check that did not complete changes nothing.  Treating it as
    /// "no update" would let a moment without a network retract a row
    /// that is still true, and the reader would watch an update they had
    /// been told about disappear.
    ///
    /// Otherwise announces only a change.  The answer is the same on
    /// almost every check, and redrawing the menu each time would rebuild
    /// it on a timer for no reason.
    @discardableResult
    func checkNow() async -> Bool {
        let found: AvailableUpdate?
        switch await check() {
        case .available(let update): found = update
        case .nothingToOffer: found = nil
        case .indeterminate: return false
        }
        guard found != available else { return true }
        available = found
        onChange()
        return true
    }

    /// The app never calls this — it checks for as long as it runs — but
    /// a test that leaves the loop running leaks it into the next test.
    func stop() {
        task?.cancel()
        task = nil
    }
}

#if DEBUG
    /// Set on the test scheme.  Presence is the whole signal -- any
    /// value switches the check off, `0` included -- because the only
    /// thing that sets it is the scheme, and a value it could
    /// disagree with would be one more thing to get wrong.
    ///
    /// DEBUG-only, like `fakeCredentialVariable`: a Release build
    /// should not have its update check switched off by whatever
    /// happens to be in the environment that launched it.
    let skipUpdateCheckVariable = "MONOCL_SKIP_UPDATE_CHECK"
#endif
