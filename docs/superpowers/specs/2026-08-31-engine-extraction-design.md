# Engine extraction — design

**Date:** 2026-08-31
**Status:** approved for planning

## Why

MonoCl's rules, sources, derived state and renderers are already
separated and unit-tested headlessly. What is not separated is the
composition root. `MonoCl/AppDelegate.swift` owns real behavior that
exists nowhere else:

- the poll → apply → render cycle for both sources,
- the `rateLimitedUntil` deadline derived from `Retry-After`,
- the trust-expiry timer (`armExpiryTimer`),
- wake handling (clear samples, then refresh both),
- the `pendingRefresh` policy that decides what the menu's refresh row
  says.

All of it lives in an `NSApplicationDelegate` that grabs
`NSStatusBar.system` on launch, so it cannot be instantiated in a test.
`MonoClTests/SmokeTests.swift` asserts the class's *name*. Every
cross-component behavior is therefore observable only by running the
app and watching a menu bar — which is how the acceptance criteria for
these behaviors were originally verified.

A second obstacle compounds it: `Refresher` and `AppDelegate` call
`Date.now` and `Task.sleep` directly, so even a headless test of "a 429
arrives, backoff stretches, the retained reading expires, the lights
blank" would have to wait in real time.

The goal is that the engine can be driven independently of the UI, at
whatever speed a test likes, and that the UI remains a sampler of its
state.

## Scope

In scope: extracting orchestration into a new local package, giving it
an injectable time source, and covering the previously unreachable
compositions with tests.

Out of scope: any change to what MonoCl displays, what it fetches, how
it decides thresholds or staleness, or how often it polls. This is a
structural change with no intended behavioral change.

## Module layout

A fourth local package, `Packages/Engine` (product `Engine`),
depending on `Indicators`, `ClaudeUsage` and `PlatformStatus`.

| File | From → To | Change |
|---|---|---|
| `IndicatorStore.swift` | app → Engine | access levels only |
| `Refresher.swift` | app → Engine | takes a `TimeSource` |
| `PendingRefresh` (+ `forMenu`) | `MenuBuilder.swift` → Engine | moves out of the AppKit file; it is pure policy, and the Engine computes it |
| `TimeSource.swift` | new, Engine | protocol + `SystemTimeSource` |
| `Engine.swift` | new, Engine | orchestration extracted from `AppDelegate` |

Remaining in the app target: `AppDelegate`, `MonoClApp`, `Preferences`,
`SettingsView`, `MenuBuilder`, `MenuBarIcon`, `TooltipComposer`,
`FakeCredentialReader` and `resolvedCredentialReader`. Keychain and
`UserDefaults` wiring therefore never enters the package: the app
constructs `UsageSource` and `PlatformStatusSource` and hands them in.

The package boundary is the point. It makes "the UI samples an
independently driven engine" a compile error to violate rather than a
convention, and it lets the engine suite run under `swift test` with no
app host — the same reason `Indicators`, `ClaudeUsage` and
`PlatformStatus` are packages.

### Settings cross the boundary as one value

```swift
public struct EngineSettings: Equatable, Sendable {
    public let thresholds: Thresholds
    public let refreshInterval: TimeInterval
    public let staleAfter: TimeInterval
}
```

Supplied by a single `settings: () -> EngineSettings`, with
`Preferences` mapping onto it in the app. This collapses today's three
separate reads — the `interval:` closure passed to each `Refresher`,
plus the `store.thresholds` and `store.staleAfter` assignments inside
`AppDelegate.render()` — into one. `Preferences.minimumRefreshInterval`
moves to the package as the floor `Refresher` already enforces; the
app's own clamp reads it from there.

### Public surface

`Engine`, `EngineSettings`, `IndicatorStore` (its read-only projections
plus the `apply`/`retryUsage`/`clearOnWake`/`revalidate` methods its own
tests need), `PendingRefresh`, `TimeSource`, `SystemTimeSource`,
`Refresher`. `MenuBuilderTests` and `MenuBarIconTests` stay in the app
bundle and build an `IndicatorStore` through that public API instead of
`@testable`.

## The `TimeSource` seam

```swift
@MainActor
public protocol TimeSource: AnyObject {
    var now: Date { get }
    /// Returns early — without throwing — when the calling task is
    /// cancelled, so callers guard on `Task.isCancelled` afterwards.
    func sleep(for duration: TimeInterval, tolerance: TimeInterval) async
}
```

Not `Swift.Clock`: the engine needs wall-clock `Date` for `asOf`,
staleness budgets, `Retry-After` deadlines and window reset times, which
`Swift.Clock` deliberately does not provide. The name avoids shadowing
`Swift.Clock` at the same time.

`sleep` is non-throwing because `Refresher` already writes
`try? await Task.sleep(…)` followed by `guard !Task.isCancelled`: the
`try?` carries no information and the guard is the real check.

`SystemTimeSource` forwards to `Date.now` and
`Task.sleep(for:tolerance:)`, preserving the coalescing tolerance that
`Refresher`'s energy-guidance comment justifies.

Every remaining `Date.now` inside the package goes through the seam:
`Refresher`'s `lastTickAt`, `spacingRemaining` and `firstTickWait`; and
in `Engine`, the `revalidate(now:)` calls, the `rateLimitedUntil`
arithmetic and the expiry-timer arming. The sources continue to take
`now:` as a parameter, as they do today.

### `TestTimeSource`

Test-only, living in `Tests/EngineTests`. No shipped testing target
until something outside the package needs one.

- Holds a virtual `now` and a set of registered sleepers
  `(deadline, continuation)`.
- `advance(by:)` walks stepwise: repeatedly take the earliest deadline
  at or before the target, set `now` to exactly that instant, resume
  that sleeper, `await Task.yield()` so it can run and register its next
  sleep, then continue; finally set `now` to the target. Stepwise is
  what makes a five-minute advance produce five one-minute ticks in
  order rather than one collapsed wake-up.
- `sleep` registers through `withTaskCancellationHandler` and
  `withCheckedContinuation`, resuming immediately on cancellation.
  Without that, a `stop()` during a sleep leaves a suspended
  continuation and the test hangs instead of failing.
- Tolerance is ignored: virtual time has nothing to coalesce with. This
  is the only behavioral difference from `SystemTimeSource` and is
  commented as such on the fake.

Everything is `@MainActor`, so the fake needs no locking.

**Determinism caveat.** `await Task.yield()` is a scheduling hint, not a
barrier. Tests therefore assert on events rather than on elapsed
advances: the existing `TickSpy` / `AsyncStream` idiom
(`await waitForTicks(4, from: spy.ticks)`) is retained and becomes the
standard way every ported test waits. `advance` supplies the time; the
stream supplies the ordering.

## `Engine`

```swift
@MainActor
public final class Engine {
    public let store: IndicatorStore

    public init(
        usage: UsageSource,
        status: PlatformStatusSource,
        settings: @escaping () -> EngineSettings,
        time: any TimeSource = SystemTimeSource(),
        onChange: @escaping () -> Void
    )

    public func start()           // launch
    public func stop()            // teardown: both refreshers and the expiry task
    public func refreshNow()      // "Refresh now"
    public func retryUsage()      // "Retry" after a sticky failure
    public func settingsChanged() // the Settings window was edited
    public func systemDidWake()   // clear samples, then refresh both
    public func menuWillOpen()    // revalidate only; deliberately does not fetch
    public var pendingRefresh: PendingRefresh? { get }
}
```

A private `refreshState()` replaces today's `AppDelegate.render()`:
apply `settings()` to the store, `store.revalidate(now: time.now)`,
re-arm the expiry task, then call `onChange()`. Readings are always
fresh before the UI samples them — an ordering `render()` gets right
today and that nothing currently enforces.

`onChange` is a callback rather than observation because the UI still
samples the store; the callback only says *when*. `withObservationTracking`
is one-shot and must be re-registered on every render, with no framework
help in an AppKit menu-bar app, and an `AsyncStream` of snapshots would
add a type and an async hop for a single consumer.

`AppDelegate` reduces to: building the `NSStatusItem` and menu,
constructing the sources and the `Engine`, passing
`onChange: { renderIcon(); renderMenu() }`, forwarding the
`NSWorkspace` and `NSMenuDelegate` events, and owning the four `@objc`
selectors. The accessibility-options notification stops reaching the
engine entirely: it changes only how the icon is drawn, so it calls
`renderIcon()` directly.

### Sources go in concretely, faked at the network boundary

`Engine` takes `UsageSource` and `PlatformStatusSource` as they are.
Engine tests inject fake `HTTPFetching`, `StatusFetching` and
`CredentialReading` implementations, so a rate-limit test drives a real
429 with a real `Retry-After` header through the real decoder. No new
protocol is introduced over the sources, and the only thing faked is the
external network.

Accepted cost: `EngineTests` carries its own small copies of the
canned-response fakes, because each package's `Tests/…/Fakes.swift` is
not visible across packages.

### State lifecycle

| State | Written by | Read by | Cleared by |
|---|---|---|---|
| `rateLimitedUntil` | `pollUsage`, on `.rateLimited(retryAfter:)`, as a deadline | the usage `Refresher`'s `retryAfter` closure (scheduling only) | `pollUsage` on any other outcome; **not** by wake — a server-side limit survives sleep |
| `expiryTask` | `refreshState`, re-armed each time | nothing; its firing calls `refreshState` | its own re-arm, and `stop()` |
| `isRefreshPending`, `consecutiveFailures`, `lastTickAt` | unchanged, inside `Refresher` | unchanged | unchanged |

`stop()` is new. Nothing tears this down today because the app only ever
exits. It exists so `afterEach` can cancel both loops and the expiry
task; without it, a test leaks a live poller into the next case.

What the menu says about a rate limit continues to come from
`store.isUsageRateLimited`, never from `rateLimitedUntil` — a 429 need
not carry a parseable header, and that split survives the move
unchanged.

## Testing

**Moved into `Packages/Engine/Tests/EngineTests`, behavior unchanged:**
all of `RefresherTests`, ported to `TestTimeSource` with `base = 0.01`
and every `Task.sleep` removed but the `TickSpy` / `AsyncStream`
sequencing retained; and all of `IndicatorStoreTests`, which already
drive time through explicit `now:` arguments rather than reading a
clock, so only the import changes.

**Remaining in the app bundle:** `MenuBuilderTests`, `MenuBarIconTests`,
`TooltipComposerTests`, `PreferencesTests`, `FakeCredentialReaderTests`,
`SmokeTests` — adjusted only where they built an `IndicatorStore`
through `@testable`.

**New engine tests.** Each covers a composition currently reachable only
by driving the app, and each fails if the behavior it names is removed:

1. **A rate limit is honored.** 429 with `Retry-After: 900` — advancing
   899s produces no further usage request; 901s produces exactly one.
   The status poller keeps its own cadence throughout.
2. **A retained reading expires on its own.** A good sample, then usage
   goes offline; advance past `staleAfter` with the poll cadence
   stretched by backoff. Session and week become `.unknown` at the
   expiry instant, and `onChange` fires without a tick having occurred.
   This is what proves the expiry task exists and is armed correctly.
3. **Wake blanks, then refetches.** `systemDidWake()` leaves all three
   readings `.unknown`, restarts both refreshers, and reports
   `pendingRefresh == .refreshing`.
4. **A sticky failure stops usage polling.** Keychain denied sets
   `usagePollingStopped`, and the fake fetcher's call count stays put
   across several advances; `retryUsage()` resumes it.
5. **A threshold edit re-derives without a fetch.** `settingsChanged()`
   with a warning threshold below the current percentage turns the
   session reading amber, with the fetch count unchanged.
6. **`pendingRefresh` policy.** A rate limit outranks an outstanding
   request; either poller outstanding yields `.refreshing`; neither
   yields `nil`.

Assertions are affirmative about the expected state, not about the
absence of unwanted ones. Per-test state resets in `beforeEach`, and
`stop()` runs in `afterEach`.

Verification: `swift test` in `Packages/Engine` (no app host, no
launch), plus `xcodebuild -scheme MonoCl test` for the app bundle, both
captured to files.

## Migration

Six commits, each leaving the build and both suites green:

1. **Package skeleton** — `Packages/Engine` with `TimeSource` and
   `SystemTimeSource` only; `project.yml` gains the package and the
   dependency; regenerate with `xcodegen`. No consumers yet.
2. **Move `Refresher`** and its tests into the package; it takes a
   `TimeSource`; the tests are ported to `TestTimeSource`. The largest
   mechanical diff, isolated from any behavioral change.
3. **Move `IndicatorStore`** and its tests; move `PendingRefresh` out of
   `MenuBuilder.swift`. Access-level churn; app tests adjusted.
4. **Add `EngineSettings` and `Engine`** by extraction from
   `AppDelegate`, and rewire `AppDelegate`. The only commit that can
   change behavior.
5. **New engine tests**, written first against the extracted code.
6. **Tidy** — re-home `Preferences.minimumRefreshInterval`, retarget the
   comments in `AppDelegate` that now describe code living elsewhere.

## Risk

Commit 4 relocates live scheduling and rate-limit logic, so a mistake
shows up as request-rate misbehavior against Anthropic's endpoint rather
than as a red test — the failure mode this codebase has been most
careful about.

Mitigations: `minimumSpacing` and its floor stay inside `Refresher` and
are never re-derived at a call site; the ported `RefresherTests` guard
the spacing and backoff rules before commit 4 lands; and the new tests
in commit 5 pin the rate-limit and sticky-failure paths that reach the
network. The coverage gap exists only between commits 4 and 5, which is
why 5 immediately follows.

Not covered by any of this, and staying hand-verified before merge: the
keychain authorization dialog, the actual menu-bar rendering, and real
sleep and wake. One live run after commit 6 — launch, confirm the three
dots read plausibly, and check `log show` for request cadence — is the
last gate rather than a test.

## Second-order effect

Once `swift test` covers the engine, the `MONOCL_FAKE_CREDENTIAL:
not-found` environment variable in the `MonoCl` scheme protects only the
remaining app-target tests. It does not go away — the test bundle is
still hosted by the app, which still launches `AppDelegate` before any
app-target test runs — but its blast radius shrinks. Recorded here so it
is not rediscovered as a mystery.
