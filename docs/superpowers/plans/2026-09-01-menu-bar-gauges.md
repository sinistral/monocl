# Menu Bar Gauges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three state-only dots with two percentage gauges and a platform dot — session as an outer ring, week as an inner pie, both sweeping clockwise from twelve — so the menu bar reports magnitude rather than only which of four states each indicator is in.

**Architecture:** `Reading` gains the `percent` that `IndicatorStore` currently discards. `IconSpec` stops being a list of interchangeable dots and becomes three named parts — two `GaugeSpec`s and a `DotSpec` — because the three are now drawn three different ways. `MenuBarIcon` draws arcs, a wedge, and radial slots cut as alpha. The `differentiateWithoutColor` plumbing goes: the slots are unconditional.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency complete), swift-tools 6.3, macOS 26, AppKit (`NSBezierPath`, `NSImage(size:flipped:drawingHandler:)`), Swift Testing (`@Test`/`#expect`), XcodeGen, SwiftPM local packages.

**Spec:** `docs/superpowers/specs/2026-09-01-menu-bar-gauges-design.md`

## Global Constraints

- **Set `SCRATCH` before starting** to this session's scratchpad directory, and redirect every suite's output into it (`> "$SCRATCH/name.log" 2>&1; echo "exit=$?"`). Never pipe a live run through `grep`/`head`/`tail` as the only record — integration runs are expensive enough that a second one is a real cost.
- **No source, rule or policy changes.** What MonoCl fetches, how often, and how it decides thresholds and staleness are all out of scope. `IndicatorState` keeps its four cases; `Thresholds` keeps its inclusive comparisons.
- **Exact geometry.** Glyph box 20 pt; session ring 3 pt stroke on a 8.5 pt centreline radius; week pie 5.5 pt radius; platform dot 6 pt to the right of the glyph box, 3 pt ring radius / 4 pt disc radius; 2 pt inset each side; total width exactly 34 pt. Height always from `NSStatusBar.system.thickness`, never hardcoded.
- **Both gauges sweep clockwise from twelve o'clock.** This is the clock metaphor the layout rests on and it must not be mirrored, in any locale.
- **Breach slots are cut as alpha** (`compositingOperation = .clear`), never painted in a background colour. The menu bar's background is the user's wallpaper.
- Swift 6 language mode, strict concurrency complete. `Indicators` stays free of AppKit types — it must remain testable without a screen.
- Tests: affirmative assertions about the specific expected value, never assertions about the absence of an unwanted one.
- Comments follow the repo's existing style: UK English, sentence-case headings with `---` underlining, motivation not restatement.
- Commit subjects end with a period; no conventional-commit prefixes; body wrapped at 72 columns.
- **Spec changes commit alone.** Any commit touching `docs/superpowers/specs/` contains nothing else.

**User decisions (already made):**
- "F1s" — continuous sweeps, not eighths. Quantizing a solid wedge is invisible to the reader and only costs accuracy.
- "S1 and S2 are just too busy/cluttered" — no permanent tick furniture on the gauges. Marks appear only on breach.
- "I propose session on the outer (long 'minute' hand), week on on inner (short 'hour' hand)."
- "R1" — session as the outer 3 pt ring, week as the full-size inner pie. Position follows consultation frequency; visual mass follows severity.
- "N2 with refinement" — the breach cue is a count of slots (one at warning, two at critical), cut at fixed angles a few degrees inside the thresholds rather than at the arc's leading edge.

---

## File Structure

| Path | Responsibility | Change |
|---|---|---|
| `Packages/Indicators/Sources/Indicators/Reading.swift` | One resolved value ready for display | Gains `percent` |
| `Packages/Indicators/Sources/Indicators/IconSpec.swift` | The drawable specification and the mapping onto it | Rewritten: `GaugeSpec`, named `IconSpec` fields, `DotSpec.breachMarks`, `.notched` removed |
| `Packages/Engine/Sources/Engine/IndicatorStore.swift` | Samples in, readings out | Writes `percent`; loses `states` |
| `MonoCl/MenuBarIcon.swift` | Turns a specification into an `NSImage` | Rewritten: arcs, wedge, alpha slots |
| `MonoCl/AppDelegate.swift` | Composition root and render trigger | New `iconSpec` call; accessibility observer removed |

Test files mirror these one for one. No new files are created, so `xcodegen generate` is not required by this plan — the `MonoCl` target's `sources` is a directory glob and no file enters or leaves it.

---

## Task 1: Carry the percentage forward

**Goal:** `Reading` carries the utilisation percentage the renderer will need, and `IndicatorStore` populates it for trusted usage readings only.

**Files:**
- Modify: `Packages/Indicators/Sources/Indicators/Reading.swift`
- Modify: `Packages/Engine/Sources/Engine/IndicatorStore.swift:123-136`
- Test: `Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift`

**Acceptance Criteria:**
- [ ] A trusted usage reading's `percent` equals the sample's percentage
- [ ] A reading that fails the trust check has `percent == nil`, not zero
- [ ] The platform reading has `percent == nil`
- [ ] `swift test` passes in `Packages/Indicators` and `Packages/Engine`
- [ ] `xcodebuild -scheme MonoCl test` still passes — this task is additive and breaks no caller

**Verify:** `cd Packages/Engine && swift test > "$SCRATCH/gauges-task1.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Write the failing tests**

Add to `Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift`, inside the existing `IndicatorStoreTests` suite (it already has `now`, `store(thresholds:staleAfter:)` and `samples(...)` helpers):

```swift
    @Test("A trusted usage reading carries its percentage")
    func usageReadingCarriesPercent() {
        let s = store()
        s.apply(samples(session: 76, week: 20))
        s.revalidate(now: now)
        #expect(s.session.percent == 76)
        #expect(s.week.percent == 20)
    }

    @Test("A reading MonoCl cannot vouch for carries no percentage")
    func untrustedReadingHasNoPercent() {
        let s = store(staleAfter: 300)
        s.apply(samples(session: 76))
        s.revalidate(now: now.addingTimeInterval(301))
        // Nil rather than zero: "cannot vouch for it" and "none used"
        // are different pictures, and the renderer draws them
        // differently.
        #expect(s.session.state == .unknown)
        #expect(s.session.percent == nil)
    }

    @Test("The platform reading carries no percentage")
    func platformReadingHasNoPercent() {
        let s = store()
        s.apply(StatusOutcome.sample(
            StatusSample(state: .nominal, description: "All Systems Operational"),
            asOf: now
        ))
        s.revalidate(now: now)
        #expect(s.platform.state == .nominal)
        #expect(s.platform.percent == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/Engine && swift test --filter IndicatorStoreTests > "$SCRATCH/gauges-task1-red.log" 2>&1; echo "exit=$?"`

Expected: non-zero exit, with compilation errors of the form `value of type 'Reading' has no member 'percent'`.

- [ ] **Step 3: Add the field to `Reading`**

Replace the body of `Packages/Indicators/Sources/Indicators/Reading.swift`:

```swift
import Foundation

/// A resolved value for one indicator, ready for display.
public struct Reading: Sendable, Equatable {
    public let state: IndicatorState
    public let detail: String
    /// Why this value may be ageing.  Nil normally.
    public let note: String?
    /// The utilisation this reading reports, 0...100, or nil where
    /// there is no number: the platform light, which has none, and any
    /// reading MonoCl cannot vouch for.  The renderer needs a
    /// magnitude; every text path uses `detail` instead.
    public let percent: Double?
    public let asOf: Date

    public init(
        state: IndicatorState,
        detail: String,
        note: String? = nil,
        percent: Double? = nil,
        asOf: Date
    ) {
        self.state = state
        self.detail = detail
        self.note = note
        self.percent = percent
        self.asOf = asOf
    }

    /// A reading MonoCl cannot vouch for.
    public static func unknown(detail: String, asOf: Date) -> Reading {
        Reading(state: .unknown, detail: detail, note: nil, percent: nil, asOf: asOf)
    }
}
```

The default on `percent` is what keeps `MonoClTests/TooltipComposerTests.swift:25` compiling unchanged — it constructs `Reading`s positionally without one.

- [ ] **Step 4: Populate it in the store**

In `Packages/Engine/Sources/Engine/IndicatorStore.swift`, in `usageReading(_:now:)`, add the field to the returned `Reading`:

```swift
        return Reading(
            state: thresholds.state(forPercent: sample.percent),
            detail: "\(Int(sample.percent.rounded()))%",
            note: usageFailure?.menuText,
            percent: sample.percent,
            asOf: asOf
        )
```

Leave `platformReading(now:)` alone: it takes the default nil, which is correct — a status page has no percentage.

Both early returns in `usageReading` go through `.unknown(detail:asOf:)`, which sets nil, so the untrusted case needs no separate change.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Packages/Engine && swift test > "$SCRATCH/gauges-task1.log" 2>&1; echo "exit=$?"`
Expected: exit=0.

Then confirm the additive change broke no caller:

```bash
cd Packages/Indicators && swift test > "$SCRATCH/gauges-task1-indicators.log" 2>&1; echo "exit=$?"; cd -
xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/gauges-task1-app.log" 2>&1; echo "exit=$?"
```

Expected: exit=0 from both. Inspect each log with `grep -n -E '✘|failed|error:' "$SCRATCH/gauges-task1-app.log"`.

- [ ] **Step 6: Commit**

```bash
git add Packages/Indicators/Sources/Indicators/Reading.swift \
        Packages/Engine/Sources/Engine/IndicatorStore.swift \
        Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift
git commit -F - <<'MSG'
Carry the utilisation percentage into the reading.

The sample's percentage crossed two package boundaries intact and was
then flattened to display text in usageReading, so nothing downstream
could draw a magnitude.

Nil rather than zero wherever there is no number -- the platform
light, and any reading that fails the trust check.  Those are
different facts from "none used" and the renderer draws them
differently.
MSG
```

---

## Task 2: Reshape the icon specification

**Goal:** `IconSpec` describes three named, differently-drawn parts instead of a list of interchangeable dots, and the breach cue becomes a mark count that no longer consults `differentiateWithoutColor`.

**Files:**
- Modify: `Packages/Indicators/Sources/Indicators/IconSpec.swift` (rewritten)
- Test: `Packages/Indicators/Tests/IndicatorsTests/IconSpecTests.swift` (rewritten)

**Acceptance Criteria:**
- [ ] `iconSpec(session:week:platform:)` takes three `Reading`s and takes no `differentiateWithoutColor` argument
- [ ] A gauge's `fraction` is the reading's percentage over one hundred; nil when the reading has no percentage
- [ ] A percentage above one hundred clamps to a fraction of 1
- [ ] `breachMarks` is 0 at nominal and unknown, 1 at warning, 2 at critical — on the gauges and on the platform dot alike
- [ ] `isTemplate` is false exactly when at least one of the three states is a breach
- [ ] `swift test` passes in `Packages/Indicators`

**Expected breakage, fixed in Task 3:** the `MonoCl` app target does not compile at the end of this task. `MenuBarIcon.swift` and `AppDelegate.swift:50` still call the old `iconSpec(for:differentiateWithoutColor:)` and read `spec.dots`. That is the package boundary doing its job; do not paper over it with a transitional shim that Task 3 would only delete.

**Verify:** `cd Packages/Indicators && swift test > "$SCRATCH/gauges-task2.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Write the failing tests**

Replace `Packages/Indicators/Tests/IndicatorsTests/IconSpecTests.swift` entirely:

```swift
import Foundation
import Testing
@testable import Indicators

@Suite("Icon specification")
struct IconSpecTests {
    private func reading(_ state: IndicatorState, percent: Double? = nil) -> Reading {
        Reading(state: state, detail: "", percent: percent, asOf: Date(timeIntervalSince1970: 0))
    }

    private func spec(
        session: IndicatorState = .nominal, sessionPercent: Double? = 10,
        week: IndicatorState = .nominal, weekPercent: Double? = 20,
        platform: IndicatorState = .nominal
    ) -> IconSpec {
        iconSpec(
            session: reading(session, percent: sessionPercent),
            week: reading(week, percent: weekPercent),
            platform: reading(platform)
        )
    }

    @Test("No breach means a template image")
    func templateWhenQuiet() {
        #expect(spec().isTemplate == true)
        #expect(spec(session: .unknown, sessionPercent: nil, platform: .unknown).isTemplate == true)
    }

    @Test("Any breach means a non-template image")
    func nonTemplateWhenBreached() {
        #expect(spec(session: .warning, sessionPercent: 78).isTemplate == false)
        #expect(spec(platform: .critical).isTemplate == false)
    }

    @Test("A gauge's fraction is its percentage over one hundred")
    func fractionFollowsPercent() {
        let s = spec(sessionPercent: 62, weekPercent: 5)
        #expect(s.session.fraction == 0.62)
        #expect(s.week.fraction == 0.05)
    }

    @Test("A reading with no percentage has no fraction")
    func unknownHasNoFraction() {
        // Nil, not zero: a track with no sweep is a different picture
        // from a sweep of length zero, and only one of them is honest
        // about not knowing.
        let s = spec(session: .unknown, sessionPercent: nil)
        #expect(s.session.fraction == nil)
    }

    @Test("A percentage beyond one hundred clamps to a full sweep")
    func fractionClamps() {
        // 104% would otherwise sweep 374 degrees and wrap past twelve,
        // drawing a nearly empty gauge for a completely full window.
        #expect(spec(session: .critical, sessionPercent: 104).session.fraction == 1)
    }

    @Test("Breach marks count severity on the gauges")
    func gaugeBreachMarks() {
        #expect(spec(sessionPercent: 10).session.breachMarks == 0)
        #expect(spec(session: .unknown, sessionPercent: nil).session.breachMarks == 0)
        #expect(spec(session: .warning, sessionPercent: 78).session.breachMarks == 1)
        #expect(spec(session: .critical, sessionPercent: 94).session.breachMarks == 2)
    }

    @Test("Breach marks count severity on the platform dot too")
    func platformBreachMarks() {
        #expect(spec(platform: .nominal).platform.breachMarks == 0)
        #expect(spec(platform: .warning).platform.breachMarks == 1)
        #expect(spec(platform: .critical).platform.breachMarks == 2)
    }

    @Test("Tints follow state")
    func tints() {
        let s = spec(session: .unknown, sessionPercent: nil,
                     week: .warning, weekPercent: 78, platform: .critical)
        #expect(s.session.tint == .dimmed)
        #expect(s.week.tint == .amber)
        #expect(s.platform.tint == .red)
        #expect(spec().session.tint == .monochrome)
    }

    @Test("The platform dot is a ring when quiet and a disc when not")
    func platformFill() {
        #expect(spec(platform: .unknown).platform.fill == .ring(faint: true))
        #expect(spec(platform: .nominal).platform.fill == .ring(faint: false))
        #expect(spec(platform: .warning).platform.fill == .filled)
        #expect(spec(platform: .critical).platform.fill == .filled)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/Indicators && swift test > "$SCRATCH/gauges-task2-red.log" 2>&1; echo "exit=$?"`

Expected: non-zero exit, with errors naming the missing `iconSpec(session:week:platform:)` and the missing `GaugeSpec`.

- [ ] **Step 3: Rewrite the specification**

Replace `Packages/Indicators/Sources/Indicators/IconSpec.swift` entirely:

```swift
/// How one dot should be drawn. Deliberately free of AppKit types so
/// the decision is testable without a screen.
public struct DotSpec: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        case ring(faint: Bool)
        case filled
    }

    public enum Tint: Sendable, Equatable {
        case monochrome
        case dimmed
        case amber
        case red
    }

    public let fill: Fill
    public let tint: Tint
    /// Radial slots cut through the dot: none when quiet, one at
    /// warning, two at critical.  The same count the gauges carry, so
    /// a reader learns one rule rather than two.
    public let breachMarks: Int

    public init(fill: Fill, tint: Tint, breachMarks: Int = 0) {
        self.fill = fill
        self.tint = tint
        self.breachMarks = breachMarks
    }
}

/// How one usage gauge should be drawn.
public struct GaugeSpec: Sendable, Equatable {
    /// The fraction of the window consumed, 0...1, or nil where there
    /// is nothing to draw a value from.  Nil is not zero: an unknown
    /// reading is a track with no sweep, which says "no value" rather
    /// than "no usage".
    public let fraction: Double?
    public let tint: DotSpec.Tint
    /// Radial slots cut through the gauge: 0 nominal, 1 warning, 2
    /// critical.
    ///
    /// A count rather than a flag
    /// ---
    ///
    /// Colour alone cannot separate amber from red for a reader with a
    /// colour vision deficiency, and with a continuous sweep the
    /// geometry does not separate them either: the warning and
    /// critical thresholds are 54 degrees of arc apart, which reads as
    /// "fairly full" either way.  Counting to two is categorical where
    /// comparing two arc lengths is not.
    public let breachMarks: Int

    public init(fraction: Double?, tint: DotSpec.Tint, breachMarks: Int) {
        self.fraction = fraction
        self.tint = tint
        self.breachMarks = breachMarks
    }
}

/// A whole menu bar image: the two usage gauges, the platform dot, and
/// whether the image may be a template.
///
/// Named parts rather than a list, because the three are drawn three
/// different ways.  There is then no position to get wrong and no count
/// to enforce elsewhere.
public struct IconSpec: Sendable, Equatable {
    public let session: GaugeSpec
    public let week: GaugeSpec
    public let platform: DotSpec
    public let isTemplate: Bool

    public init(session: GaugeSpec, week: GaugeSpec, platform: DotSpec, isTemplate: Bool) {
        self.session = session
        self.week = week
        self.platform = platform
        self.isTemplate = isTemplate
    }
}

/// Maps readings to a drawable specification.
///
/// A template image is tinted by the system from its alpha channel,
/// which is exactly right for monochrome and dimmed and destroys amber
/// and red. So the image stays a template until something actually
/// needs colour — `.unknown` does not, because "dimmed" is alpha, not
/// hue.
///
/// The breach marks are not conditional on
/// `accessibilityDisplayShouldDifferentiateWithoutColor`.  They are the
/// only thing separating warning from critical by shape, they appear
/// only in a state that is exceptional by construction, and the reader
/// they exist for is the one who has not enabled the setting.
public func iconSpec(session: Reading, week: Reading, platform: Reading) -> IconSpec {
    IconSpec(
        session: gauge(for: session),
        week: gauge(for: week),
        platform: dot(for: platform),
        isTemplate: ![session, week, platform].contains { $0.state.isBreach }
    )
}

private func gauge(for reading: Reading) -> GaugeSpec {
    GaugeSpec(
        fraction: reading.percent.map { min(max($0 / 100, 0), 1) },
        tint: tint(for: reading.state),
        breachMarks: breachMarks(for: reading.state)
    )
}

private func dot(for reading: Reading) -> DotSpec {
    DotSpec(
        fill: reading.state.isBreach ? .filled : .ring(faint: reading.state == .unknown),
        tint: tint(for: reading.state),
        breachMarks: breachMarks(for: reading.state)
    )
}

private func breachMarks(for state: IndicatorState) -> Int {
    switch state {
    case .unknown, .nominal: 0
    case .warning: 1
    case .critical: 2
    }
}

private func tint(for state: IndicatorState) -> DotSpec.Tint {
    switch state {
    case .unknown: .dimmed
    case .nominal: .monochrome
    case .warning: .amber
    case .critical: .red
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/Indicators && swift test > "$SCRATCH/gauges-task2.log" 2>&1; echo "exit=$?"`
Expected: exit=0.

Do not run `xcodebuild` here; the app target is knowingly broken until Task 3.

- [ ] **Step 5: Commit**

```bash
git add Packages/Indicators/Sources/Indicators/IconSpec.swift \
        Packages/Indicators/Tests/IndicatorsTests/IconSpecTests.swift
git commit -F - <<'MSG'
Describe the icon as three named parts.

A list of interchangeable dots was the right shape while all three
were drawn identically.  They are about to be drawn three different
ways, so the list becomes a position to get wrong and a count to
enforce elsewhere; named fields make both unrepresentable.

Fill.notched goes with it.  It spelled "critical" as a shape at a
point when nothing else did, and breachMarks now expresses severity
for every indicator -- keeping both would leave two spellings of one
idea, with the dot as the only survivor of the older one.

The marks are no longer gated on the differentiate-without-colour
setting.  They are the only thing separating warning from critical by
shape; they appear only in a state that is exceptional by
construction; and the reader they exist for is precisely the one who
has not found the setting.  The app target does not build until its
call site catches up.
MSG
```

---

## Task 3: Draw the gauges

**Goal:** The menu bar shows the new icon: session as an outer swept ring, week as an inner wedge, the platform as a dot, with breach slots cut as alpha.

**Files:**
- Modify: `MonoCl/MenuBarIcon.swift` (rewritten)
- Modify: `MonoCl/AppDelegate.swift:47-55` (the `iconSpec` call) and `:104-113` (the accessibility observer)
- Modify: `Packages/Engine/Sources/Engine/IndicatorStore.swift` (remove `states`)
- Modify: `Packages/Engine/Tests/EngineTests/EngineTests.swift:135`
- Modify: `Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift:259`
- Test: `MonoClTests/MenuBarIconTests.swift` (rewritten)

**Acceptance Criteria:**
- [ ] The image is exactly 34 pt wide and `NSStatusBar.system.thickness` tall
- [ ] The accessibility description carries both magnitudes and all three states, e.g. `Session 94 percent critical, week 40 percent normal, platform warning`
- [ ] An unknown gauge is described as `unknown`, never as `0 percent`
- [ ] The template flag reaches the image
- [ ] The drawing handler produces a bitmap
- [ ] `AppDelegate` no longer reads `accessibilityDisplayShouldDifferentiateWithoutColor` and no longer observes `accessibilityDisplayOptionsDidChangeNotification`
- [ ] `swift test` passes in `Packages/Engine`; `xcodebuild -scheme MonoCl test` passes

**Verify:** `xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/gauges-task3-app.log" 2>&1; echo "exit=$?"` → exit=0

**Steps:**

- [ ] **Step 1: Write the failing tests**

Replace `MonoClTests/MenuBarIconTests.swift` entirely:

```swift
import AppKit
import Foundation
import Indicators
import Testing
@testable import MonoCl

@MainActor
@Suite("Menu bar icon")
struct MenuBarIconTests {
    private let appearance = NSAppearance(named: .aqua)!

    private func reading(_ state: IndicatorState, percent: Double? = nil) -> Reading {
        Reading(state: state, detail: "", percent: percent, asOf: Date(timeIntervalSince1970: 0))
    }

    private func image(
        session: IndicatorState = .nominal, sessionPercent: Double? = 10,
        week: IndicatorState = .nominal, weekPercent: Double? = 20,
        platform: IndicatorState = .nominal
    ) -> NSImage {
        let spec = iconSpec(
            session: reading(session, percent: sessionPercent),
            week: reading(week, percent: weekPercent),
            platform: reading(platform)
        )
        return MenuBarIcon.image(for: spec, appearance: appearance)
    }

    @Test("The template flag reaches the image")
    func templateFlagPropagates() {
        #expect(image().isTemplate == true)
        #expect(image(session: .critical, sessionPercent: 94).isTemplate == false)
    }

    @Test("Geometry matches the menu bar and the glyph layout")
    func geometry() {
        let icon = image()
        #expect(icon.size.height == NSStatusBar.system.thickness)
        // 2pt inset, a 20pt glyph box, a 6pt gap, the platform disc's
        // 4pt radius, 2pt inset.  The exact number rather than a lower
        // bound: a bound written in terms of the implementation's own
        // constants cannot fail when the layout formula changes, which
        // is the one thing worth being told about.
        #expect(icon.size.width == 34)
    }

    @Test("The accessibility description carries both magnitudes and all three states")
    func accessibilityDescriptionCarriesMagnitudes() {
        let icon = image(session: .critical, sessionPercent: 94,
                         week: .nominal, weekPercent: 40,
                         platform: .warning)
        #expect(icon.accessibilityDescription
                == "Session 94 percent critical, week 40 percent normal, platform warning")
    }

    @Test("An unknown gauge is described as unknown, not as zero")
    func accessibilityDescriptionForUnknown() {
        let icon = image(session: .unknown, sessionPercent: nil,
                         week: .nominal, weekPercent: 40)
        #expect(icon.accessibilityDescription
                == "Session unknown, week 40 percent normal, platform normal")
    }

    @Test("The drawing handler produces a bitmap")
    func drawable() throws {
        let icon = image(session: .unknown, sessionPercent: nil,
                         week: .warning, weekPercent: 78,
                         platform: .critical)
        // The `#require`s are the assertion: `tiffRepresentation` is nil
        // if the drawing handler produced nothing.  Asserting a size
        // greater than zero would pass on an image that never drew,
        // since the size is set at construction rather than by drawing.
        let data = try #require(icon.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.size == icon.size)
    }
}
```

The old `accessibilityDescriptionSurvivesAMismatchedCount` test is deliberately gone. It guarded a `zip` over a positional array; with named fields there is no count to mismatch, so the case it covered is now unrepresentable rather than merely untested.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/gauges-task3-red.log" 2>&1; echo "exit=$?"`

Expected: non-zero exit. `grep -n 'error:' "$SCRATCH/gauges-task3-red.log"` shows `MenuBarIcon.swift` and `AppDelegate.swift` failing against the reshaped `IconSpec` — the breakage Task 2 predicted.

- [ ] **Step 3: Rewrite the renderer**

Replace `MonoCl/MenuBarIcon.swift` entirely:

```swift
import AppKit
import Indicators

/// Draws the menu bar image from a specification.
///
/// The appearance is passed in rather than read from `NSApp`: the menu
/// bar's effective appearance differs from the application's, and using
/// the wrong one produces a glyph that is invisible against certain
/// wallpapers.  Callers pass `statusItem.button!.effectiveAppearance`.
@MainActor
enum MenuBarIcon {
    private static let inset: CGFloat = 2
    private static let glyphDiameter: CGFloat = 20
    private static let ringWidth: CGFloat = 3
    /// Centreline of the session ring, so its 3pt stroke lands inside
    /// the glyph box rather than straddling the edge of it.
    private static let ringRadius: CGFloat = glyphDiameter / 2 - ringWidth / 2
    private static let pieRadius: CGFloat = glyphDiameter / 2 - ringWidth - 1.5
    private static let platformGap: CGFloat = 6
    private static let platformRingRadius: CGFloat = 3
    private static let platformDiscRadius: CGFloat = 4

    static let width: CGFloat =
        inset + glyphDiameter + platformGap + platformDiscRadius + inset

    /// Where the breach slots are cut, as `NSBezierPath` measures
    /// angles.
    ///
    /// Inside the thresholds, not on them
    /// ---
    ///
    /// A slot at the 75% angle sits under a degree of arc from the tip
    /// of a just-breached 76% gauge — less than a pixel at drawn size —
    /// so it reads as the arc ending rather than as a mark within it,
    /// and just-breached is exactly when the cue matters most.  Pulling
    /// the slots inward leaves drawn material on both sides of every
    /// cut.  They count severity; the arc length already reports the
    /// value.
    private static let markAngles: [CGFloat] = [angle(atPercent: 73), angle(atPercent: 88)]

    /// Clockwise from twelve o'clock, which is where every gauge starts.
    private static func angle(atPercent percent: CGFloat) -> CGFloat {
        90 - percent / 100 * 360
    }

    static func image(for spec: IconSpec, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: width, height: NSStatusBar.system.thickness)

        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let centre = NSPoint(x: inset + glyphDiameter / 2, y: rect.midY)
                draw(ring: spec.session, at: centre)
                draw(pie: spec.week, at: centre)
                draw(dot: spec.platform,
                     at: NSPoint(x: centre.x + glyphDiameter / 2 + platformGap, y: rect.midY))
            }
            return true
        }
        image.isTemplate = spec.isTemplate
        image.accessibilityDescription = accessibilityDescription(for: spec)
        return image
    }

    // MARK: - Parts

    private static func draw(ring gauge: GaugeSpec, at centre: NSPoint) {
        strokeArc(at: centre, radius: ringRadius, width: ringWidth,
                  sweep: 360, color: trackColor)
        if let fraction = gauge.fraction, fraction > 0 {
            strokeArc(at: centre, radius: ringRadius, width: ringWidth,
                      sweep: 360 * fraction, color: color(for: gauge.tint))
        }
        cut(gauge.breachMarks, at: centre,
            from: ringRadius - ringWidth / 2 - 0.5,
            to: ringRadius + ringWidth / 2 + 0.5)
    }

    private static func draw(pie gauge: GaugeSpec, at centre: NSPoint) {
        fillDisc(at: centre, radius: pieRadius, color: trackColor)
        if let fraction = gauge.fraction, fraction > 0 {
            fillWedge(at: centre, radius: pieRadius, sweep: 360 * fraction,
                      color: color(for: gauge.tint))
        }
        cut(gauge.breachMarks, at: centre, from: 0, to: pieRadius + 0.5)
    }

    private static func draw(dot: DotSpec, at centre: NSPoint) {
        switch dot.fill {
        case let .ring(faint):
            strokeCircle(at: centre, radius: platformRingRadius,
                         width: faint ? 1 : 1.5, color: color(for: dot.tint))
        case .filled:
            fillDisc(at: centre, radius: platformDiscRadius, color: color(for: dot.tint))
        }
        cut(dot.breachMarks, at: centre, from: 0, to: platformDiscRadius + 0.5)
    }

    /// Cuts radial slots through whatever has already been drawn.
    ///
    /// The slots are alpha rather than paint.  The menu bar's
    /// background is the user's wallpaper, so a gap painted in any
    /// colour would be a smear of the wrong one; and a template image
    /// takes its tint from the alpha channel, which is what the cut
    /// leaves behind.
    private static func cut(_ count: Int, at centre: NSPoint,
                            from innerRadius: CGFloat, to outerRadius: CGFloat) {
        guard count > 0, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        for degrees in markAngles.prefix(count) {
            let radians = degrees * .pi / 180
            let path = NSBezierPath()
            path.move(to: NSPoint(x: centre.x + cos(radians) * innerRadius,
                                  y: centre.y + sin(radians) * innerRadius))
            path.line(to: NSPoint(x: centre.x + cos(radians) * outerRadius,
                                  y: centre.y + sin(radians) * outerRadius))
            path.lineWidth = 1
            NSColor.black.setStroke()
            path.stroke()
        }
        context.restoreGraphicsState()
    }

    // MARK: - Primitives

    private static func strokeArc(at centre: NSPoint, radius: CGFloat, width: CGFloat,
                                  sweep: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .butt
        color.setStroke()
        path.stroke()
    }

    private static func strokeCircle(at centre: NSPoint, radius: CGFloat,
                                     width: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private static func fillDisc(at centre: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    private static func fillWedge(at centre: NSPoint, radius: CGFloat,
                                  sweep: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: centre)
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.close()
        color.setFill()
        path.fill()
    }

    private static var trackColor: NSColor { .labelColor.withAlphaComponent(0.18) }

    private static func color(for tint: DotSpec.Tint) -> NSColor {
        switch tint {
        case .monochrome: .labelColor
        case .dimmed: .labelColor.withAlphaComponent(0.35)
        case .amber: .systemOrange
        case .red: .systemRed
        }
    }

    // MARK: - Accessibility

    private static func accessibilityDescription(for spec: IconSpec) -> String {
        "Session \(describe(spec.session)), week \(describe(spec.week)), "
            + "platform \(name(for: spec.platform.tint))"
    }

    private static func describe(_ gauge: GaugeSpec) -> String {
        guard let fraction = gauge.fraction else { return name(for: gauge.tint) }
        return "\(Int((fraction * 100).rounded())) percent \(name(for: gauge.tint))"
    }

    private static func name(for tint: DotSpec.Tint) -> String {
        switch tint {
        case .monochrome: "normal"
        case .dimmed: "unknown"
        case .amber: "warning"
        case .red: "critical"
        }
    }
}
```

- [ ] **Step 4: Update the call site and drop the accessibility observer**

In `MonoCl/AppDelegate.swift`, `renderIcon()`:

```swift
        let spec = iconSpec(
            session: engine.store.session,
            week: engine.store.week,
            platform: engine.store.platform
        )
```

and delete this whole block from `observeSystemNotifications()`:

```swift
        center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Nothing about the readings changed — only how they are
            // drawn — so this never reaches the engine.
            MainActor.assumeIsolated { self?.renderIcon() }
        }
```

Nothing in the drawing consults the setting any more, so an observer that re-renders when it changes would redraw an identical image and would suggest a behaviour that no longer exists.

- [ ] **Step 5: Remove `IndicatorStore.states`**

Its doc comment calls it "Convenience for the renderer", and the renderer no longer takes a list of states. Delete from `Packages/Engine/Sources/Engine/IndicatorStore.swift`:

```swift
    /// Convenience for the renderer: the three states in display order.
    public var states: [IndicatorState] { [session.state, week.state, platform.state] }
```

Then fix its two test call sites. In `Packages/Engine/Tests/EngineTests/EngineTests.swift:135`:

```swift
        #expect(engine.store.session.state == .unknown)
        #expect(engine.store.week.state == .unknown)
        #expect(engine.store.platform.state == .unknown)
```

And in `Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift:259`, keeping the comment that explains the choice of values:

```swift
        // Three DISTINGUISHABLE states, so a transposition fails rather
        // than coincidentally matching: session critical (95%), week
        // nominal (10%), platform warning.
        #expect(s.session.state == .critical)
        #expect(s.week.state == .nominal)
        #expect(s.platform.state == .warning)
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd Packages/Engine && swift test > "$SCRATCH/gauges-task3-engine.log" 2>&1; echo "exit=$?"; cd -
xcodebuild -scheme MonoCl -destination 'platform=macOS' test > "$SCRATCH/gauges-task3-app.log" 2>&1; echo "exit=$?"
```

Expected: exit=0 from both. Inspect with `grep -n -E '✘|failed|error:' "$SCRATCH/gauges-task3-app.log"`.

- [ ] **Step 7: Commit**

```bash
git add MonoCl/MenuBarIcon.swift MonoCl/AppDelegate.swift \
        MonoClTests/MenuBarIconTests.swift \
        Packages/Engine/Sources/Engine/IndicatorStore.swift \
        Packages/Engine/Tests/EngineTests/EngineTests.swift \
        Packages/Engine/Tests/EngineTests/IndicatorStoreTests.swift
git commit -F - <<'MSG'
Draw the usage windows as gauges.

Session becomes an outer swept ring and the week an inner wedge, both
running clockwise from twelve: the fast hand outside, the slow one
within.  Two concentric rings would have been the obvious nesting and
collapse into an undifferentiated bullseye exactly when both are
breached and both are red, which is when knowing which one matters
most; a stroke against a fill stays legible in every combination.

Breach slots are cut as alpha rather than painted, because the
background behind a menu bar item is the user's wallpaper, and
because a template image takes its tint from the alpha channel.

IndicatorStore.states goes: it existed as a convenience for a
renderer that no longer takes a list of states, and its two remaining
callers were tests asserting three states at once.
MSG
```

---

## Task 4: See it in the menu bar

**Goal:** Confirm the icon renders correctly through a real `NSStatusItem`, against a real wallpaper, in both appearances — the one claim no amount of offscreen rendering could settle.

**Files:** none modified unless a defect is found.

**Acceptance Criteria:**
- [ ] The app launches and shows the new icon in the menu bar
- [ ] The session ring and the week wedge are distinguishable from each other at actual size
- [ ] The icon is legible in both light and dark appearance, and against a busy wallpaper
- [ ] Switching appearance redraws the icon correctly rather than leaving a stale image
- [ ] If usage data is unavailable, the icon shows tracks with no sweep — not an empty box and not a full one

**Verify:** visual inspection of the running app; report what was observed, including which states could not be exercised.

**Steps:**

- [ ] **Step 1: Build and launch**

```bash
xcodebuild -scheme MonoCl -destination 'platform=macOS' \
  -derivedDataPath "$SCRATCH/dd" build > "$SCRATCH/gauges-task4-build.log" 2>&1; echo "exit=$?"
open "$SCRATCH/dd/Build/Products/Debug/MonoCl.app"
```

Approve the keychain prompt if it appears — an ad-hoc signature changes on every build, so the grant does not survive one (`DEFERRED.md` item 3).

- [ ] **Step 2: Look at it**

Check, in this order, and write down what you actually see rather than what you expect:

1. Ring and wedge distinguishable at actual size.
2. Legibility in light appearance, then dark (System Settings → Appearance), then over a busy wallpaper.
3. Whether the appearance switch redraws or leaves a stale image.
4. The unknown state: quit Claude Code so the credential expires, or run with `MONOCL_FAKE_CREDENTIAL=not-found`, and confirm the gauges show faint tracks with no sweep.

- [ ] **Step 3: Exercise a breach if you can, and say so if you cannot**

The breach slots only appear above 75%, which real usage may not reach on demand. If it cannot be exercised live, temporarily lower the thresholds in Settings (warning 1%, critical 2%), confirm one slot then two, and **restore the thresholds afterwards**. Record which states were seen live and which were reached only by moving the thresholds.

- [ ] **Step 4: Quit and report**

Quit MonoCl from its own menu. Report findings against each acceptance criterion, naming anything not verified. Silence reads as "verified", so an unexercised state must be stated as unexercised.

If a defect is found, fix it in a new commit on this branch and re-run Task 3's verify command before reporting complete.

---

## Task 5: Update the durable records

**Goal:** A reader arriving at `2026-08-31-monocl-design.md` or at `DEFERRED.md` learns what changed, rather than implementing three dots from one and a dot-order mirror from the other.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-monocl-design.md`
- Modify: `DEFERRED.md`

**Acceptance Criteria:**
- [ ] The Rendering section names its successor by path
- [ ] The "Color is not the only encoder" section says its shape table no longer describes what is drawn
- [ ] `DEFERRED.md` item 2's "What to build" describes moving the platform dot, and records that the gauges must not mirror
- [ ] Two commits: the spec change alone, then `DEFERRED.md` alone

**Verify:** `git show --stat HEAD~1 && git show --stat HEAD` → the first touches only `docs/superpowers/specs/`, the second only `DEFERRED.md`

**Steps:**

- [ ] **Step 1: Add the pointers**

Immediately under the `## Rendering` heading in `docs/superpowers/specs/2026-08-31-monocl-design.md`, insert:

```markdown
> **Superseded** by
> `docs/superpowers/specs/2026-09-01-menu-bar-gauges-design.md`. The
> three dots described below were replaced by two percentage gauges
> and a platform dot. Everything above this section still holds.
```

And immediately under the `### Color is not the only encoder` heading, insert:

```markdown
> **Superseded.** The shape table below describes the three-dot icon.
> The gauges encode severity as a count of cut slots instead, and do
> not consult the system setting — see the successor spec for why.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-31-monocl-design.md
git commit -F - <<'MSG'
Mark the three-dot rendering as superseded.

The sections still read as current, and a reader arriving at the
original design would otherwise implement an icon that no longer
exists.  Pointers rather than deletion: the reasoning for the single
status item, the template rule and the effective-appearance choice all
survive into the successor and are argued here.
MSG
```

- [ ] **Step 3: Confirm the commit is spec-only**

Run: `git show --stat HEAD`
Expected: one file, under `docs/superpowers/specs/`.

- [ ] **Step 4: Correct the deferred right-to-left item**

`DEFERRED.md` item 2 currently says the mirror is achieved by reversing the dot sequence. There is no sequence any more. Replace its "**What to build:**" paragraph with:

```markdown
**What to build:** move the platform dot to the left of the gauge
glyph when the effective layout direction is right-to-left, and
reverse the tooltip line order to match, so the text and the icon
agree.

The gauges themselves MUST NOT mirror. Their clockwise sweep is a
clock convention rather than a reading-direction one, and clocks run
clockwise in right-to-left locales too; reversing them would make the
icon wrong rather than localized.
```

- [ ] **Step 5: Commit `DEFERRED.md` on its own**

```bash
git add DEFERRED.md
git commit -F - <<'MSG'
Correct the right-to-left item for the gauge icon.

The item described the mirror as reversing a dot sequence, which no
longer exists.  It is now one glyph and one dot, so the mirror moves
the dot.

Records the limit while the reasoning is fresh: the gauges must not
mirror.  Clockwise is a clock convention, not a reading-direction
one, and clocks run clockwise in right-to-left locales too.
MSG
git show --stat HEAD
```

Expected: one file, `DEFERRED.md`.
