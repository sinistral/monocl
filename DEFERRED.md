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

**Deferred:** reversing the left-to-right dot order (session, weekly,
platform) for locales that read right to left.

The brief specifies the ordering "for locales that read from left to
right", which implies the mirrored arrangement elsewhere. MonoCl is a
single-user personal tool built for a left-to-right locale, so
implementing the mirror now would be speculative work with no user.

**Why deferring is acceptable:** nothing else in the design has to
move to accommodate it later. The dot order is decided in one place —
the renderer that composes the three-dot image — so the change is a
single `NSApp.userInterfaceLayoutDirection` check at that point. No
data model, threshold rule, or tooltip logic depends on the order.

**What to build:** reverse the dot sequence when the effective layout
direction is right-to-left, and reverse the tooltip line order to
match, so the text and the dots agree.

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
