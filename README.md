# MonoCl

> | ˈmɒnəkl |
>
> noun 
>
>   a single eyeglass

A macOS menu bar app that shows your Claude usage at a glance: how much
of the five-hour session window you have spent, how much of the seven-day
window, and whether the Claude platform is healthy.

One status item, one glyph:

| Element | Form | Shows |
|---|---|---|
| Session | outer ring, sweeping clockwise from twelve o'clock | five-hour window utilization |
| Week | inner filled pie, same origin and direction | seven-day window utilization |
| Platform | dot to the right of the glyph | `status.claude.com` indicator |

The glyph is monochrome until a threshold is crossed (75% warning, 90%
critical by default), at which point it takes color *and* cuts radial
slots through the gauge — one for warning, two for critical — so the
severity survives for readers who cannot rely on the amber/red pair.
Hovering gives the numbers and how long until each window resets; the
menu gives them in words and adds the reset's clock time, plus "Refresh
now", Settings, and Quit. The platform row in the menu opens
`status.claude.com`, where the incident behind the summary is written
out.

Color only ever means *the thing being measured is in a bad state* —
your usage is high, or Anthropic has an incident open. It never means
MonoCl itself is unhappy: every failure resolves to a dim, unknown state
and explains itself in words. A light that turns red because a DNS
lookup failed teaches the reader to distrust it, and the one time it
turns red for the real reason they will dismiss it.

## Requirements

- macOS 26 or later (deployment target 26.0)
- Xcode 26 with Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `MonoCl.xcodeproj`
  is generated from `project.yml` and is not checked in
- Claude Code, signed in on the same machine

## Build and run

```sh
xcodegen generate
xcodebuild -scheme MonoCl -configuration Release build
```

Then copy the built `MonoCl.app` out of the derived-data path into
`/Applications` and launch it.

Tests live in five local Swift packages plus a host-run app suite:

```sh
swift test --package-path Packages/Indicators
swift test --package-path Packages/ClaudeUsage
swift test --package-path Packages/PlatformStatus
swift test --package-path Packages/Engine
swift test --package-path Packages/AppUpdate
xcodebuild -scheme MonoCl test
```

The suites are offline by construction. `Scripts/check-fixture-drift.sh`
is the deliberate, manual check that the captured fixtures still match
the live endpoints' shapes.

Formatting is gated by `swift-format`, which ships inside the Xcode
toolchain and so needs no separate install:

```sh
Scripts/check-format.sh        # report
Scripts/check-format.sh --fix  # rewrite in place
```

`.swift-format` holds the configuration. It sets the indent to four
spaces and takes every other rule from the tool's defaults, which are
the Swift standard style.

## Why there is no App Store build, and no signed release

MonoCl reads the OAuth access token that Claude Code stores in the macOS
login keychain, and calls an undocumented endpoint,
`GET https://api.anthropic.com/api/oauth/usage`, with it.

Anthropic's published guidance directs third-party software to API key
authentication through Claude Console, and prohibits third-party tools
that misrepresent their identity to Anthropic's servers, route
third-party traffic against subscription limits, or otherwise violate
applicable terms. Two limbs, assessed separately:

- **Routing traffic against subscription limits: no.** The endpoint is a
  read-only metadata request. It consumes no tokens and performs no
  inference.
- **Misrepresenting identity: yes.** Presenting Claude Code's credential
  from another process is indistinguishable, server-side, from Claude
  Code itself.

No compliant alternative produces the data. A Console API key has no
five-hour or weekly window to report, because those are subscription
concepts. Claude Code's own status line receives the same figures, but
only while Claude Code is running — which fails a menu bar indicator's
entire purpose: answering "do I have budget?" at an arbitrary moment.

So MonoCl is a personal tool, built and installed locally, ad-hoc
signed, and shipped as source only. There is no App Store listing, no
notarized release channel, and no binary to download. The exposure stays
what it is intended to be: one person reading their own account's quota
on their own machine, having read the paragraphs above and decided for
themselves. If Anthropic refuses the request server-side with a 403,
MonoCl reports that plainly and lets the exponential backoff stretch the
interval toward its fifteen-minute cap rather than hammering the
endpoint — a policy signal should not be made indistinguishable from
abuse.

There is a second, mechanical reason there is no App Store build: an App
Sandbox app cannot read another application's keychain item, and that
read is the whole feature. `ENABLE_APP_SANDBOX` is deliberately `NO`.

## Why keychain access is required

The five-hour and seven-day windows are properties of a Claude
subscription, and the endpoint that reports them authenticates with the
subscription's OAuth token. That token lives in the login keychain under
service `Claude Code-credentials`, account `NSUserName()`, written there
by Claude Code. Reading it is the only way to ask the question.

MonoCl does not ask the Security framework for that item. It runs
`/usr/bin/security find-generic-password`, the command Claude Code
itself uses to read its login, and decodes the record from its output.
No keychain dialog appears, on first launch or after a rebuild.

The obvious approach fails in a way that looks like flakiness, so the
reason is worth knowing. A keychain item's access control holds a list
of applications and a *partition list*. "Always Allow" adds the
requesting app to both, and an app with no Team ID — any self-signed or
ad-hoc build, MonoCl included — enters the partition list as
`cdhash:<hash>`, the hash of that exact binary. Two consequences follow,
both observed:

- **A rebuild asks again**, because the new binary has a new hash.
  Signing with a stable certificate does not change that.
- **Claude Code revokes the grant every time it saves a token.** It
  writes with `security add-generic-password -U`, and that update resets
  the partition list to `apple-tool:` alone. Claude Code refreshes its
  token several times a day, and each refresh made MonoCl's next poll
  raise the dialog again.

`/usr/bin/security` survives both, because Claude Code's own writes keep
it on the application list and keep its partition, `apple-tool:`, in
place. Running it makes `security`, not MonoCl, the process the keychain
checks.

This widens nothing. Any process running as you can already read the
item this way without a dialog, because that is how Claude Code's
writes leave it; the dialog MonoCl used to raise protected the token
from no one. It holds for as long as Claude Code writes the item with
`security`, as Claude Code 2.1.316 does on macOS 26.

What MonoCl does with the token:

- **Reads only.** The one command `KeychainCredentialReader` runs is
  `security find-generic-password`.
- **Never refreshes it.** Claude Code rotates refresh tokens under a
  compare-and-swap, so a MonoCl-side refresh would invalidate the copy
  Claude Code holds and break your login. The accepted consequence is
  that after an idle stretch the usage gauges go blank until Claude Code
  next runs. A menu bar ornament must not be able to break the tool it
  ornaments.
- **Never persists, logs, or serializes it.** `StoredCredential` is not
  `Encodable`, and both `description` and `debugDescription` report
  `<redacted>`, so a `dump()` or a string interpolation cannot leak it.
  `URLSession` runs on an ephemeral configuration, so no credential,
  cookie, or cache reaches disk. The token arrives over a pipe from
  `security`, never as a command-line argument, so no process listing
  shows it.
- **Re-reads it every poll** rather than caching, because that is the
  only way to pick up a token Claude Code has rotated.
- **Checks expiry before asking.** If the stored token has expired,
  MonoCl issues no request at all.

What that does *not* claim: the token is necessarily a `String` in
memory for the lifetime of one request, because no HTTP header can be
set without one. The guarantee is about persistence, logging, and
serialization — not about absence from process memory.

Should a keychain dialog ever appear — which takes the item's access
control being changed so that `security` itself must ask — and you
decline it, MonoCl stops polling usage and offers an explicit "Retry" in
the menu. It will not re-prompt on a timer; a modal dialog every minute
is worse than a blank gauge.

The platform status source needs no credential at all:
`https://status.claude.com/api/v2/summary.json` is public, and its
`description` is repeated verbatim so MonoCl never invents a
characterization of an incident.

## Polling

Five minutes by default, configurable from one to fifteen. Usage and
platform status poll independently; neither can blank or slow the other.
Additional triggers are launch, wake from sleep, and "Refresh now". No
request may land within the minimum spacing of the last one, whichever
trigger asked for it, and a `Retry-After` from the endpoint is honored
in full. Opening the menu re-renders but never fetches.

## Updates

MonoCl is built and installed by hand, so nothing would otherwise tell
you a newer version exists. Once a day, and once at launch, it asks
GitHub for the repository's latest release and compares the tag against
the running `CFBundleShortVersionString`. If the release is newer, a row
appears in the menu naming the version and opening the release page.

Notify-only: MonoCl installs nothing. The build is one you compiled, and
an updater that replaced it would be replacing your own work. There is
no notification and no mark on the status item either — the glyph means
"the thing being measured is in a bad state", and MonoCl wanting
attention is not that.

No failure is ever reported as a fault; the worst any of them produces
is the absence of a row. A settled answer — a repository with no release
yet, which answers 404 and is this one's ordinary state until the first
release is cut, or a tag that is not three whole numbers — means there
is nothing to offer. A check that did not complete, because you were
offline or rate-limited, means nothing at all: whatever was last known
still stands, so a moment without a network cannot retract a row that is
still true. An unsettled check is retried in fifteen minutes rather than
tomorrow, because the check most likely to fail is the one at launch,
before the network is up.

The request carries no credential, and `api.github.com` is the only host
MonoCl contacts that is not Anthropic's. The suites never contact it at
all: `MONOCL_SKIP_UPDATE_CHECK` is set on the test scheme, because the
test bundle is hosted by the app and the suites are offline by
construction.

## Documentation

Design documents and implementation plans live in `docs/superpowers/`.
`DEFERRED.md`, at the repository root, records what was consciously left
undone and why.

## Alternatives

 * **[CodexBar](https://github.com/steipete/CodexBar/):** Comprehensive
 Agent platform coverage.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

The one exception is the Claude flare in `Icon/monocl.svg`, which is
Anthropic's trademark rather than this project's work. It is a
redrawing rather than their own artwork, which changes nothing about
whose mark it is, and the BSD grant does not extend to it — see the
scope note at the foot of [LICENSE](LICENSE). It is a further reason
this is a local build rather than something published.
