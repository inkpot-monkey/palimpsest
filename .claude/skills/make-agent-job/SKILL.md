---
name: make-agent-job
description: Design a hermes agent job and scaffold it up to the handover line. Use when adding scheduled work on rk1b — a recurring check, watch, digest, or recheck whose output wants judgement rather than a threshold.
---

# Make an agent job

An **agent job** is scheduled work the hermes gateway owns, which may invoke a model. This skill
takes one from "I want something that runs daily" to a handover line you paste. It stops there:
creating the job is a human act on a live host.

Facts, flags, channels and the handover checklist live in `docs/agents/agent-jobs.md`. Read it
at step 3 — the steps below assume it rather than repeat it.

## 1. Grill it

Invoke the `grilling` skill on the job. Work the frontier until it is empty.

The questions this job cannot be built without:

- What changes in the world, and how would a script notice?
- What does the model decide that a threshold cannot?
- What does the job write, and who else writes there?
- Who reads the output, and what do they do next?

**Done when** every one has an answer the user gave, and the frontier is empty.

## 2. Find the boundary

Separate what **detects** from what **judges**. Detection is deterministic and belongs in a
script; judgement is the only reason a model is in this job at all.

Run the test out loud: *if the model were removed, what would stop working?* An answer like
"the notification would be noisier" names a real judgement. An answer like "nothing" means this
is a watcher, and it belongs in the systemd tier with the DMARC and secret-expiry checks, not
here. Say so and stop.

Bookkeeping that needs no model gets split into its own `--no-agent` job rather than widening
this one.

**Done when** the user has agreed a one-sentence statement of what the model judges, and what
the script detects without it.

## 3. Write the source script

Read `docs/agents/agent-jobs.md`, then write the script to
`$HERMES_HOME/scripts/<job>.{py,sh}`.

Hold two properties, because the mode depends on them:

- **Stable bytes.** `--monitor-script` hashes exact output; a timestamp in it means the model
  runs every tick and the suppression is dead.
- **Silence on quiet.** No change produces no output.

Run it twice against the live world and compare the bytes.

**Done when** two consecutive runs are byte-identical on an unchanged world, and the user has
seen its output on a changed one.

## 4. Choose declared or mutable

A source script is **mutable by default**, so hermes can improve it. Declaring it through
`hermesHomeFiles` freezes it — activation overwrites — and buys review and rollback.

Declare it when the job writes outside the agent's own state or acts on the fleet. Leave it
mutable when the job reads and reports.

Put the choice to the user as a choice, with which side this job falls on and why.

**Done when** the user has stated the side, and it is written in the index entry at step 5.

## 5. Scaffold

Produce all four, filled in:

- **The issue** on `inkpot-monkey/palimpsest` carrying the job's reasoning — the grill's
  conclusions, the boundary from step 2, the choice from step 4. See
  `docs/agents/issue-tracker.md`.
- **The index entry** for `docs/agent-jobs.md`: name, issue, channel, declared-or-mutable.
- **The channel**: the per-job Matrix room, and `--failure-deliver` pointed at Infra Alerts.
- **The handover line**: the literal `hermes cron create …` command, every flag resolved, ready
  to paste.

**Done when** all four exist, and the handover line names a real script path, a real room and a
real schedule.

## 6. Hand over

Walk the handover checklist in `docs/agents/agent-jobs.md` and report it **evidenced** — each
line with what makes it true, not a tick.

Then give the user the handover line and stop. Running it is theirs: it is the one imperative
act in this design, and it is where a human looks at the whole job once more.

**Done when** the user has the checklist and the line, and every checklist item carries its
evidence.
