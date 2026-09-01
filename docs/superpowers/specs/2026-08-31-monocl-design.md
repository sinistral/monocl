# MonoCl design

Date: 2026-08-31
Status: approved for planning

MonoCl ("monocle") is a macOS menu bar application that displays the
user's Claude status as three circular lights: session usage, weekly
usage, and Claude platform status. Lights are monochrome until a
configurable threshold is breached. Hovering shows the current values.

## Scope

MonoCl is a personal, single-user tool for its author's own machine. It
is built and installed locally, ad-hoc signed, and is not distributed.

### Non-goals

- Mac App Store distribution, notarization, or a signed release channel
- Multi-user onboarding, consent flows, or first-run credential setup
- Any write to Claude Code's state, credentials included
- Inference, chat, or any interaction with Claude beyond reading usage
- Notifications, alerts, badges, or a Dock presence

## Policy context, recorded deliberately

MonoCl reads the OAuth access token that Claude Code stores in the
macOS login keychain and calls an undocumented endpoint with it.
Anthropic's published guidance directs third-party software to API key
authentication through Claude Console, and prohibits third-party tools
that "misrepresent their identity to Anthropic's servers, attempt to
route third-party traffic against subscription limits, or otherwise
violate applicable terms or policies".

Two limbs, assessed separately:

- **Routing traffic against subscription limits: no.** The endpoint is
  a read-only metadata request. It consumes no tokens and performs no
  inference.
- **Misrepresenting identity: yes.** Presenting Claude Code's
  credential from another process is indistinguishable, server-side,
  from Claude Code itself.

No compliant alternative produces the data. A Console API key has no
five-hour or weekly window to report, because those are subscription
concepts. Claude Code's status line receives the same figures, but
only refreshes while Claude Code runs, which fails a menu bar
indicator's core use: answering "do I have budget?" at an arbitrary
moment.

This is why MonoCl is not distributed. The exposure is one user reading
their own account's quota on their own machine. Should Anthropic refuse
the request server-side, MonoCl reports that plainly and backs off
rather than retrying (see Failure handling).

## Toolchain

| | |
|---|---|
| macOS | 26.6.2, SDK 26.5, deployment target 26.0 |
| Xcode / Swift | 26.6 / 6.3.3, language mode 6, strict concurrency complete |
| Bundle identifier | `net.sinistral.monocl` |
| Dependencies | none |
| Observation | `@Observable` |
| Tests | Swift Testing |

## Architecture

```
MonoCl.xcodeproj
  MonoCl/                    app target: LSUIElement, NSStatusItem,
                             NSMenu, SwiftUI Settings scene, rendering
  Packages/
    Indicators/              vocabulary and rules. Pure, no I/O.
    ClaudeUsage/             keychain read, usage endpoint, two Readings
    PlatformStatus/          status.claude.com, one Reading
```

Three local Swift packages. `ClaudeUsage` and `PlatformStatus` are
separate because they are genuinely different features: different
authentication, endpoints, cadence, and failure modes. Presentation
stays in the app target because it is inherently AppKit-wired and
small; a package for it would add ceremony without a boundary.

`Indicators` holds the shared vocabulary:

```swift
enum IndicatorState { case unknown, nominal, warning, critical }

struct Reading {
    let state: IndicatorState
    let detail: String
    let note: String?      // why this value may be ageing; nil normally
    let asOf: Date
}
```

`note` carries the reason a RETAINED value may be ageing — the failure's
own text when a network error or a rate limit has left the last good
sample standing. It exists because an unannotated retained number is the
one shape this design rules out: the reader cannot tell a fresh 62% from
a four-minute-old one, and the justification for keeping the value is
that it is still the best available truth, not that it is current.

The store emits atoms (`"62%"`, `"Offline"`) and each surface joins them
in its own style. Composing the joined string in the store would put
separator style in two places and leave neither surface in control.

Threshold evaluation is a pure function here: percentage plus
configured thresholds in, `IndicatorState` out.

Each source exposes one non-throwing method returning a summed outcome:
`func fetch(now: Date) async -> UsageOutcome` and `-> StatusOutcome`.
Failures are values in that outcome rather than thrown errors, because
every failure has a defined display consequence and none is exceptional.

Sources return raw samples, not resolved `Reading`s. Thresholds are
applied by the store, so moving a threshold in Settings re-renders
immediately rather than at the next poll — up to a full cadence later.

The protocol seams sit at the TRANSPORT boundary (`HTTPFetching`,
`StatusFetching`, `CredentialReading`), not at the source boundary. That
is the external-service carve-out where stubbing is sanctioned; the
decoding, the response types and the threshold rules are always the real
implementations. The refresh loop takes injected closures rather than a
source protocol. None of this is a pluggability mechanism; no second
implementation is planned.

## Data sources

### Claude usage

`GET https://api.anthropic.com/api/oauth/usage`

Response carries independently-optional windows:

```json
{ "five_hour": { "utilization": 18.0,
                 "resets_at": "2026-08-31T17:50:00.568709+00:00",
                 "limit_dollars": null, "used_dollars": null,
                 "remaining_dollars": null, "locked_reason": null },
  "seven_day": { "utilization": 14.0,
                 "resets_at": "2026-09-04T15:00:00.568730+00:00" } }
```

Verified against the live endpoint on 2026-08-31; see
`docs/superpowers/plans/2026-08-31-monocl.endpoint-contract.md`.

Two properties of this response were originally assumed from static
inspection of Claude Code's bundle and are now known to be different.
The bundle's status-line mapping
(`used_percentage: five_hour.utilization * 100`) operates on Claude
Code's **already-normalised internal state**, not on this response, so
reading it as a description of the endpoint was a mistake:

- **`utilization` is already a percentage**, 0 to 100. It is NOT
  multiplied.
- **`resets_at` is an ISO-8601 timestamp string** with fractional
  seconds and a UTC offset, not epoch seconds.

The request needs only a bearer token and `Content-Type`. The beta
identifier `anthropic-beta: oauth-2025-04-20` is **optional** — the
endpoint returns 200 with and without it — so MonoCl does not send it.

The response carries many more top-level keys than MonoCl consumes,
including per-model weekly windows, spend and extra-usage objects, and
several that appear to be internal feature flags. Only `five_hour` and
`seven_day` are read. Every other key is ignored, and the key set must
be expected to change without notice.

### Platform status

`GET https://status.claude.com/api/v2/summary.json`

Public, unauthenticated Statuspage. Mapping:

| `status.indicator` | MonoCl | Tooltip |
|---|---|---|
| `none` | nominal | `status.description` verbatim |
| `minor` | warning | `status.description` verbatim |
| `major`, `critical` | critical | `status.description` verbatim |
| absent or unparseable | unknown | "Platform status unavailable" |

`status.description` is repeated verbatim so MonoCl never invents a
characterization of an incident.

## Credential handling

The credential lives in the login keychain under service
`Claude Code-credentials`, account `NSUserName()`. The record's
schema:

```
{ accessToken, refreshToken, expiresAt, refreshTokenExpiresAt,
  scopes, subscriptionType, rateLimitTier, clientId }
```

`expiresAt` was observed as a 13-digit value, i.e. epoch
**milliseconds**. The unit is undocumented, so the decoder also accepts
epoch seconds rather than relying on that observation holding.

### MonoCl is strictly read-only

MonoCl never writes the keychain and never refreshes the token.

Access tokens live hours, and Claude Code's refresh path saves a new
`refreshToken` from each response under a compare-and-swap, which means
refresh tokens rotate. A MonoCl-side refresh would therefore
invalidate the copy Claude Code holds and break the user's login. The
failure would be a race, surfacing when both processes are most
active, and its symptom would be the primary tool breaking. A menu bar
ornament must not be able to do that.

The consequence is accepted: after an idle stretch the usage lights are
blank until Claude Code next runs. `DEFERRED.md` item 1 covers
explaining that state to the user.

The keychain is re-read every refresh cycle rather than cached, because
that is the only way MonoCl picks up a token Claude Code has rotated.

`expiresAt` gates the request: if the stored token has expired, MonoCl
issues no request at all. This is cheaper and never exercises the
401-refresh path that has been deliberately excluded.

The token is read fresh from the keychain on each poll, used to build
one request, and released when that request returns. It is never
persisted, never logged at any level — not redacted — and never reaches
a serialised form: `StoredCredential` is deliberately not `Encodable`,
and both `description` and `debugDescription` report `<redacted>` in
place of the token, so a `dump()` or a string interpolation of the
record cannot leak it. `URLSession` uses an ephemeral configuration, so
no credential, cookie or cache from the request reaches disk.

What this does not claim: the token is necessarily a `String` in memory
for the lifetime of one request, because no HTTP header can be set
without one. The guarantee is about persistence, logging and
serialisation, not about its absence from process memory. A crash report
captured mid-request could in principle contain it; nothing MonoCl does
makes that more likely, and no lesser design avoids it.

An earlier draft of this section claimed the token was "never stored in
a property, interpolated into a string, or logged". The first two were
false when written — `StoredCredential.accessToken` is a stored property
and is interpolated to build the header — and an unachievable absolute
in a security section is worse than a weaker true one, because a reader
trusts it and stops checking.

## Refresh and staleness

Two independent pollers; neither can blank or slow the other.

Base cadence 5 minutes, configurable down to 1 minute. Additional
refresh triggers: app launch, `NSWorkspace.didWakeNotification`, and an
explicit "Refresh now". Sleeps carry 10% tolerance
(`Task.sleep(for:tolerance:)`) so the OS can coalesce timers and an idle
Mac stays idle.

**Opening the menu does not fetch.** It re-renders, which is what keeps
the displayed value honest, and nothing more. A fetch there hands the
request rate to a gesture made for unrelated reasons — the menu is how
the user reaches Quit and Settings — and one open a minute against a
five-minute cadence is five times the traffic the setting asks for.
Opening it to check a number is served by the staleness rule, which
says outright when the reading is too old to trust, and by "Refresh
now" one click away.

The cadence is set by the endpoint's tolerance, not the display's
appetite. The windows being reported span five hours and seven days, so
even a minute resolves them more finely than the data changes, and
`api/oauth/usage` answers 429 to a caller that asks too often.

**No request may land within `minimumRefreshInterval` of the last one**,
whichever trigger asked for it. Every trigger reaches the endpoint
through `Refresher.start()`, so the floor is enforced there rather than
at the four call sites: the request rate is then a property of the
refresher, and adding a fifth trigger cannot raise it. A trigger that
arrives inside the floor is deferred to the end of it, never dropped —
"Refresh now" always refreshes, just not necessarily this instant. The
backoff is a separate mechanism layered on top, and only ever lengthens
the wait; because it reacts to failures it bounds nothing at all while
every poll succeeds, which is precisely the case that earns a 429.

A restarted loop's first request also waits out any `Retry-After` the
endpoint last supplied. The spacing is MonoCl's own politeness and the
backoff is its reaction to failure, but `Retry-After` is the server
stating a limit outright, so no trigger may step over it — least of all
waking, which restarts both pollers with no user involved. It is held
as the INSTANT it elapses, not as a duration: every trigger restarts
the poller, so a duration would be re-armed in full each time, and a
menu opened periodically through a long `Retry-After` would push the
deadline out indefinitely.

While a refresh the user ASKED FOR is outstanding — deferred or in
flight — the menu replaces its "Refresh now" command with a disabled
"Refreshing…" row. Otherwise the
deferral is indistinguishable from a dead button: the user clicks,
nothing visibly happens for up to a minute, and the reasonable
conclusion is that the app is broken rather than that it is being
polite. Every request off the cadence is one somebody asked for, so
there is no second kind to tell apart.

The row covers the fetch itself and not merely the wait before it.
Re-enabling the command mid-request invites a second click, and that
click restarts the poller — cancelling a fetch that was about to land
and deferring its replacement by a whole spacing.

The menu carries one refresh command for two independent pollers, and
ANY poller waiting takes the command away. The alternative — keeping it
while either poller could still act — was tried and is worse: only the
usage poller is ever rate limited, so for the hour a `Retry-After` can
last it leaves a live "Refresh now" that cannot move the two rows the
user came to read. It would still refresh the platform row, so it is a
partial command rather than a dead one — but partial in exactly the
half nobody opened the menu for.

The cost is that platform status cannot be refreshed BY HAND while
usage is rate limited. It keeps polling on its own cadence throughout,
so nothing goes stale; only the button is unavailable, and only until
usage next gets an answer that is not a refusal.

**The row follows the rate limit, not the request.** The limit outlives
any one click: for as long as it stands, no refresh of usage can
succeed, whether or not anyone has asked. Deriving the row from an
outstanding request instead leaves the command live through most of the
window — the poller sleeps out the limit on its ordinary cadence with
nothing pending — so the first click of the hour would still meet a
command that cannot help. `Refresher` therefore reports only WHETHER a
requested refresh is outstanding, never why.

It is keyed on the last usage FAILURE, not on the `Retry-After`
deadline the scheduler holds, because a 429 need not carry a parseable
header: `rateLimited(retryAfter: nil)` is a real outcome, and MonoCl is
no less rate limited for not being told how long. That is also the
fact the Session and Week rows report, so the menu cannot read one and
show the other. It clears when usage next gets an answer that is not a
refusal, which is the same instant those rows stop saying it.

A request arriving while one is outstanding is IGNORED rather than
restarted, which covers the commands the row does not withdraw —
"Retry" above all. It does NOT cover a fetch the CADENCE started:
nothing is pending then, so a click landing in that window cancels it,
costing a spacing and a flashed "Offline". That window is one fetch
every five minutes, and closing it means tracking in-flight state that
a restart would race on — more machinery than the fault is worth.

**The row names which wait it is.** A spacing deferral is at most a
minute and reads honestly as "Refreshing…"; a `Retry-After` can be an
hour — the endpoint was observed returning 3372 seconds — and an hour
of "Refreshing…" is a claim the app cannot support, sitting directly
under two rows that say "Rate limited". That case reads "Waiting out
the rate limit" instead. Hence one value rather than a flag plus a
reason: the menu has one row to fill, and a pair of booleans admits a
state that is both.

**Every trigger is deliberate, so every trigger resets the backoff.**
"Refresh now" and wake are the only two, and both are acts, not
by-products. That is the whole reason the menu does not fetch: an
incidental trigger would have to be told apart from a deliberate one at
every point that touches the schedule — the failure count, the pending
row, the ordering of render against fetch — and each of those
distinctions is a place to get it wrong. Removing the trigger removes
the distinction.

A reading is trusted only while all three hold; otherwise the light is
`.unknown`:

| | |
|---|---|
| Age | `now - asOf < staleAfter`, default 15 minutes, never below two poll intervals |
| Token | `expiresAt` in the future |
| Window | `resets_at` in the future |

The window condition mirrors Claude Code, which drops any window whose
`resets_at` has passed rather than displaying a value it knows is void.

The age budget spans several cycles deliberately. A single failed poll
must not blank a light: transient blips are common, and a dot
flickering to gray and back teaches the user to ignore it. That is why
`staleAfter` is clamped on read to at least twice the cadence: a budget
shorter than the interval would expire every reading before its
replacement arrived. The clamp masks the stored value rather than
overwriting it, so shortening the interval restores the user's own
choice — the same rule the critical threshold follows.

### State lifecycle

| | `Reading`, per indicator |
|---|---|
| **written by** | every `revalidate(now:)`, rebuilt from scratch from the held sample |
| **read by** | dot renderer (state to color), tooltip composer (detail, `note`, `asOf`), NSMenu items |
| **cleared by** | age exceeding `staleAfter`; `expiresAt` passing; `resets_at` passing; `didWakeNotification`, before the post-wake fetch returns; a failure whose row in the table above says `.unknown`; process exit |

| | `isRefreshPending`, per refresher |
|---|---|
| **written by** | `Refresher.start()`; every caller of `start()` — launching, "Refresh now", waking — is a fetch in its own right, never the next turn of the loop |
| **read by** | `refreshNow()`, which drops a request already being served; `PendingRefresh.forMenu`, which turns both pollers' answers plus `store.isUsageRateLimited` into the row |
| **cleared by** | the refresh task once its fetch returns, unless cancelled meanwhile; `stop()`, since a cancelled tick will never land |

The displayed `PendingRefresh` is derived, not stored, so it needs no
row of its own here: it is recomputed on every render from this flag
and `rateLimitedUntil`, and cannot go stale independently of them.

The ordinary cadence is not pending: nobody asked for it, and
announcing it would leave the row showing almost permanently and say
nothing.

`Reading` is rebuilt on every `revalidate` rather than mutated, so `note`
needs no clearing step of its own: it is derived each time and cannot
accumulate. That is the whole reason it is safe to add — a field with an
empty "cleared by" column is the defect this table exists to catch.

**A failed poll does not, by itself, clear the sample.** Only the
failures whose table row says `.unknown` do. A network error or a rate
limit leaves the last good sample in place until its age budget expires,
because a single dropped packet greying every light for a minute and
back is the flicker that teaches a reader to ignore the indicator.

Because a retained value can therefore outlive the poll that produced
it, the display must be revalidated when its trust expires rather than
only when the next poll lands — the poll cadence stretches to the
15-minute backoff cap, and a dot showing amber for a reading the
staleness rule would reject is precisely what the colour rule exists to
prevent. Every trusted reading already knows the instant it stops being
trusted: the earliest of `asOf + staleAfter`, the token's expiry, and
the window's reset. A single self-cancelling timer armed for that
instant is sufficient, and must be independent of the fetch cadence —
coupling them would cap the backoff and defeat its purpose.

Nothing is persisted across launches. A relaunch starts blank rather
than resurrecting a reading from an unknown point in the past. Clearing
on wake matters because a laptop opened after eight hours holds a
reading that is confidently wrong, and the wake notification arrives
before the replacement does.

## Rendering

> **Superseded** by
> `docs/superpowers/specs/2026-09-01-menu-bar-gauges-design.md`. The
> three dots described below were replaced by two percentage gauges
> and a platform dot. Everything above this section still holds.

One `NSStatusItem`, one image, three dots, fixed order: session,
weekly, platform.

A single item rather than three, because macOS lets the user rearrange
status items freely. With three items the specified left-to-right
ordering would be a suggestion the system may violate, and a light
whose meaning depends on an unguaranteed position is worse than no
light.

Height from `NSStatusBar.system.thickness`, never hardcoded. Dots 8 pt
diameter, 4 pt gaps. Drawn via `NSImage(size:flipped:drawingHandler:)`
so the image redraws on appearance changes.

### Template images

| Case | Image | Consequence |
|---|---|---|
| All nominal | `isTemplate = true` | System handles light/dark, menu bar tinting, Reduce Transparency, menu-open inversion |
| Any breached | `isTemplate = false` | Colors survive; MonoCl resolves the monochrome dots itself |

In the non-template case the base color resolves from
`statusItem.button!.effectiveAppearance`, not the app's appearance,
which differs from the menu bar's. This gives the common case perfect
system behavior for free and accepts explicit drawing in the rare case,
where a fixed color is what is wanted anyway.

### Color is not the only encoder

> **Superseded.** The shape table below describes the three-dot icon.
> The gauges encode severity as a count of cut slots instead, and do
> not consult the system setting — see the successor spec for why.

Amber against red is the most confusable pair for viewers with color
vision deficiency, and the entire signal rides on it. MonoCl honors the
system setting rather than inventing its own:
`NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor`,
observed via
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` so it
applies without relaunch.

| State | Color | Shape when differentiating without color |
|---|---|---|
| unknown | dimmed | faint ring |
| nominal | monochrome | thin ring |
| warning | amber | filled |
| critical | red | filled, notched at top |

Tooltip and menu always carry words, so the reading is never
color-dependent where text is available.

### Tooltip

```
Session   47%  ·  resets 14:20
Week      62%  ·  resets Mon 09:00
Platform  All Systems Operational
```

An unknown line reads `—  no recent reading`, never a stale number.

## Thresholds and settings

One shared pair for both usage lights, in `UserDefaults`:

| Setting | Default |
|---|---|
| Warning threshold | 75% |
| Critical threshold | 90% |
| Refresh interval | 5 minutes (range 1–15 minutes) |
| Stale after | 15 minutes (never below two refresh intervals) |

Comparisons are inclusive: `>= 75` is warning, `>= 90` is critical. So
74.9 is nominal, 75.0 is warning, 89.9 is warning, 90.0 is critical.

Not per-light thresholds: there is no reason the session and weekly
windows would want different tolerances, and the extra settings rows
earn nothing.

Settings are a SwiftUI `Settings` scene in an `NSHostingController`.

## Failure handling

**Governing rule: color means the user's usage is high. It never means
MonoCl is unhappy.** Every failure resolves to `.unknown` — dim,
monochrome — and is reported in words in the tooltip and menu. A light
that turns red because a DNS lookup failed trains the user to distrust
it, and the one time it turns red for the real reason they will dismiss
it.

| Failure | Detection | Response | Menu text |
|---|---|---|---|
| Keychain item absent | `errSecItemNotFound` | `.unknown`, stop polling usage | "Claude Code credentials not found" |
| Keychain access denied | `errSecAuthFailed` or user cancel | `.unknown`, stop polling, manual retry only | "Keychain access denied — Retry" |
| Keychain unavailable | any other `OSStatus` | `.unknown`, keep polling with backoff | "Keychain unavailable" |
| Keychain record unreadable | credential JSON fails to decode | `.unknown`, stop polling, manual retry only | "Claude Code credentials unreadable" |
| Token expired | `expiresAt` in past | `.unknown`, no request issued | "Run Claude Code to refresh" |
| Network or timeout | `URLError` | Keep last reading until `staleAfter`, then `.unknown` | "Offline" |
| 401 | HTTP status | `.unknown`, treat as expired, back off | "Authorization rejected" |
| 403 | HTTP status | `.unknown`, back off to cap | "Access refused by Anthropic" |
| 429 | HTTP status | Back off, honor `Retry-After` | "Rate limited" |
| Window absent | Decoding | That window `.unknown`; the other still renders | "No session data" |
| Malformed response | Decoding | `.unknown`, log, back off | "Unexpected response" |

Two entries need their reasoning recorded.

**Keychain denial is sticky for the session.** Reading another app's
keychain item can raise the system authorization dialog. Retrying on a
60-second timer after the user clicks Deny would throw a modal dialog
at them every minute until they force-quit. Denial therefore stops the
usage poller; the menu offers an explicit Retry and nothing re-prompts
unasked.

**403 is treated as an answer, not an error.** MonoCl reads this
endpoint outside Anthropic's stated guidance. If that use is refused
server-side, the correct response is to say so and back off to the cap,
not to retry every minute and make a policy signal indistinguishable
from abuse.

**A malformed keychain record is not an endpoint problem.** If the
stored credential fails to decode, the fault is local, and reporting
"Unexpected response" would point the user at Anthropic's endpoint for a
file on their own machine. It is sticky, because Claude Code will not
rewrite the record in response to MonoCl polling it, so retrying to the
backoff cap achieves nothing.

**An unexpected keychain status is NOT treated as denial.** Only
`errSecAuthFailed`, user cancellation and `errSecInteractionNotAllowed`
mean the user declined or the keychain cannot prompt; those are sticky,
because retrying them on a timer is what produces a dialog every minute.
Every other `OSStatus` — a locked keychain during login, `errSecNotAvailable`,
an I/O failure — is transient, and collapsing it into denial would do two
harmful things at once: halt polling permanently for a condition that has
since cleared, and tell the user "Keychain access denied", which is a
false explanation. A wrong attribution is worse than an admitted absence,
because it ends the reader's investigation. So unexpected statuses report
"Keychain unavailable" and keep polling under the normal backoff.

Backoff is exponential from the base interval to a 15-minute cap, reset
on success or explicit refresh. The two sources back off independently.

Logging uses `Logger` from OSLog, subsystem `net.sinistral.monocl`, one
category per package. No credential material is logged at any level —
not redacted, not logged.

No alerts, notifications, or badges. Every failure is legible on hover
and none interrupt.

## Testing

| Target | Approach |
|---|---|
| Threshold evaluation | Pure function, exhaustive boundaries |
| Staleness rule | Pure function of `(asOf, now, expiresAt, resetsAt)` |
| Response decoding | Real `JSONDecoder`, captured fixtures |
| Refresh state machine | Fake source, network carve-out |
| Dot specification | Pure `[IndicatorState] -> [DotSpec]` |
| Tooltip composition | Pure function to exact strings |
| Backoff | Pure function of failure count |

Assertions state the specific expected outcome, never the absence of an
unwanted one. Threshold cases include 74.9, 75.0, 75.1, 89.9, 90.0,
90.1, 0, 100, and 120. The last is defensive rather than expected:
nothing in the consumed response is documented to exceed 100%, so the
threshold function must not assume a ceiling it cannot enforce.

Rendering is tested at the specification, not the pixels: a pure
function decides color, shape, and the `isTemplate` flag, and only the
final Core Graphics call consumes it. Asserting "any breach implies
`isTemplate == false`" is the real contract, needs no snapshot
dependency, and survives appearance changes.

### Coverage gaps, stated plainly

- **The keychain read is not covered by automated tests.** It requires
  the real login keychain, a real Claude Code credential, and an
  interactive authorization grant, so it cannot run unattended.
  `SecItem` is not mocked: a mocked keychain would pass while the real
  call fails on precisely the ACL semantics that make this hard. The
  read is verified manually, and the implementation plan names that as
  an explicit manual step rather than letting it appear covered.
- **No test touches the network.** Fixtures are captured once by hand
  from real responses.

The second gap has a consequence: **fixtures rot silently.** If a
response shape changes, tests keep passing while the app breaks.
Mitigation is a separate opt-in check that hits both live endpoints and
asserts the fixtures still match the live shape, run deliberately. It
must never join the default suite, which would become
network-dependent and flaky.

Suite output is captured to a file rather than piped through a filter:

```bash
swift test --package-path Packages/Indicators > "$SCRATCH/indicators.log" 2>&1; echo "exit=$?"
```

## Risk

**What this could break.** MonoCl reads Claude Code's credential and
calls an undocumented endpoint. The realistic blast radius is MonoCl
itself showing blank lights: the strict read-only policy means it
cannot corrupt Claude Code's login, and the endpoint consumes no quota.
The residual risks are that Anthropic changes or refuses the endpoint,
and that reading the credential is outside published guidance.

**What has been done about it.** The write policy is a design
invariant, not a convention, and it is justified above from the
observed token rotation behavior. Every failure mode resolves to an
honest `.unknown` rather than a stale or invented value, with the state
lifecycle enumerated so no path leaves a reading uncleared. Refusal by
Anthropic is handled as a first-class outcome with backoff. The tool is
not distributed, so the exposure stays with its author.

**Not executed.** The endpoint's request contract and response shape
have now been verified against a live request (2026-08-31), which
corrected two assumptions this document originally carried — see the
Claude usage section. Everything else asserted here about Claude Code's
behavior still comes from static inspection of the on-disk 2.1.251
bundle and Anthropic's published documentation, not from observing it
run: in particular the claim that refresh tokens rotate is read from
the refresh code path, not watched rotating.

## Deferred

See `DEFERRED.md`:

1. Report token expiration to the user
2. Mirror indicator order in right-to-left locales
