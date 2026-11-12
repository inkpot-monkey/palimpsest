# Packages held back from a flake bump are a registry an agent rechecks daily, not a comment

This repo bumps `flake.lock` roughly every two to three days — 127 commits touching it since
2025-11-22. Most bumps are uneventful. The ones that are not produce a *hold*: a package that
cannot move until something upstream changes, pinned in-tree with the reason written beside it.

Today that reason is a prose comment next to the pin, and the comments are good. The
`stable-until-fixed` block in `modules/shared/overlays/default.nix` names three packages, the
exact crate that broke each one (`aws-lc-sys`, `zstd-sys`, `libsqlite3-sys`), the shared cause
(nixpkgs moving Rust `*-sys` crates onto system libraries), the two alternatives that were
rejected and why, and — this is the part that matters — **the literal command that would tell
you whether the wait is over**:

```
gh search commits --repo NixOS/nixpkgs matrix-tuwunel
gh search commits --repo NixOS/nixpkgs "trunk zstd"
```

It also says, in capitals, `REMOVE ENTRIES AS UPSTREAM FIXES THEM — this is a waiting room, not an architecture`.

**Nothing runs those commands.** They will be run when someone next opens that file for an
unrelated reason, which is the definition of never. The waiting room has no door.

**Decision: every hold that can eventually clear is one entry in `docs/holds.md`, carrying a
machine-runnable probe and a human release condition; a daily agent on rk1b runs the probes and
writes its findings back into that file.**

## Why a markdown file is the registry, and not a Nix attrset

The obvious shape is `secrets/expiry.nix` — a Nix attrset, a flake check, a daily timer. It was
considered and rejected, for one reason: the reader here is an agent, and the thing it reads
and the thing it writes have to be the same artifact. A Nix attrset is cheap to evaluate and
expensive to write back to; a markdown file is the opposite, and writing back is the whole
point. A hold's most valuable field is the agent's last finding, which is prose.

The alternative that was rejected harder is scraping the Nix comments directly. It is grep-truth
over a syntax we have already been burned by reading with grep, and it is *silently incomplete*:
a hold is not always a pin with a version string in it. So the markdown is canonical and the
pin carries a one-line `# HOLD: docs/holds.md#anchor` pointer back, which makes the Nix comment
a signpost rather than a second source of truth.

## Only things that can become false live there

`holds.md` is not a list of every deviation from upstream. porcupineFish must run a `stable_*`
vendor kernel; `jmap-bridge` must track a release tag. No upstream event makes either false, so
a daily probe on them is work that can never pay. Those are standing laws and stay where they
already are — `AGENTS.md`, the host README, ADR-0016. A registry that mixes a to-do list with a
law book is a law book nobody finishes reading.

## This amends a previous verdict, deliberately

On 2026-06-25 a design for a general change-watcher concluded: *probe, diff, version-compare and
notify are all deterministic; AI adds value only as an optional human-facing change-summariser,
and even that belongs in a separate human-triggered tool, not the timer loop.* That reasoning
was right and still is. It is amended rather than overturned, because the split survives
intact — it just lands inside one job rather than across two systems.

Hermes (`modules/nixos/profiles/hermes.nix`) can run a **deterministic pre-run script before any
tokens are spent**, which is the property that won it the profile. So the probes stay
deterministic Python: parse `holds.md`, run each probe, diff against last-recorded state, and
invoke the model **only for holds whose probe tripped**. A quiet day costs approximately zero
tokens and produces a date stamp. The model never detects; it only judges and writes.

That boundary is load-bearing because of what is behind it. The gateway's default model is
`qwen3.8-27b` — capable of reading a release note, not a reliable authority on "is it safe to
unpin a federated homeserver". Two rules fence it in: **a tripped probe is a hard precondition
for a hold reaching `ready-to-drop`**, so the model can never promote something nothing moved
on; and its output is always a recommendation with evidence links, never a bare verdict. The
unpin itself stays a human action. A wrong recommendation therefore costs one wasted look, which
is a price worth paying for a waiting room with a door.

## What the agent is allowed to touch

One file. `holds.md` and nothing else — not the pins, not `CHANGELOG.md`, not the overlays.
One owner per file is what makes a daily automated writer safe next to a human editor.

It commits straight to `main`, because a daily pull request against a docs-only file is 365
notifications a year that CI has nothing to say about. When the rebase is not clean it **aborts
and alerts**; it never forces. "I could not write" is itself a state change worth hearing about.

Notification follows the same discipline as the rest of the fleet's watchers: on **state change
only** — a hold reaching `ready-to-drop`, a new hold opened, a probe failing repeatedly. Never
on "checked, still held". The evidence that the agent looked is the `last checked` date in the
file, not a message in `#infra-alerts`.

Which creates the one blind spot this design has, and it is the fleet's recurring one: a job
that is silent when healthy is indistinguishable from a job that has stopped. Hermes cron jobs
are not declarative — they live in `jobs.json` under the state directory — so a deploy cannot
prove the job exists either, and `hosts/rk1/backup.nix` already warns that a restored host
"would come up healthy, with the gateway running and nothing ever firing". A **deterministic**
daily check therefore alerts if the last-run stamp in `holds.md` is older than 48 hours. It is
the only part of this design that can detect the design failing.

## The changelog is the other half, and a human writes it

`CHANGELOG.md` at the repo root is the narrative: one entry per flake bump, dated, listing what
moved, what broke, what was held and what was released. It admits only fleet-visible change —
the test is "would I want to know this when something behaves oddly next month?" — and leaves
everything else to `git log`.

It is written by whoever performs the bump, as part of the bump commit, and the bump runbook
makes recording a new hold one of its steps. That is deliberate: the moment a hold is born is
the moment you have just been interrupted by a broken deploy and want to move on, which is
exactly when the knowledge is lost. Putting it in the runbook puts the pin and the entry in one
motion.

Cleared holds are never deleted. They move to a `## Cleared` section with the date and what
cleared them, because the expensive knowledge in a hold is the negative result — *snapcast
0.35.0 was tried and broke Music Assistant's teardown path* — and a deleted hold means the next
person re-pins blind, or walks into the same wall.
