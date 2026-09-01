# MonoCl

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
Hovering gives the numbers and reset times; the menu gives them in
words, plus "Refresh now", Settings, and Quit.

Color only ever means *your usage is high*. It never means MonoCl is
unhappy: every failure resolves to a dim, unknown state and explains
itself in words.

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
`/Applications` and launch it. The first run asks for keychain access
(see below).

Tests live in four local Swift packages plus a host-run app suite:

```sh
swift test --package-path Packages/Indicators
swift test --package-path Packages/ClaudeUsage
swift test --package-path Packages/PlatformStatus
swift test --package-path Packages/Engine
xcodebuild -scheme MonoCl test
```

The suites are offline by construction. `Scripts/check-fixture-drift.sh`
is the deliberate, manual check that the captured fixtures still match
the live endpoints' shapes.

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
MonoCl reports that plainly and backs off to its cap rather than
retrying — a policy signal should not be made indistinguishable from
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

Because that item belongs to another application, macOS raises the
keychain authorization dialog the first time MonoCl asks for it. Ad-hoc
signing means the signature changes with every build, so a rebuilt
MonoCl is a different application as far as the keychain is concerned
and will ask again.

What MonoCl does with the token:

- **Reads only.** `KeychainCredentialReader` contains no `SecItemAdd`,
  `SecItemUpdate`, or `SecItemDelete`.
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
  cookie, or cache reaches disk.
- **Re-reads it every poll** rather than caching, because that is the
  only way to pick up a token Claude Code has rotated.
- **Checks expiry before asking.** If the stored token has expired,
  MonoCl issues no request at all.

What that does *not* claim: the token is necessarily a `String` in
memory for the lifetime of one request, because no HTTP header can be
set without one. The guarantee is about persistence, logging, and
serialization — not about absence from process memory.

If you decline the keychain dialog, MonoCl stops polling usage and
offers an explicit "Retry" in the menu. It will not re-prompt on a
timer; a modal dialog every minute is worse than a blank gauge.

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

## Documentation

Design documents and implementation plans live in `docs/superpowers/`;
`DEFERRED.md` records what was consciously left undone and why.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
