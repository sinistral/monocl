# Deferred

Index of follow-up items consciously deferred during design or
implementation. Each entry states what was deferred, why it was
acceptable to defer, and what would trigger picking it up.

Newest items go at the end. Delete an entry when the work lands, and
name the commit that closed it.

---

## 1. Report token expiration to the user

**Deferred:** surfacing *why* the usage lights are blank when MonoCl
cannot authenticate.

MonoCl is strictly read-only toward Claude Code's keychain credential
(`Claude Code-credentials`): it never refreshes and never writes.
Access tokens last hours, and refresh tokens rotate, so a MonoCl-side
refresh would invalidate the copy Claude Code holds and break the
user's login. Reading `expiresAt` from the credential record lets
MonoCl know locally, with no network call, whether its data can be
trusted.

The consequence is that after an idle stretch the two usage lights go
to their "unknown" state until Claude Code next runs and refreshes the
token. The initial build shows the unknown state without explaining
it.

**Why deferring is acceptable:** the unknown state is honest — it
reports absence rather than a stale value presented as current, which
is the failure mode that actually misleads. An unexplained blank is a
discoverability gap, not a correctness defect.

**What to build:** the tooltip, and any detail popover, should
distinguish "no reading yet" from "reading expired at HH:MM — run
Claude Code to refresh", using `expiresAt` rather than inferring
expiry from a failed request.

**Trigger:** the first time the blank state is confusing in daily use,
or before MonoCl is used by anyone who did not build it.

---

## 2. Mirror indicator order in right-to-left locales

**Deferred:** mirroring the left-to-right arrangement — the gauge
glyph (session ring, week pie) followed by the platform dot — for
locales that read right to left.

The brief specifies the ordering "for locales that read from left to
right", which implies the mirrored arrangement elsewhere. MonoCl is a
single-user personal tool built for a left-to-right locale, so
implementing the mirror now would be speculative work with no user.

**Why deferring is acceptable:** nothing else in the design has to
move to accommodate it later. The arrangement is decided in one
place — the renderer that composes the gauge glyph and the platform
dot — so the change is a single `NSApp.userInterfaceLayoutDirection`
check at that point. No data model, threshold rule, or tooltip logic
depends on the order.

**What to build:** move the platform dot to the left of the gauge
glyph when the effective layout direction is right-to-left, and
reverse the tooltip line order to match, so the text and the icon
agree.

The gauges themselves MUST NOT mirror. Their clockwise sweep is a
clock convention rather than a reading-direction one, and clocks run
clockwise in right-to-left locales too; reversing them would make the
icon wrong rather than localized.

**Trigger:** MonoCl being used in a right-to-left locale, or gaining
any user other than its author.

---

## 3. Sign with a stable identity so the keychain grant persists

**Deferred:** replacing ad-hoc signing with a stable self-signed code
signing identity.

A keychain ACL grant is bound to the requesting binary code signature.
MonoCl is ad-hoc signed, and an ad-hoc signature changes on every
rebuild, so the "Always Allow" decision does not survive a rebuild: the
authorization dialog reappears once per build.

**Why deferring is acceptable:** during development a rebuild happens
often and the prompt is a one-click annoyance, not a malfunction. The
behaviour MonoCl must get right, which is not re-prompting on a timer
after a denial, is unaffected by signing and is verified in Task 14.

**What to build:** create a self-signed code signing certificate in the
login keychain, set CODE_SIGN_IDENTITY in project.yml to its name, and
confirm that a rebuild no longer re-prompts.

**Trigger:** the per-build prompt becoming irritating enough to notice,
or MonoCl being installed somewhere it runs for long stretches without
being rebuilt.

---

## 4. Revisit the test host's fake credential

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

---

## 5. Make the drift check notice a value it cannot decode

**Deferred:** extending `Scripts/check-fixture-drift.sh` to compare the
things `UsageWindow` and `SummaryResponse` actually require, rather than
only the JSON type of each named key.

On 2026-09-01 MonoCl showed "Unexpected response" on both usage rows for
roughly half an hour, logging `Usage response did not decode` against a
200. Run during that window, the drift check reported "Fixtures match
the live response shapes". Both statements were true: the script asserts
that each named key exists in both documents and holds the same JSON
type, so two shapes it cannot see still break decoding — a `null` where
`UsageWindow` requires a non-optional value, and a `resets_at` whose
format neither of the two accepted `DateFormatter` patterns parses. The
failure cleared on its own and the offending body was never captured, so
which of those it was is unknown.

**Why deferring is acceptable:** the script's purpose is to warn that the
response's SHAPE has moved, and at that it works — this is a widening,
not a correction. The immediate cost of the gap was diagnostic, and that
half is now closed: both decode sites log the underlying `DecodingError`,
so the next occurrence names its own field without anyone re-deriving it
by hand.

**What to build:** decode the live response through the real types rather
than comparing keys — the shipping decoder is the only authority on what
is decodable. A small executable target depending on `ClaudeUsage` and
`PlatformStatus` that decodes a fetched body and exits non-zero on a
thrown `DecodingError` would replace most of `compare-shape.py`'s
per-key logic, and would have named this failure in one run.

**Trigger:** the next unexplained "Unexpected response" that the new
error logging does not immediately explain, or any change to the two
sources' `Decodable` conformances.

---

## 6. Distinguish an unknown gauge from a 0% gauge

**Deferred:** making the session and week gauges render differently
for "cannot vouch for this reading" than for "reading is zero".

`IndicatorStore.usageReading` returns an unknown reading only through
`Reading.unknown(...)`, which fixes `percent` to nil, and
`Thresholds.state(forPercent:)` never returns `.unknown` from a real
percentage. So for a usage reading, `state == .unknown` exactly when
`percent == nil`, hence `GaugeSpec.fraction == nil`. `MenuBarIcon`'s
`draw(ring:)` and `draw(pie:)` both guard their coloured sweep behind
`fraction > 0` and call `color(for: gauge.tint)` only inside that
guard, so a nil fraction never reaches it: the track is drawn in a
fixed `labelColor` at 0.18 alpha regardless of tint. A 0% reading
takes the same path, since its fraction is also not greater than
zero. The consequence is that `GaugeSpec.tint == .dimmed` is
unreachable in the renderer, and the spec's "unknown → dimmed" row
(line 111) is not implemented for the two gauges — the dimmed tint
survives only in `accessibilityDescription`, which does distinguish
the two cases by describing an unknown gauge's state by name instead
of a percentage.

This was confirmed live on screen, not only by reading the code, and
it reads worse for the week gauge than the session gauge: the pie's
track is a full faint disc at any fraction, so an unknown week gauge
reads as "full" before its low alpha reads as "unknown".

**Why deferring is acceptable:** the accessibility description
already carries the distinction MonoCl needs to not actively lie —
VoiceOver announces "unknown" rather than "0 percent" — so the gap is
a sighted-reader ambiguity, not a case where the tool reports false
information. MonoCl is single-user, and its author now knows to read
the tooltip rather than the glyph alone when a gauge looks empty.

**What to build:** give the unknown state its own mark on the gauge
track — e.g. a hairline dash, a distinct track alpha, or a small
glyph — so `draw(ring:)` and `draw(pie:)` branch on `gauge.fraction
== nil` before falling back to the fixed track colour, the way
`draw(dot:)` already branches on fill to tell a ring from a disc.

**Trigger:** the collision causing a real misreading in daily use, or
any change that gives the gauges a use case where zero usage and
unknown usage need to be told apart at a glance.
