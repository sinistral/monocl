# Engine Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move MonoCl's orchestration out of `AppDelegate` into a new `Packages/Engine` module with an injectable `TimeSource`, so every cross-component behaviour can be tested headlessly instead of by driving the app.

**Architecture:** A fourth local SwiftPM package holds `TimeSource`, `Refresher`, `IndicatorStore`, `PendingRefresh` and a new `Engine` that owns the poll → apply → revalidate cycle, the `Retry-After` deadline, the trust-expiry timer and the refresh-pending policy. The app target keeps AppKit, `UserDefaults` and the keychain, constructs the sources, and re-renders from an `onChange` callback. Tests drive the engine through a virtual clock and fake HTTP transports.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency), swift-tools 6.3, macOS 26, Swift Testing (`@Test`/`#expect`), XcodeGen, SwiftPM local packages.

**Spec:** `docs/superpowers/specs/2026-08-31-engine-extraction-design.md`

## Global Constraints

- **No behavioural change is intended.** What MonoCl displays, fetches, and how often it polls must be identical after this plan as before it. Any observable difference is a defect, not an improvement.
- **Request rate is sacred.** `minimumSpacing` stays inside `Refresher` and is never re-derived at a call site. No new code path may reach `UsageSource.fetch` or `PlatformStatusSource.fetch` outside a `Refresher` tick.
- The package must never import AppKit, SwiftUI, or `UserDefaults`. Keychain and preferences wiring stay in the app target.
- Swift 6 language mode, strict concurrency complete. Everything in the package is `@MainActor` except value types, which are `Sendable`.
- Tests: affirmative assertions about the expected state, never assertions about the absence of unwanted ones. Per-test mutable state resets in the test body's own construction; anything that starts a poller must be stopped before the test returns.
- Comments follow the repo's existing style: UK English, sentence-case headings with `---` underlining, motivation not restatement.
- Commit subjects end with a period; no conventional-commit prefixes; body wrapped at 72 columns.
- Test output is captured to a file and inspected afterwards, never piped through a filter as the only record.

**User decisions (already made):**
- "B" — the engine goes in a fourth local package, `Packages/Engine`, not in the app target.
- "TimeSource is fine" — the seam is named `TimeSource`, not `Clock`.
- Full injected clock (both `now` and `sleep`), not merely an injected `now()`.
- `onChange` callback for change notification, not `@Observable` tracking or an `AsyncStream`.
- Port *all* existing `RefresherTests` to the fake clock, rather than porting only the flaky ones or rewriting at engine level.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Packages/Engine/Package.swift` | Manifest: library `Engine`, depends on `Indicators`, `ClaudeUsage`, `PlatformStatus` |
| `Packages/Engine/Sources/Engine/TimeSource.swift` | The clock seam and its system implementation |
| `Packages/Engine/Sources/Engine/Refresher.swift` | Timer loop for one source (moved) |
| `Packages/Engine/Sources/Engine/IndicatorStore.swift` | Samples in, readings out (moved) |
| `Packages/Engine/Sources/Engine/PendingRefresh.swift` | What the menu's refresh row says (moved out of `MenuBuilder.swift`) |
| `Packages/Engine/Sources/Engine/EngineSettings.swift` | The settings value crossing the boundary |
| `Packages/Engine/Sources/Engine/Engine.swift` | Orchestration extracted from `AppDelegate` |
| `Packages/Engine/Tests/EngineTests/TestTimeSource.swift` | Virtual clock |
| `Packages/Engine/Tests/EngineTests/TestTimeSourceTests.swift` | Tests for the virtual clock itself |
| `Packages/Engine/Tests/EngineTests/Fakes.swift` | Scriptable HTTP/status/credential fakes and JSON literals |
| `Packages/Engine/Tests/EngineTests/RefresherTests.swift` | Moved, ported to `TestTimeSource` |
| `Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift` | Moved, import-only change |
| `Packages/Engine/Tests/EngineTests/EngineTests.swift` | New: the six compositions |
| `MonoCl/AppDelegate.swift` | AppKit wiring only |
| `MonoCl/Preferences.swift` | Maps to `EngineSettings`; floor re-homed |

---

### Task 1: Engine package skeleton and the TimeSource seam

**Goal:** A new `Packages/Engine` package containing `TimeSource`, `SystemTimeSource`, and a tested virtual `TestTimeSource`, wired into the Xcode project with no consumers yet.

**Files:**
- Create: `Packages/Engine/Package.swift`
- Create: `Packages/Engine/Sources/Engine/TimeSource.swift`
- Create: `Packages/Engine/Tests/EngineTests/TestTimeSource.swift`
- Create: `Packages/Engine/Tests/EngineTests/TestTimeSourceTests.swift`
- Modify: `project.yml` (add the package and the app target's dependency)

**Acceptance Criteria:**
- [ ] `swift build` and `swift test` succeed in `Packages/Engine`
- [ ] `TestTimeSource` wakes sleepers in deadline order, each observing `now` equal to its own deadline
- [ ] A cancelled sleep on `TestTimeSource` returns without any advance
- [ ] `xcodebuild -scheme MonoCl build` still succeeds after regenerating the project

**Verify:** `cd Packages/Engine && swift test > "$SCRATCH/engine-task1.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Create the package manifest**

`Packages/Engine/Package.swift` — mirrors the three existing manifests (swift-tools 6.3, macOS 26, language mode v6):

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Engine", targets: ["Engine"])],
    dependencies: [
        .package(path: "../Indicators"),
        .package(path: "../ClaudeUsage"),
        .package(path: "../PlatformStatus"),
    ],
    targets: [
        .target(
            name: "Engine",
            dependencies: [
                .product(name: "Indicators", package: "Indicators"),
                .product(name: "ClaudeUsage", package: "ClaudeUsage"),
                .product(name: "PlatformStatus", package: "PlatformStatus"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] **Step 2: Write the failing tests for the virtual clock**

`Packages/Engine/Tests/EngineTests/TestTimeSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import Engine

@MainActor
@Suite("Virtual clock")
struct TestTimeSourceTests {
    @Test("Sleepers wake in deadline order, each seeing its own deadline")
    func wakesInOrder() async {
        let time = TestTimeSource(now: origin)
        var observed: [Date] = []

        let first = Task { await time.sleep(for: 120, tolerance: 0); observed.append(time.now) }
        let second = Task { await time.sleep(for: 60, tolerance: 0); observed.append(time.now) }
        await Task.yield()

        await time.advance(by: 130)
        _ = await first.value
        _ = await second.value

        #expect(observed == [
            origin.addingTimeInterval(60),
            origin.addingTimeInterval(120),
        ])
        #expect(time.now == origin.addingTimeInterval(130))
    }

    @Test("A sleeper whose deadline is past the target stays asleep")
    func staysAsleep() async {
        let time = TestTimeSource(now: origin)
        var woke = false

        let sleeper = Task { await time.sleep(for: 600, tolerance: 0); woke = true }
        await Task.yield()

        await time.advance(by: 599)
        #expect(woke == false)
        #expect(time.now == origin.addingTimeInterval(599))

        sleeper.cancel()
        _ = await sleeper.value
    }

    @Test("Cancelling a sleep resumes it without advancing the clock")
    func cancellationResumes() async {
        let time = TestTimeSource(now: origin)
        let sleeper = Task { await time.sleep(for: 3600, tolerance: 0); return time.now }
        await Task.yield()

        sleeper.cancel()
        let observed = await sleeper.value

        #expect(observed == origin)
        #expect(time.now == origin)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Packages/Engine && swift test > "$SCRATCH/engine-task1-red.log" 2>&1; echo "exit=$?"`
Expected: non-zero exit; the log names `cannot find 'TestTimeSource' in scope`.

- [ ] **Step 4: Write `TimeSource` and `SystemTimeSource`**

`Packages/Engine/Sources/Engine/TimeSource.swift`:

```swift
import Foundation

/// The engine's only access to time.
///
/// Not `Swift.Clock`
/// ---
///
/// The engine needs wall-clock `Date` for `asOf` stamps, staleness
/// budgets, `Retry-After` deadlines and window resets.  `Swift.Clock`
/// deliberately supplies none of those, so a protocol of our own is
/// simpler than adapting one that measures a different thing.  The name
/// also avoids shadowing `Swift.Clock` at every use site.
@MainActor
public protocol TimeSource: AnyObject {
    var now: Date { get }

    /// Returns early — without throwing — when the calling task is
    /// cancelled, so callers guard on `Task.isCancelled` afterwards
    /// rather than catching.
    func sleep(for duration: TimeInterval, tolerance: TimeInterval) async
}

/// The real clock.
public final class SystemTimeSource: TimeSource {
    public init() {}

    public var now: Date { .now }

    public func sleep(for duration: TimeInterval, tolerance: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration), tolerance: .seconds(tolerance))
    }
}
```

- [ ] **Step 5: Write `TestTimeSource`**

`Packages/Engine/Tests/EngineTests/TestTimeSource.swift`:

```swift
import Foundation
@testable import Engine

/// A fixed origin, so every expectation in the suite is an offset from
/// a known instant rather than from whenever the tests happened to run.
/// 2026-08-31T12:00:00Z, chosen to sit before the reset timestamps in
/// the canned usage response.
let origin = Date(timeIntervalSince1970: 1_788_177_600)

/// Yields enough times for an engine tick — several awaits deep, across
/// the refresher's loop, the source's fetch and the store's apply — to
/// run to completion.
///
/// A single yield does not reliably carry it that far.  The count is a
/// bound, not a timing assumption: too few yields makes an assertion
/// fail loudly rather than pass on stale state, which is the failure
/// mode worth having.
@MainActor
func settle(_ times: Int = 20) async {
    for _ in 0..<times { await Task.yield() }
}

/// A clock that only moves when a test moves it.
///
/// `advance` walks stepwise rather than jumping: it stops at each due
/// deadline in turn so a loop that re-sleeps immediately registers its
/// next wait before the clock moves on.  A single jump would collapse
/// five minutes of one-minute ticks into one.
///
/// Tolerance is ignored — virtual time has nothing to coalesce with.
/// That is the only behavioural difference from `SystemTimeSource`.
@MainActor
final class TestTimeSource: TimeSource {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let resume: () -> Void
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    init(now: Date) { self.now = now }

    func sleep(for duration: TimeInterval, tolerance: TimeInterval) async {
        guard duration > 0 else { return }
        let id = nextID
        nextID += 1
        let deadline = now.addingTimeInterval(duration)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Cancelled before registering: resume here, and leave
                // nothing for `wake` to find.  Registering first would
                // strand the continuation, since the cancellation
                // handler has already run by this point.
                guard !Task.isCancelled else { return continuation.resume() }
                sleepers.append(Sleeper(id: id, deadline: deadline, resume: continuation.resume))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id: id) }
        }
    }

    /// Moves the clock forward, resuming every sleeper whose deadline it
    /// passes, in deadline order.
    func advance(by duration: TimeInterval) async {
        let target = now.addingTimeInterval(duration)
        while let next = sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) {
            now = next.deadline
            wake(id: next.id)
            // Lets the woken task run far enough to register its next
            // sleep before the clock moves past that sleep's deadline.
            // A woken refresher performs a whole fetch before sleeping
            // again, so one yield is not enough.
            await settle()
        }
        now = target
        await settle()
    }

    private func wake(id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).resume()
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Packages/Engine && swift test > "$SCRATCH/engine-task1.log" 2>&1; echo "exit=$?"`
Expected: exit=0, three tests passing.

- [ ] **Step 7: Wire the package into the Xcode project**

In `project.yml`, add to `packages:`:

```yaml
  Engine:
    path: Packages/Engine
```

and to the `MonoCl` target's `dependencies:`:

```yaml
      - package: Engine
```

Then regenerate and build:

```bash
xcodegen generate > "$SCRATCH/xcodegen.log" 2>&1; echo "exit=$?"
xcodebuild -scheme MonoCl -destination 'platform=macOS' build > "$SCRATCH/build-task1.log" 2>&1; echo "exit=$?"
```
Expected: exit=0 for both.

- [ ] **Step 8: Commit**

```bash
git add Packages/Engine project.yml MonoCl.xcodeproj
git commit -m "Add an Engine package with an injectable time source.

The engine's scheduling is only testable if time is, and the wall
clock the readings are stamped with is not something Swift.Clock
models.  TimeSource supplies both halves; TestTimeSource makes them
virtual."
```

---

### Task 2: Move Refresher into the package and onto the clock

**Goal:** `Refresher` lives in `Engine`, takes a `TimeSource`, and its entire suite passes against the virtual clock with no real waiting.

**Files:**
- Create: `Packages/Engine/Sources/Engine/Refresher.swift` (moved from `MonoCl/Refresher.swift`)
- Create: `Packages/Engine/Tests/EngineTests/RefresherTests.swift` (moved from `MonoClTests/RefresherTests.swift`)
- Delete: `MonoCl/Refresher.swift`, `MonoClTests/RefresherTests.swift`

**Acceptance Criteria:**
- [ ] All fifteen cases are present in the new file, asserting the same behaviour: ticking continues across repeated failures; consecutive failures lengthen the interval; a success resets the count; `refreshNow` clears the count and restarts immediately; a burst of triggers produces one tick; a trigger inside the spacing is deferred not dropped; the spacing floors the scheduled cadence; a start announces the fetch it is about to make; a trigger inside the spacing reports a pending refresh; the pending refresh clears once the deferred tick lands; `stop` clears the pending refresh; the pending refresh lasts until the fetch returns; a second request cannot cancel the first one's fetch; a restart waits out a server's `Retry-After`; `stop` cancels the loop
- [ ] The new file contains no `Task.sleep` and no `Date.now`; waiting is `await time.advance(by:)` and `await waitForTicks(_:from:)`
- [ ] `swift test` in `Packages/Engine` passes
- [ ] `xcodebuild -scheme MonoCl build` fails only where `AppDelegate` constructs a `Refresher` without a `time:` argument, and is fixed in this task by passing `SystemTimeSource()`

**Verify:** `cd Packages/Engine && swift test --filter RefresherTests > "$SCRATCH/refresher.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Move the file and add the clock**

`git mv MonoCl/Refresher.swift Packages/Engine/Sources/Engine/Refresher.swift`, then apply exactly these changes and no others:

1. Update the leading path comment to `// Packages/Engine/Sources/Engine/Refresher.swift`.
2. Mark the type and its members public: `public final class Refresher`, `public private(set) var isRefreshPending`, `public init(...)`, `public func start()`, `public func stop()`, `public func refreshNow()`.
3. Add a stored `private let time: any TimeSource` and a `time:` parameter to `init`, placed after `minimumSpacing:`.
4. Replace every `.now` with `time.now` (three sites: `firstTickWait(now: .now)`, `self.spacingRemaining(now: .now)`, `self.lastTickAt = .now`).
5. Replace the sleep with the seam.

The initializer becomes:

```swift
    /// - Parameter tick: performs one fetch; returns whether it succeeded.
    public init(
        interval: @escaping () -> TimeInterval,
        minimumSpacing: TimeInterval,
        time: any TimeSource,
        retryAfter: @escaping () -> TimeInterval? = { nil },
        tick: @escaping () async -> Bool
    ) {
        self.interval = interval
        self.minimumSpacing = minimumSpacing
        self.time = time
        self.retryAfter = retryAfter
        self.tick = tick
    }
```

and the sleep inside `start()`'s loop becomes:

```swift
                if wait > 0 {
                    await self.time.sleep(for: wait, tolerance: wait * 0.1)
                    guard !Task.isCancelled else { return }
                }
```

The `Task.sleep` tolerance comment at the top of the file stays: it still explains why `SystemTimeSource` passes a tolerance at all.

- [ ] **Step 2: Move the tests and port them to the virtual clock**

`git mv MonoClTests/RefresherTests.swift Packages/Engine/Tests/EngineTests/RefresherTests.swift`, change `@testable import MonoCl` to `@testable import Engine`, then port each case mechanically:

- Delete `private let base: TimeInterval = 0.01` and pass real-world intervals instead (`{ 300 }`).
- Construct one `TestTimeSource(now: origin)` per test and pass it as `time:`.
- Replace every `try? await Task.sleep(for: .seconds(x))` with `await time.advance(by: y)`, where `y` is the real-world interval the old test was scaling down. A test that slept `base * 30` to let three ticks land at interval `base` advances by `3 * 300` with interval `{ 300 }`.
- Keep `TickSpy` and `waitForTicks(_:from:)` exactly as they are: they sequence ticks, not time.
- Where a tick body previously slept to stay in flight (`try? await Task.sleep(for: .seconds(0.2))`), have it await a continuation the test resumes instead, so "in flight" no longer depends on wall-clock duration:

```swift
    /// Holds a tick open until the test lets it finish, so "a fetch is
    /// in flight" is a fact the test controls rather than a duration it
    /// hopes is long enough.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
```

Worked example — the existing "ticking continues across repeated failures" case becomes:

```swift
    @Test("Ticking continues across repeated failures")
    func ticksAcrossFailures() async {
        let time = TestTimeSource(now: origin)
        let spy = TickSpy { false }
        let refresher = Refresher(
            interval: { 300 }, minimumSpacing: 0, time: time
        ) { await spy.tick() }

        refresher.start()
        await waitForTicks(1, from: spy.ticks)
        // Backoff doubles from 300: the next three ticks fall at
        // +300, +900 and +2100 from the first.
        await time.advance(by: 2100)
        await waitForTicks(3, from: spy.ticks)
        refresher.stop()

        #expect(spy.callCount == 4)
    }
```

Note the assertion tightens from `>= 4` to `== 4`: with a virtual clock the count is exact, and an exact count is what makes the test falsifiable.

- [ ] **Step 3: Run the ported suite**

Run: `cd Packages/Engine && swift test --filter RefresherTests > "$SCRATCH/refresher.log" 2>&1; echo "exit=$?"`
Expected: exit=0. Then `grep -c 'Task\.sleep\|Date\.now' Packages/Engine/Tests/EngineTests/RefresherTests.swift` → 0. (`time.now` is allowed and expected; the real clock is not.)

If a case hangs, the cause is almost always a `waitForTicks` for a tick whose deadline the test never advanced past. Print `time.now` at the point of the hang before changing production code.

- [ ] **Step 4: Keep the app building**

In `MonoCl/AppDelegate.swift`, add `import Engine` and pass the clock to both refreshers:

```swift
        usageRefresher = Refresher(
            interval: { [preferences] in preferences.refreshInterval },
            minimumSpacing: Preferences.minimumRefreshInterval,
            time: SystemTimeSource(),
            retryAfter: { [weak self] in self?.rateLimitRemaining(now: .now) }
        ) { [weak self] in
            await self?.pollUsage() ?? false
        }

        statusRefresher = Refresher(
            interval: { [preferences] in preferences.refreshInterval },
            minimumSpacing: Preferences.minimumRefreshInterval,
            time: SystemTimeSource()
        ) { [weak self] in
            await self?.pollStatus() ?? false
        }
```

Two instances is deliberate and temporary: Task 4 gives the engine one clock and hands it to both.

- [ ] **Step 5: Verify both suites**

```bash
cd Packages/Engine && swift test > "$SCRATCH/engine-task2.log" 2>&1; echo "exit=$?"; cd -
xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/app-task2.log" 2>&1; echo "exit=$?"
```
Expected: exit=0 for both.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Move Refresher into the Engine package.

Its tests scaled real intervals down to hundredths of a second and
waited for them; on a virtual clock they assert exact tick counts at
real cadences instead, and the suite stops paying for wall time."
```

---

### Task 3: Move IndicatorStore and PendingRefresh into the package

**Goal:** The store and the refresh-row policy live in `Engine`, with their tests, and the app builds against their public API.

**Files:**
- Create: `Packages/Engine/Sources/Engine/IndicatorStore.swift` (moved)
- Create: `Packages/Engine/Sources/Engine/PendingRefresh.swift` (extracted from `MonoCl/MenuBuilder.swift`)
- Create: `Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift` (moved)
- Modify: `MonoCl/MenuBuilder.swift`, `MonoClTests/MenuBuilderTests.swift`, `MonoCl/AppDelegate.swift`
- Delete: `MonoCl/IndicatorStore.swift`, `MonoClTests/IndicatorStoreTests.swift`

**Acceptance Criteria:**
- [ ] `IndicatorStore`'s public API is exactly: `init(thresholds:staleAfter:)`, the `session`/`week`/`platform`/`usageFailure`/`statusFailure`/`usagePollingStopped`/`isUsageRateLimited`/`states`/`sessionResetsAt`/`weekResetsAt` projections, the `thresholds`/`staleAfter` settables, `apply(_:)` ×2, `clearOnWake(now:)`, `retryUsage()`, `revalidate(now:)`, `nextTrustExpiry(now:)`
- [ ] `PendingRefresh` and `forMenu(rateLimited:refreshesOutstanding:)` are public and no longer declared in an AppKit-importing file
- [ ] `MenuBuilderTests` builds its stores through the public API, with no `@testable` reliance on `IndicatorStore`
- [ ] Both suites pass

**Verify:** `cd Packages/Engine && swift test > "$SCRATCH/engine-task3.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Move the store**

`git mv MonoCl/IndicatorStore.swift Packages/Engine/Sources/Engine/IndicatorStore.swift`. Add `public` to the class, its `init`, every `private(set) var` projection listed in the acceptance criteria, `thresholds`, `staleAfter`, both `apply` methods, `clearOnWake`, `retryUsage`, `revalidate`, `nextTrustExpiry`, `states`, `isUsageRateLimited`, and the `sessionResetsAt`/`weekResetsAt` extension. Leave `Self.noReading` internal — nothing outside the package reads it except `TooltipComposerTests`, which is handled in Step 4. Everything else stays private.

- [ ] **Step 2: Extract `PendingRefresh`**

Create `Packages/Engine/Sources/Engine/PendingRefresh.swift` holding the `enum PendingRefresh` declaration and its `forMenu` extension, moved verbatim from `MonoCl/MenuBuilder.swift` with `public` added to the enum, both cases, and `forMenu`. Delete both declarations from `MenuBuilder.swift`, which keeps `import AppKit` and gains `import Engine`.

- [ ] **Step 3: Move the store's tests**

`git mv MonoClTests/IndicatorStoreTests.swift Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift` and change `@testable import MonoCl` to `@testable import Engine`. No other edit: these tests already drive time through explicit `now:` arguments.

- [ ] **Step 4: Fix the app-target tests**

`MonoClTests/MenuBuilderTests.swift` and `MonoClTests/MenuBarIconTests.swift` gain `import Engine` and drop any reliance on internal store members. `MonoClTests/TooltipComposerTests.swift` references `IndicatorStore.noReading`; replace that reference with the literal it holds:

```swift
    /// Matches `IndicatorStore.noReading`, which is internal to Engine.
    /// The tooltip's contract is the text the user sees, so pinning the
    /// literal here is the assertion, not a workaround.
    private let noReading = "no recent reading"
```

- [ ] **Step 5: Run both suites**

```bash
cd Packages/Engine && swift test > "$SCRATCH/engine-task3.log" 2>&1; echo "exit=$?"; cd -
xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/app-task3.log" 2>&1; echo "exit=$?"
```
Expected: exit=0 for both. Inspect the logs for `✕`, `FAIL` and `error:`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Move the indicator store and refresh policy into Engine.

PendingRefresh was declared in the AppKit file that renders it, but
it is pure policy and the engine is what decides it, so it moves with
the store rather than with the menu."
```

---

### Task 4: Extract the Engine and reduce AppDelegate to wiring

**Goal:** `Engine` owns the poll cycle, the `Retry-After` deadline, the expiry timer, wake handling and the pending-refresh policy; `AppDelegate` only builds AppKit objects and forwards events.

**Files:**
- Create: `Packages/Engine/Sources/Engine/EngineSettings.swift`
- Create: `Packages/Engine/Sources/Engine/Engine.swift`
- Modify: `MonoCl/AppDelegate.swift` (rewritten)

**Acceptance Criteria:**
- [ ] `AppDelegate` contains no `Refresher`, no `rateLimitedUntil`, no `expiryTask`, no `pollUsage`/`pollStatus`, and no `PendingRefresh.forMenu` call
- [ ] `Engine` exposes exactly `store`, `start()`, `stop()`, `refreshNow()`, `retryUsage()`, `settingsChanged()`, `systemDidWake()`, `menuWillOpen()`, `pendingRefresh`
- [ ] Both refreshers share one `TimeSource` instance
- [ ] The app builds and both suites pass
- [ ] A launched app still shows three dots and a menu whose rows read as before

**Verify:** `xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/app-task4.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Write `EngineSettings`**

`Packages/Engine/Sources/Engine/EngineSettings.swift`:

```swift
import Foundation
import Indicators

/// Everything the engine needs from the user's preferences, as one
/// value.
///
/// One value rather than three closures: thresholds, cadence and the
/// staleness budget are read together on every revalidation, and a
/// single read cannot observe a half-applied pair.
public struct EngineSettings: Equatable, Sendable {
    /// The shortest cadence the user may choose, and the floor
    /// `Refresher` applies to every request it makes.  Chosen for the
    /// endpoint's sake rather than the display's: the windows being
    /// reported span five hours and seven days, so a minute is already
    /// finer resolution than the data has.
    public static let minimumRefreshInterval: TimeInterval = 60

    public let thresholds: Thresholds
    public let refreshInterval: TimeInterval
    public let staleAfter: TimeInterval

    public init(thresholds: Thresholds, refreshInterval: TimeInterval, staleAfter: TimeInterval) {
        self.thresholds = thresholds
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter
    }
}
```

- [ ] **Step 2: Write `Engine`**

`Packages/Engine/Sources/Engine/Engine.swift`. Every comment below is carried over from `AppDelegate`, where it already explains this code:

```swift
import ClaudeUsage
import Foundation
import Indicators
import PlatformStatus

/// Drives MonoCl's state: polls both sources, applies what comes back,
/// re-derives the readings, and says when something changed.
///
/// Knows nothing about how any of it is drawn.  `onChange` is a
/// notification, not a payload — the UI samples `store` when it fires.
@MainActor
public final class Engine {
    public let store: IndicatorStore

    private let usage: UsageSource
    private let status: PlatformStatusSource
    private let settings: () -> EngineSettings
    private let time: any TimeSource
    private let onChange: () -> Void

    private var usageRefresher: Refresher?
    private var statusRefresher: Refresher?

    /// When the endpoint's last `Retry-After` elapses, held as an
    /// instant rather than a duration.  Scheduling only: what the MENU
    /// says about a rate limit comes from `store.isUsageRateLimited`,
    /// because a 429 need not supply a deadline at all.  Every trigger
    /// restarts the poller, and a duration would be re-armed in full
    /// each time: a menu opened every few minutes during a 15-minute
    /// `Retry-After` would push the deadline out indefinitely, and a
    /// wake after hours asleep would wait the whole period again before
    /// the fetch that matters most.
    private var rateLimitedUntil: Date?

    /// Fires once a retained reading's trust would otherwise lapse
    /// unnoticed.  Independent of `Refresher`'s cadence on purpose: that
    /// cadence stretches to the 15-minute backoff cap, and folding this
    /// in would defeat the backoff's whole purpose.
    private var expiryTask: Task<Void, Never>?

    public init(
        usage: UsageSource,
        status: PlatformStatusSource,
        settings: @escaping () -> EngineSettings,
        time: any TimeSource = SystemTimeSource(),
        onChange: @escaping () -> Void
    ) {
        self.usage = usage
        self.status = status
        self.settings = settings
        self.time = time
        self.onChange = onChange
        let initial = settings()
        store = IndicatorStore(thresholds: initial.thresholds, staleAfter: initial.staleAfter)
    }

    // MARK: - Lifecycle

    public func start() {
        stop()

        let usageRefresher = Refresher(
            interval: { [settings] in settings().refreshInterval },
            minimumSpacing: EngineSettings.minimumRefreshInterval,
            time: time,
            retryAfter: { [weak self] in
                guard let self else { return nil }
                return self.rateLimitRemaining(now: self.time.now)
            }
        ) { [weak self] in
            await self?.pollUsage() ?? false
        }

        let statusRefresher = Refresher(
            interval: { [settings] in settings().refreshInterval },
            minimumSpacing: EngineSettings.minimumRefreshInterval,
            time: time
        ) { [weak self] in
            await self?.pollStatus() ?? false
        }

        self.usageRefresher = usageRefresher
        self.statusRefresher = statusRefresher
        usageRefresher.start()
        statusRefresher.start()
        refreshState()
    }

    /// Stops both pollers and the expiry timer.  The app never calls
    /// this — it only ever exits — but a test that leaves a poller
    /// running leaks it into the next test.
    public func stop() {
        usageRefresher?.stop()
        statusRefresher?.stop()
        usageRefresher = nil
        statusRefresher = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    // MARK: - Triggers

    public func refreshNow() {
        usageRefresher?.refreshNow()
        statusRefresher?.refreshNow()
        refreshState()
    }

    public func retryUsage() {
        store.retryUsage()
        usageRefresher?.refreshNow()
        refreshState()
    }

    public func settingsChanged() { refreshState() }

    public func systemDidWake() {
        // The held reading may describe a moment hours ago.
        store.clearOnWake(now: time.now)
        // Refreshed before the state is published, as at the other
        // deliberate call sites: the refreshes are what set the pending
        // state the UI displays.
        usageRefresher?.refreshNow()
        statusRefresher?.refreshNow()
        refreshState()
    }

    /// Re-derives before the menu is shown: the held reading may have
    /// crossed its staleness budget since the last poll, and the
    /// staleness rule is what keeps the displayed value honest.
    ///
    /// Opening the menu deliberately does NOT fetch.  It is how the user
    /// reaches Quit and Settings, so a fetch here would put the request
    /// rate in the hands of a gesture made for unrelated reasons — up to
    /// one request a minute against a five-minute cadence.  A user who
    /// wants a fresh number has "Refresh now" one click away.
    public func menuWillOpen() { refreshState() }

    /// The menu carries one refresh command for two pollers, so it needs
    /// one answer, and ANY poller waiting takes the command away.
    ///
    /// The alternative — keeping the command while either poller could
    /// still act — was tried and is worse.  Only usage is ever rate
    /// limited, so for the hour a `Retry-After` can last, that rule
    /// leaves a live "Refresh now" that cannot move the two rows the
    /// user came to read.  It would still refresh the platform row, so
    /// it is a partial command rather than a dead one, but partial in
    /// exactly the half nobody opened the menu for.
    ///
    /// The cost of this rule is that platform status cannot be refreshed
    /// BY HAND while usage is rate limited.  It keeps polling on its own
    /// cadence throughout, so nothing goes stale; only the button is
    /// unavailable, and only until usage next gets an answer that is not
    /// a refusal.
    public var pendingRefresh: PendingRefresh? {
        PendingRefresh.forMenu(
            rateLimited: store.isUsageRateLimited,
            refreshesOutstanding: [
                usageRefresher?.isRefreshPending == true,
                statusRefresher?.isRefreshPending == true,
            ]
        )
    }

    // MARK: - Polling

    private func pollUsage() async -> Bool {
        guard !store.usagePollingStopped else { return true }
        let outcome = await usage.fetch(now: time.now)
        if case let .failure(.rateLimited(retryAfter)) = outcome {
            rateLimitedUntil = retryAfter.map { time.now.addingTimeInterval($0) }
        } else {
            rateLimitedUntil = nil
        }
        store.apply(outcome)
        refreshState()
        if case .samples = outcome { return true }
        return false
    }

    private func pollStatus() async -> Bool {
        let outcome = await status.fetch(now: time.now)
        store.apply(outcome)
        refreshState()
        if case .sample = outcome { return true }
        return false
    }

    private func rateLimitRemaining(now: Date) -> TimeInterval? {
        guard let rateLimitedUntil else { return nil }
        let remaining = rateLimitedUntil.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Derivation

    /// Applies the current settings, re-derives the readings, re-arms
    /// the expiry timer, and announces the change.  Settings are applied
    /// here rather than at poll time so moving a threshold updates the
    /// lights immediately.
    private func refreshState() {
        let current = settings()
        store.thresholds = current.thresholds
        store.staleAfter = current.staleAfter
        store.revalidate(now: time.now)
        armExpiryTimer()
        onChange()
    }

    /// Cancels and re-arms the expiry timer for the earliest instant any
    /// currently-trusted reading stops being trusted.  A retained
    /// reading can outlive the poll that produced it, so nothing else
    /// would re-derive it before the next poll — which, under backoff,
    /// may be up to 15 minutes away.
    private func armExpiryTimer() {
        expiryTask?.cancel()
        expiryTask = nil
        let now = time.now
        guard let expiry = store.nextTrustExpiry(now: now), expiry > now else { return }
        let wait = expiry.timeIntervalSince(now)
        expiryTask = Task { [weak self] in
            guard let self else { return }
            await self.time.sleep(for: wait, tolerance: wait * 0.1)
            guard !Task.isCancelled else { return }
            self.refreshState()
        }
    }
}
```

- [ ] **Step 3: Rewrite `AppDelegate`**

`MonoCl/AppDelegate.swift` in full:

```swift
import AppKit
import ClaudeUsage
import Engine
import Indicators
import PlatformStatus

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preferences = Preferences()

    private lazy var engine = Engine(
        usage: UsageSource(
            credentials: resolvedCredentialReader(),
            http: EphemeralHTTPFetcher()
        ),
        status: PlatformStatusSource(),
        settings: { [preferences] in
            EngineSettings(
                thresholds: preferences.thresholds,
                refreshInterval: preferences.refreshInterval,
                staleAfter: preferences.staleAfter
            )
        },
        onChange: { [weak self] in self?.render() }
    )

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonoCl"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        observeSystemNotifications()
        engine.start()
    }

    // MARK: - Rendering

    private func render() {
        renderIcon()
        renderMenu()
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        let spec = iconSpec(
            for: engine.store.states,
            differentiateWithoutColor: NSWorkspace.shared
                .accessibilityDisplayShouldDifferentiateWithoutColor
        )
        button.image = MenuBarIcon.image(for: spec, appearance: button.effectiveAppearance)
        button.toolTip = TooltipComposer.tooltip(
            session: engine.store.session,
            week: engine.store.week,
            platform: engine.store.platform,
            sessionResetsAt: engine.store.sessionResetsAt,
            weekResetsAt: engine.store.weekResetsAt
        )
    }

    /// Rebuilds the menu's items in place rather than reassigning
    /// `statusItem.menu`: this avoids reassigning it from inside the
    /// menu's own delegate callback (`menuNeedsUpdate(_:)`). Populating
    /// items does not re-fire `menuNeedsUpdate`, so there is no
    /// recursion.
    private func renderMenu() {
        guard let menu = statusItem?.menu else { return }
        MenuBuilder.populate(
            menu,
            store: engine.store,
            target: self,
            actions: .init(
                refresh: #selector(refreshNow),
                retry: #selector(retryUsage),
                openSettings: #selector(openSettings),
                quit: #selector(quit)
            ),
            refreshPending: engine.pendingRefresh
        )
    }

    func settingsChanged() { engine.settingsChanged() }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.menuWillOpen()
    }

    // MARK: - System notifications

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.systemDidWake() }
        }

        center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Nothing about the readings changed — only how they are
            // drawn — so this never reaches the engine.
            MainActor.assumeIsolated { self?.renderIcon() }
        }
    }

    // MARK: - Menu actions

    @objc private func refreshNow() { engine.refreshNow() }

    @objc private func retryUsage() { engine.retryUsage() }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 4: Verify the build and both suites**

```bash
cd Packages/Engine && swift test > "$SCRATCH/engine-task4.log" 2>&1; echo "exit=$?"; cd -
xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/app-task4.log" 2>&1; echo "exit=$?"
```
Expected: exit=0 for both. Inspect for `✕`, `FAIL`, `error:`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Extract the engine from AppDelegate.

The poll cycle, the Retry-After deadline, the expiry timer and the
pending-refresh policy were only reachable by launching the app,
because they lived in a class that grabs the status bar on init.  They
are the same code in a place a test can construct."
```

---

### Task 5: Cover the compositions that needed a running app

**Goal:** Six engine tests, each pinning a behaviour previously verified only by watching a menu bar.

**Files:**
- Create: `Packages/Engine/Tests/EngineTests/Fakes.swift`
- Create: `Packages/Engine/Tests/EngineTests/EngineTests.swift`

**Acceptance Criteria:**
- [ ] All six tests pass, and each fails when the behaviour it names is removed
- [ ] No test waits on wall-clock time; all timing is `await time.advance(by:)`
- [ ] Every test stops its engine before returning
- [ ] Assertions state the expected value, never the absence of an unwanted one

**Verify:** `cd Packages/Engine && swift test --filter EngineTests > "$SCRATCH/engine-tests.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Write the fakes**

`Packages/Engine/Tests/EngineTests/Fakes.swift`. These are scriptable — a queue of outcomes, not one fixed outcome — because every test here spans several fetches:

```swift
import ClaudeUsage
import Foundation
import PlatformStatus

/// A transport that answers from a script and counts its calls.
///
/// The last entry repeats once the script runs out, so a test states
/// only the answers it cares about and the loop can keep polling.
final class ScriptedHTTP: HTTPFetching, @unchecked Sendable {
    enum Answer {
        case response(status: Int, body: String, retryAfter: TimeInterval?)
        case offline
    }

    private let answers: [Answer]
    private(set) var callCount = 0

    init(_ answers: [Answer]) {
        precondition(!answers.isEmpty, "a script needs at least one answer")
        self.answers = answers
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult {
        let answer = answers[min(callCount, answers.count - 1)]
        callCount += 1
        switch answer {
        case let .response(status, body, retryAfter):
            return HTTPResult(status: status, body: Data(body.utf8), retryAfter: retryAfter)
        case .offline:
            throw URLError(.notConnectedToInternet)
        }
    }
}

final class ScriptedStatusFetcher: StatusFetching, @unchecked Sendable {
    private let body: String
    private(set) var callCount = 0

    init(body: String = statusBody) { self.body = body }

    func get(_ url: URL) async throws -> (Data, Int) {
        callCount += 1
        return (Data(body.utf8), 200)
    }
}

/// Supplies a credential, or the error the keychain would have raised.
final class StubCredentials: CredentialReading, @unchecked Sendable {
    private let result: Result<StoredCredential, CredentialError>

    init(_ result: Result<StoredCredential, CredentialError>) { self.result = result }

    func read() throws -> StoredCredential { try result.get() }
}

/// `StoredCredential` is deliberately decode-only, so a test builds one
/// the way the keychain does.
func storedCredential(expiresAt: Date) throws -> StoredCredential {
    let seconds = Int(expiresAt.timeIntervalSince1970)
    return try JSONDecoder().decode(
        StoredCredential.self,
        from: Data(#"{"accessToken":"t","expiresAt":\#(seconds)}"#.utf8)
    )
}

/// Session 47%, week 62%, both windows resetting well after `origin`.
let usageBody = """
{
  "five_hour": { "utilization": 47.0, "resets_at": "2026-08-31T17:50:00.568709+00:00" },
  "seven_day": { "utilization": 62.0, "resets_at": "2026-09-04T15:00:00.568730+00:00" }
}
"""

let statusBody = #"{ "status": { "indicator": "none", "description": "All Systems Operational" } }"#

/// Matches the app's own defaults, so these tests exercise the cadence
/// and budget MonoCl actually ships with.
let defaultSettings = EngineSettings(
    thresholds: .default,
    refreshInterval: 300,
    staleAfter: 900
)
```

- [ ] **Step 2: Write the six tests**

`Packages/Engine/Tests/EngineTests/EngineTests.swift`:

```swift
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
        credentials: Result<StoredCredential, CredentialError>? = nil,
        settings: EngineSettings = defaultSettings,
        time: TestTimeSource,
        onChange: @escaping () -> Void = {}
    ) throws -> Engine {
        let resolved = try credentials ?? .success(
            storedCredential(expiresAt: origin.addingTimeInterval(86_400))
        )
        return Engine(
            usage: UsageSource(credentials: StubCredentials(resolved), http: usage),
            status: PlatformStatusSource(http: status),
            settings: { settings },
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
        #expect(http.callCount == 1)
        #expect(engine.store.isUsageRateLimited == true)

        await time.advance(by: 899)
        #expect(http.callCount == 1)

        await time.advance(by: 2)
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
        var changes = 0
        let engine = try makeEngine(usage: http, time: time) { changes += 1 }
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        #expect(engine.store.session.state == .nominal)

        // The next poll fails and the sample is retained, so the lights
        // stay lit until the budget itself runs out at +900.
        await time.advance(by: 300)
        #expect(engine.store.session.detail == "47%")
        #expect(engine.store.session.note == "Offline")

        let fetchesBefore = http.callCount
        let changesBefore = changes
        await time.advance(by: 600)

        #expect(engine.store.session.state == .unknown)
        #expect(engine.store.session.detail == "Offline")
        #expect(engine.store.week.state == .unknown)
        // The expiry timer, not a poll, is what re-derived: the cadence
        // has stretched under backoff past this instant.
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
        #expect(engine.store.session.state == .nominal)

        engine.systemDidWake()
        #expect(engine.store.states == [.unknown, .unknown, .unknown])
        #expect(engine.pendingRefresh == .refreshing)

        // The spacing floor is 60s, and the last tick was at `origin`.
        await time.advance(by: 60)
        #expect(engine.store.session.detail == "47%")
        #expect(engine.pendingRefresh == nil)
    }

    @Test("A denied keychain stops usage polling until a retry")
    func stickyFailureStopsPolling() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([.response(status: 200, body: usageBody, retryAfter: nil)])
        let engine = try makeEngine(
            usage: http, credentials: .failure(.accessDenied), time: time
        )
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
        #expect(engine.store.usagePollingStopped == true)
        #expect(engine.store.session.detail == "Keychain access denied")

        // The transport is never reached while polling is stopped: the
        // credential read fails first, and the loop returns early.
        await time.advance(by: 3600)
        #expect(http.callCount == 0)
    }

    @Test("A threshold edit re-derives the lights without fetching")
    func settingsChangeRederivesWithoutFetching() async throws {
        let time = TestTimeSource(now: origin)
        let http = ScriptedHTTP([.response(status: 200, body: usageBody, retryAfter: nil)])
        var settings = defaultSettings
        let engine = Engine(
            usage: UsageSource(
                credentials: StubCredentials(
                    .success(try storedCredential(expiresAt: origin.addingTimeInterval(86_400)))
                ),
                http: http
            ),
            status: PlatformStatusSource(http: ScriptedStatusFetcher()),
            settings: { settings },
            time: time,
            onChange: {}
        )
        defer { engine.stop() }

        engine.start()
        await time.advance(by: 0)
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

        await time.advance(by: 0)
        #expect(engine.pendingRefresh == .rateLimited)
    }
}
```

- [ ] **Step 3: Run the suite**

Run: `cd Packages/Engine && swift test --filter EngineTests > "$SCRATCH/engine-tests.log" 2>&1; echo "exit=$?"`
Expected: exit=0, six tests passing.

If `honoursRetryAfter` reports `statusHTTP.callCount == 3`, the status poller's fourth tick landed exactly on the advance boundary; advance by 2 rather than 1 past the deadline and re-check, but confirm the cadence is still 300s before adjusting the expectation — a changed cadence is a defect, not a test to relax.

- [ ] **Step 4: Prove each test can fail**

For each of the six, make the named behaviour absent, confirm the test fails, then revert. Capture the failing run each time.

| Test | Temporary break |
|---|---|
| `honoursRetryAfter` | delete the `retryAfter:` argument from the usage `Refresher` |
| `retainedReadingExpires` | make `armExpiryTimer` return immediately |
| `wakeClearsAndRefetches` | drop `store.clearOnWake` from `systemDidWake` |
| `stickyFailureStopsPolling` | drop the `usagePollingStopped` guard in `pollUsage` |
| `settingsChangeRederivesWithoutFetching` | stop applying `current.thresholds` in `refreshState` |
| `pendingRefreshPolicy` | pass `rateLimited: false` to `PendingRefresh.forMenu` |

```bash
cd Packages/Engine && swift test --filter EngineTests > "$SCRATCH/falsify-<name>.log" 2>&1; echo "exit=$?"
```
Expected each time: non-zero exit naming that test. Revert before the next.

- [ ] **Step 5: Commit**

```bash
git add Packages/Engine/Tests/EngineTests
git commit -m "Test the behaviours that needed a running app.

Each of these was previously an acceptance criterion verified by
watching the menu bar for three minutes; on a virtual clock the same
facts are asserted in milliseconds."
```

---

### Task 6: Re-home the refresh floor and retarget stale comments

**Goal:** No duplicate declaration of the minimum interval, and no comment left describing code that now lives elsewhere.

**Files:**
- Modify: `MonoCl/Preferences.swift`
- Modify: `MonoClTests/PreferencesTests.swift` (only if it names `Preferences.minimumRefreshInterval`)
- Modify: `DEFERRED.md`

**Acceptance Criteria:**
- [ ] `minimumRefreshInterval` is declared once, on `EngineSettings`
- [ ] `Preferences` clamps against `EngineSettings.minimumRefreshInterval`
- [ ] `grep -rn "minimumRefreshInterval" MonoCl MonoClTests` shows only uses, no second declaration
- [ ] Both suites pass

**Verify:** `grep -rn "static let minimumRefreshInterval" MonoCl Packages | wc -l` → 1

**Steps:**

- [ ] **Step 1: Re-home the constant**

In `MonoCl/Preferences.swift`, add `import Engine`, delete the `static let minimumRefreshInterval` declaration and its doc comment (both now live on `EngineSettings`), and change the two clamps:

```swift
    var refreshInterval: TimeInterval {
        get { max(defaults.double(forKey: Key.refreshInterval), EngineSettings.minimumRefreshInterval) }
        set { defaults.set(max(newValue, EngineSettings.minimumRefreshInterval), forKey: Key.refreshInterval) }
    }
```

- [ ] **Step 2: Update any test that named it**

```bash
grep -rn "minimumRefreshInterval" MonoClTests
```
Replace `Preferences.minimumRefreshInterval` with `EngineSettings.minimumRefreshInterval` and add `import Engine` where needed. If the grep is empty, skip.

- [ ] **Step 3: Record the scheme's narrowed role**

Append to `DEFERRED.md`, following the existing entry format and numbering (continue from the last entry's number):

```markdown
## N. Revisit the test host's fake credential

**Deferred:** removing `MONOCL_FAKE_CREDENTIAL: not-found` from the
`MonoCl` scheme.

The test bundle is hosted by the app, so `xcodebuild test` launches
MonoCl and `applicationDidFinishLaunching` runs before any test does.
The environment variable is what stops that launch reading a real
credential. Extracting the engine did not change this: it moved the
behaviour worth testing into `Packages/Engine`, where `swift test`
needs no host at all, so the variable now protects only the remaining
app-target tests.

**Why deferring is acceptable:** the variable costs one line and
misleads nobody, and the app-target tests it protects still run under
the host.

**What to build:** a test target that does not use the app as its host,
if the app-target suite ever shrinks to renderers alone.

**Trigger:** the next time the scheme's environment block is edited for
any other reason.
```

- [ ] **Step 4: Format, lint and verify**

```bash
cd Packages/Engine && swift test > "$SCRATCH/engine-task6.log" 2>&1; echo "exit=$?"; cd -
xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/app-task6.log" 2>&1; echo "exit=$?"
```
Expected: exit=0 for both.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Re-home the refresh floor onto EngineSettings.

Refresher enforces the floor and now lives in the package, so the
constant belongs beside it rather than on the app's preferences, which
merely clamp against it."
```

---

### Task 7: Verify the extracted engine against the real app

**Goal:** Confirm the running app behaves exactly as it did before the extraction, on the axes no headless test covers.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `docs/superpowers/plans/2026-08-31-engine-extraction.verification.md`

**Acceptance Criteria:**
- [ ] The built app launches and shows three dots, with the two usage dots reading real percentages that match `/usage` in Claude Code to within one poll interval
- [ ] The Platform row matches the headline on status.claude.com
- [ ] Over ten minutes at the default 300 s cadence, the usage endpoint is requested no more than three times — confirmed from `log show`, not inferred
- [ ] Lowering the warning threshold below the current session percentage turns the session dot amber immediately, without a fetch
- [ ] Sleeping and waking the Mac blanks the dots until the next successful fetch
- [ ] No access token appears in `log show --predicate 'subsystem == "net.sinistral.monocl"'`
- [ ] Observations are recorded in the verification document

**Verify:** `log show --last 10m --predicate 'subsystem == "net.sinistral.monocl"' > "$SCRATCH/monocl-log.txt" 2>&1; grep -c -i -E 'sk-ant|Bearer|accessToken' "$SCRATCH/monocl-log.txt"` → 0

**Steps:**

- [ ] **Step 1: Build and launch the real app**

```bash
xcodebuild -scheme MonoCl -destination 'platform=macOS' -configuration Debug build > "$SCRATCH/build-final.log" 2>&1; echo "exit=$?"
grep -m1 'BUILT_PRODUCTS_DIR' "$SCRATCH/build-final.log"
```
Launch the built `MonoCl.app` and answer the keychain dialog with Always Allow.

- [ ] **Step 2: Compare the readings against their sources**

Record, in the verification document, the tooltip's Session and Week percentages beside the figures `/usage` reports in Claude Code, and the Platform row beside the headline on status.claude.com.

- [ ] **Step 3: Check the request cadence**

Leave the app alone for ten minutes, then:

```bash
log show --last 10m --predicate 'subsystem == "net.sinistral.monocl"' > "$SCRATCH/monocl-log.txt" 2>&1
grep -c -i -E 'sk-ant|Bearer|accessToken' "$SCRATCH/monocl-log.txt"
```
Expected: `0`. Record the observed request count from the log in the document.

- [ ] **Step 4: Exercise the two live behaviours**

Lower the warning threshold in Settings below the current session percentage and record whether the dot changes colour before the next poll. Then sleep the Mac, wake it, and record what the dots show immediately after waking and after the first fetch lands.

- [ ] **Step 5: Write the verification document and commit**

Record each observation with what was expected and what was seen, then:

```bash
git add docs/superpowers/plans/2026-08-31-engine-extraction.verification.md
git commit -m "Record the engine extraction's live verification."
```

```json:metadata
{"files": ["docs/superpowers/plans/2026-08-31-engine-extraction.verification.md"], "verifyCommand": "log show --last 10m --predicate 'subsystem == \"net.sinistral.monocl\"' > \"$SCRATCH/monocl-log.txt\" 2>&1; grep -c -i -E 'sk-ant|Bearer|accessToken' \"$SCRATCH/monocl-log.txt\"", "acceptanceCriteria": ["three dots, usage percentages match /usage within one poll interval", "Platform row matches status.claude.com headline", "no more than three usage requests in ten minutes, from log show", "threshold edit turns the dot amber immediately without a fetch", "sleep and wake blanks the dots until the next successful fetch", "no access token in the log", "observations recorded in the verification document"], "modelTier": "frontier", "userGate": true, "tags": ["user-gate"], "requiresUserSpecification": false, "gateScope": "all", "failurePolicy": "halt"}
```

---

## Notes for the executor

- **The spec is the argument; this plan is the procedure.** Read `docs/superpowers/specs/2026-08-31-engine-extraction-design.md` first — several steps here say "moved verbatim", and the spec explains why each piece belongs where it now goes.
- **Comments move with their code.** Every doc comment quoted in Task 4 already exists in `AppDelegate` today. Do not rewrite them; they encode decisions the code alone does not.
- **If a moved test fails, suspect the move.** These tests passed before the extraction. A red one after it means the port dropped something, not that the old behaviour was wrong.
