# Menu bar gauges — design

**Date:** 2026-09-01
**Status:** draft, awaiting review
**Supersedes:** the Rendering section of
`2026-08-31-monocl-design.md` (three 8 pt dots), and its "Color is not
the only encoder" shape table

## Why

The three dots report state and nothing else. Each is one of four
values, so the icon can say "session is in warning" but never "session
is at 78% and climbing". The number exists — `UsageSample.percent`
crosses two package boundaries intact — and is then thrown away in
`IndicatorStore.usageReading`, which keeps only
`"\(Int(sample.percent.rounded()))%"` as display text for the menu.

The consequence is that the menu bar cannot answer the question it is
there to answer. "Do I have room for a long task before the session
window resets?" needs a magnitude, and today it needs a click to get
one. A dot that is still monochrome at 74% and amber at 75% gives no
warning of its own arrival.

The redesign spends the icon's area on that magnitude, and keeps the
threshold states as an overlay on it rather than as the whole signal.

## Scope

In scope: the drawn image, the specification type it is drawn from, and
carrying `percent` far enough forward to draw it.

Out of scope: what MonoCl fetches, how often, how it decides thresholds
or staleness, the tooltip, and the menu. No source, no rule and no
policy changes. The states themselves are unchanged — `IndicatorState`
keeps its four cases and `Thresholds` keeps its inclusive comparisons.

## The design

One `NSStatusItem`, one image, as now, and for the same reason: macOS
lets the user rearrange status items freely, so a light whose meaning
depends on position must not be a separate item.

| Element | Form | Carries |
|---|---|---|
| Session | outer ring, 20 pt diameter, 3 pt stroke | percentage, as a sweep clockwise from twelve o'clock over a faint full-circle track |
| Week | inner filled pie, 5.5 pt radius | percentage, as a wedge from the same origin in the same direction |
| Platform | separate dot, right of the glyph | state only — it has no percentage |

Drawn extent is about 34 pt against today's 36 pt, so the change costs
no menu bar width. Height continues to come from
`NSStatusBar.system.thickness`, never hardcoded, and the image is still
built with `NSImage(size:flipped:drawingHandler:)` so it redraws on
appearance changes.

### Why concentric, and why these two forms

Nesting two gauges only works if they differ in kind. Two concentric
rings — whatever their radii or stroke weights — collapse into an
undifferentiated bullseye exactly when both are breached and both are
red, which is the moment the reader most needs to know *which* one.
A stroked ring against a filled pie stays legible in every combination,
because the discrimination does not depend on estimating radius.

### Why session is the outer element

Session refills in hours; the week window in days. Reading the fast
quantity on the long outer arc and the slow one within is the clock's
own convention, and both gauges sweep clockwise from twelve, so the
metaphor is reinforced rather than merely borrowed. The outer path also
has the greater circumference and therefore the finer angular
resolution, which is worth spending on the value consulted more often.

The week nonetheless keeps the heavier form. Consultation frequency
favors the session, but severity favors the week: a full session window
refills over lunch, whereas a full week locks the user out for days.
Position follows frequency, visual mass follows severity, and the two
signals do not compete because they are different shapes.

### Why a continuous sweep and not eighths

An earlier iteration divided both gauges into eight countable segments.
It was rejected, and the reason generalizes: **quantization is only
visible where there are gaps.** A solid wedge snapped to 45° is
indistinguishable from a continuous wedge that happens to sit at 45°, so
the inner gauge gained nothing a reader could see while still rounding
3% up to an eighth of the disc. Segmenting the outer ring did read, but
only at the cost of the busy, ticked appearance the design is trying to
avoid.

## Breach marks: color is not the only encoder

Amber against red remains the most confusable pair for viewers with
color vision deficiency, and with a continuous sweep the geometry no
longer separates them on its own: 75% and 90% differ by 54° of arc,
which reads as "fairly full" either way.

The cue is a **count of radial slots cut through the gauge**: none when
nominal, one at warning, two at critical.

| State | Tint | Session ring | Week pie |
|---|---|---|---|
| unknown | dimmed | faint track only, no sweep | faint track only, no wedge |
| nominal | monochrome | sweep, no slots | wedge, no slots |
| warning | amber | sweep + 1 slot | wedge + 1 slot |
| critical | red | sweep + 2 slots | wedge + 2 slots |

The platform dot keeps the existing treatment: a ring when quiet, a
disc when not, notched once at warning and twice at critical.

Three properties of this cue were established by prototype and are the
reasons for its specific shape:

- **The slots sit at fixed angles, not at the arc's leading edge.** A
  mark that tracks the tip moves as the value moves, so the reader
  cannot learn where to look.
- **They sit a few degrees *inside* the thresholds** — around the 73%
  and 88% angles rather than 75% and 90%. At the 75% angle a
  just-breached 76% gauge leaves a sliver of arc beyond the cut of
  about 3.6°, well under a pixel at drawn size, so the slot reads as
  the arc simply ending rather than as a mark within it. Just-breached
  is when the cue matters most and is where the literal placement is
  weakest. The mark is therefore a severity counter, not a threshold
  indicator; the arc length already reports the value.
- **A notch at twelve o'clock does not work**, though it is the obvious
  first idea. At 94% the sweep already stops 21.6° short of twelve, so
  the cue would be confounded with the value it is meant to qualify,
  precisely in the range where it fires.

Slots are cut as **alpha**, by compositing `.clear` into the image,
never painted in a background color. The menu bar's background is the
user's wallpaper, so a painted gap would be a visible smear of the
wrong color. Alpha is also what template rendering consumes, so the
same drawing is expected to tint correctly in both the template and
non-template cases — expected on the basis of how template images are
documented to work, not yet observed in a running status item.

### The marks are not gated on the system setting

This is a behavior change and is deliberate. Today `.notched` appears
only when
`NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor`
is set. The new marks always appear.

Three reasons. The marks are the only thing separating warning from
critical by shape, and that distinction is worth having unconditionally.
They appear only in a breached state, which is exceptional by
construction, so the always-on cost is close to nothing. And a reader
with unrecognized or undiagnosed color vision deficiency has not enabled
the setting and is precisely the reader the cue exists for; gating it
serves only those who already know to ask.

The consequence must be followed through rather than left half-done: no
drawing decision then branches on the setting, so
`differentiateWithoutColor` stops being consulted, and its
`accessibilityDisplayOptionsDidChangeNotification` observer should be
removed rather than left as dead wiring that suggests a behavior which
no longer exists.

## Public surface

`IconSpec` is currently `[DotSpec]` — N interchangeable dots, with the
count of three enforced elsewhere and the renderer zipping labels onto
it positionally. The new image has three *named* parts drawn three
different ways, so the list is the wrong shape and the reshape is the
substantive change to the `Indicators` package:

```swift
public struct GaugeSpec: Sendable, Equatable {
    /// 0...1, or nil when there is no value to draw.
    public let fraction: Double?
    public let tint: DotSpec.Tint
    /// 0 nominal, 1 warning, 2 critical.
    public let breachMarks: Int
}

public struct IconSpec: Sendable, Equatable {
    public let session: GaugeSpec
    public let week: GaugeSpec
    public let platform: DotSpec
    public let isTemplate: Bool
}
```

`GaugeSpec` carries decisions, not geometry: diameters, stroke widths
and slot angles stay in `MenuBarIcon`, which is where the AppKit types
already live. The renderer knows that the session is drawn as a ring and
the week as a pie; the spec does not need to say so, and keeping it out
preserves the property that the spec is testable without a screen.

Naming the parts also fixes `accessibilityDescription`, which today
zips `["Session", "week", "platform"]` against an array and silently
truncates if the counts disagree. With named fields there is nothing to
zip and no mismatch to guard.

`DotSpec` survives unchanged for the platform light, `.notched`
included.

`isTemplate` keeps its existing rule — true until something breaches —
for the reasons the original design gives: the common case gets correct
system behavior for free, and the rare case wants a fixed color anyway.

## State lifecycle

| | `Reading.percent` |
|---|---|
| **written by** | `IndicatorStore.usageReading`, on every `revalidate(now:)`, from `UsageSample.percent`; nil for the platform reading, which has no percentage |
| **read by** | `iconSpec(for:)`, to compute sweep angle and mark count |
| **cleared by** | nothing separately: `Reading` is rebuilt wholesale on every `revalidate`, so the field is nil again whenever the sample is absent or fails the trust check |

The single-reader column is worth defending, because a discriminator
with one consumer is usually a signal that was added and never wired up.
Here the text paths already have what they need: `detail` carries the
formatted percentage for the tooltip and menu, and adding a second
consumer would mean deriving that string from the new field for no
gain. The renderer is the only thing that needs a number rather than a
string.

The rebuilt-not-mutated property is what makes the field safe to add at
all, and it is inherited rather than newly argued — the original
design's lifecycle table established it for `note` for the same reason.

## Testing

`iconSpec(for:)` is pure and stays headlessly testable, which is where
the behavior worth pinning lives:

- a percentage maps to the expected `fraction`, and an unknown reading
  to nil rather than to zero — the two must not be conflated, since one
  means "none used" and the other means "cannot vouch for it";
- `breachMarks` is 0, 1 and 2 at the nominal, warning and critical
  thresholds, asserted at the inclusive boundaries `Thresholds` already
  promises;
- `isTemplate` is false exactly when some part breaches.

Assertions state the expected value positively rather than the absence
of a wrong one, per the house rule.

`MenuBarIcon` itself is drawing, and the prototypes showed that the
questions worth asking about it — is the wedge distinguishable from the
ring, does a slot read as a slot at 22 pt — are answered by looking, not
by asserting. The honest coverage statement is that the geometry is
verified by eye and the specification by test; a snapshot test would pin
pixels without pinning legibility.

## Provenance

The design was settled over eight rounds of throwaway renderers that
drew candidate icons at `NSStatusBar.system.thickness` onto light, dark
and hue-removed strips. Those renderers were scratch files and are not
retained; the findings they produced are recorded above as the reasons
for each decision, which is the part worth keeping.

Nothing in them was ever seen through a real `NSStatusItem` against a
real wallpaper. That remains the first thing implementation should
check, and the one claim in this document that no amount of further
prototyping could have settled.

## Risk

The blast radius is one icon. Nothing here touches credentials, network
behavior, thresholds, staleness or persistence; there is no migration,
nothing is stored, and reverting is a revert.

The reversibility argument does not cover the accessibility change,
which is the one part of this that could make MonoCl worse for someone
without making it visibly wrong. Ungating the marks is defended above on
its merits, but the defense is reasoning, not evidence, and it is the
item most worth disagreeing with during review.

The second-order effect worth naming: `Reading` gaining a numeric field
invites later work to render numbers elsewhere from it, and the field is
nil in exactly the cases where a number would be a lie. The lifecycle
table above is the guard, and any new consumer needs to be added to it
rather than reading the field on trust.

## Relationship to deferred items

`DEFERRED.md` item 2 defers mirroring the indicator order in
right-to-left locales, on the grounds that the order is decided in one
place. That remains true and gets simpler: the mirror becomes moving the
platform dot to the left of the glyph.

It also acquires a limit worth recording now, while the reasoning is
fresh. The gauges must **not** mirror. Their clockwise direction is a
clock convention, not a reading-direction one, and clocks run clockwise
in right-to-left locales too. Reversing them would make the icon wrong
rather than localized.
