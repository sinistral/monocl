---
name: releasing-monocl
description: Use when cutting, tagging or publishing a MonoCl release, editing release notes, or bumping MARKETING_VERSION — including when asked to "cut 0.x.y", "ship a release", or correct notes on a release already published.
---

# Releasing MonoCl

## Overview

Publishing is the **last** step, not the middle one. Everything a release
announces must have been observed before the release exists, because two
things here are effectively irreversible: a tag freezes the source it
points at, and a published claim has already been read.

The second principle is scarcer than it looks: **the update row can only
be observed once per release.** It appears only while the *installed*
build is older than the latest release. Install the new build before
looking, and the only chance is gone until the next version.

## The sequence

1. `git log <last-tag>..main --oneline` — what actually landed.
2. Bump `MARKETING_VERSION` in `project.yml`; bump
   `CURRENT_PROJECT_VERSION` with it. A tag whose build reports the
   *previous* version makes the app find its own release and offer an
   update to what is already running.
3. `xcodegen generate`, then the gates: `Scripts/check-format.sh`, the
   five package suites, `xcodebuild -scheme MonoCl test`.
4. Commit the bump on a branch; merge `--no-ff`.
5. `/code-review`, **before** pushing. Not after.
6. `git push origin main`.
7. **Leave the old build installed.** Do not install the new one yet.
8. `gh release create vX.Y.Z --notes-file …` — see the notes rule below.
9. **Relaunch the still-installed old build** and confirm the update row
   appears, naming the new version, opening the release page. Relaunching
   is required: a previous check that got a 404 is a *settled* answer
   cached for 24 hours, so an already-running app will not notice the
   release today.
10. Only now install the new build. Confirm the row is gone — the
    negative case — and that usage still reads.

## Release notes

Every sentence making a claim about behaviour must name the observation
behind it, or be cut. Notes written from a change's *intent* are how
v0.2.0 shipped "the permission survives both rebuilds and updates",
which measurement disproved half an hour later.

One class of claim cannot be verified first, and only one: the update
row itself, which needs a release to exist before it can appear. So
split the notes by what is checkable when. Everything else — what the
app does, what a setting changes, what a permission survives — is
verifiable before publishing and **must** be. The update mechanism is
verified at step 9, immediately after; until then the notes must not
assert it as observed, and if step 9 contradicts them, retract.

Correcting published notes is a **retraction, not a silent rewrite**:
say what the release claimed and why it was wrong. Notes are mutable;
the tag is not, so released source keeps the uncorrected text. If that
divergence matters, cut a patch release instead.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Installing the new build before observing the row | The feature's positive case can never be verified this release |
| Verifying only that the row is *absent* | Passes identically if the row is broken |
| Publishing, then verifying | The claim is already read by the time it is known to be false |
| Pushing, then reviewing | The gate exists to run before publication |
| Bumping only `MARKETING_VERSION` | Build number stops distinguishing builds |
| Assuming a running app will see a new release | A settled 404 is cached 24h; relaunch |
| Treating "cannot verify first" as licence to claim anything | Only the update row is unverifiable pre-publish; everything else is checkable |

## Red flags

- "I'll write the notes from the commit messages" — commits state intent.
- "The tests pass, so it works" — no test has ever seen the menu.
- "I'll correct the docs after tagging" — the tag keeps the old text.
