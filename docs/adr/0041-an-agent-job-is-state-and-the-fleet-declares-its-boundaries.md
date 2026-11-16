# An agent job is state; the fleet declares its boundaries, not its schedule

The hermes gateway has run on rk1b since 2026-11-13 with **zero jobs**. Everything built so far
is the runtime: the dashboard at `agent.<domain>`, the model wiring, the credentials. The thing
it exists to do has not started, and the first attempt to start it ran straight into a conflict
this repo has not had to resolve before.

Every other recurring thing in this fleet is declarative. The watcher tier, the unit-state
check, the DMARC and TLSRPT pipelines, the secret-expiry check, the book filer — each is a
systemd timer whose schedule, script and alert path are all in the flake, reviewed in a diff and
reproducible from a clean host. That is the house style and it has earned its place.

Hermes is not shaped that way, and the mismatch is not an oversight upstream. It bills itself as
"the self-improving AI agent … it creates skills from experience, improves them during use,
nudges itself to persist knowledge". Its cron jobs live in `jobs.json` under the state directory
and are created with the CLI or the dashboard. There is no import, no export, and no flake
option. **Declaring that surface would disable the product.**

The naive readings both fail. "Declare everything" turns a learning agent into an expensive
systemd timer. "Declare nothing" puts a model with shell access on a schedule nobody reviewed.

**Decision: an agent job's schedule and prompt are state, owned by the gateway and created by
hand. The fleet declares the boundaries that job runs inside — the model, the permissions, the
instruction file, the PATH, the operator's skills directory — and the handover across that
boundary is a human act.**

## Why the schedule stays out of the flake

A reconciler is buildable. `hermes cron create` / `edit` / `remove` are ordinary commands, and a
systemd oneshot could drive them from a Nix attrset. It was considered and declined on two
counts.

The cheap count: there is no import or export, so the reconciler is ours to write and own —
diffing a declared set against a live `jobs.json`, deciding what an edit means versus a
recreate, and keeping that correct across upstream schema changes.

The count that actually decides it: the schedule is the least valuable thing to protect. It is
one line, recreated in seconds from the job's issue. What a declared schedule buys is review,
and review is already bought elsewhere — by the issue that exists before the job does, and by
the index in `docs/agent-jobs.md`. What it would cost is a reconciler fighting an agent that is
designed to change its own state.

**`jobs.json` is backed up instead.** `/persistent/var/lib/hermes` is in rk1b's daily restic
job, and the backup entry already said why before this ADR existed: *"the one thing here that
the flake CANNOT rebuild"*. Do not declare the learning; back it up.

## The boundary, stated

Declared in the flake, reviewed in a diff:

- the model and provider, the permission policy, `dashboard.public_url`
- the credentials, through sops
- the unit's PATH — what the agent's shell can reach at all
- the instruction file (`AGENTS.md` in the working directory, and at `$HOME`)
- `skills.external_dirs`, the read-only directory for operator-authored skills

Owned by the agent, never declared:

- `skills/` and `skills.create_dir` — the learning loop
- `memories/`, `sessions/`, `state.db` — recall across runs
- `SOUL.md` — seeded by upstream, refined in place
- each job's `notepad` — durable state between runs
- `jobs.json` — the schedule

The seam is upstream's own: `external_dirs` is read, `create_dir` is written. Declaring a skill
into `skills/` would collide with the agent writing there and be overwritten on activation.

## Three writers, never one table

A job that produces findings a human then judges has **three** writers, not two: the job writes
*findings*, the operator writes *judgements*, and the agent writes *assessments*. ADR-0038's
rule generalises — *one owner per file is what makes a daily automated writer safe next to a
human editor* — and the failure it prevents is concrete: a ranking silently clobbered by the
next ingest.

So a job's store is one database with disjoint tables by writer, joined on a key. Never one
table all three update.

## The agent owns data; a human owns presentation

Three surfaces, and the ownership is constant across all of them:

| The output is | Surface | The agent writes |
| --- | --- | --- |
| time-series | in-tree Grafana board | the metric, via the node-exporter textfile collector |
| prose or findings needing a URL | static file served by Caddy | the file |
| something to act on — approve, rank, dismiss | one shared in-tree Streamlit app | only the data the page reads |

Grafana was the default answer and survives for time-series: a board is one JSON file with no
unit, port, vhost or probe behind it. It loses where a surface must take a judgement *back*,
because a provisioned board is read-only by construction — `/var/lib/grafana` sits in
`notBackedUp` precisely so that a UI-authored board cannot become a second source of truth.

Streamlit was considered for the whole tier and declined as a default. Its real advantage is
that the artifact is Python, which an agent writes and can verify by running, where Grafana JSON
is schema-heavy and unverifiable without the preview loop. Its disqualifying property is the
same fact: **a Streamlit app is code running as a service**, reachable, persistent, outside any
session. An agent that owns one is authoring code that executes unattended, which is a larger
version of the hazard this ADR closes below. And it does not escape the promotion tension — it
sharpens it: in-tree so it can be reviewed means the agent cannot edit it, and mutable so the
agent can own it means undeclared agent-written code serving HTTP.

So the app is in-tree and human-owned, one service with a page per job rather than a service per
job, and what the agent owns is the rows it reads.

## Unattended scheduling stays off

`cron.allow_agent_scheduling` is `false` by default — upstream's words, *"policy-denied in cron
context to prevent unattended scheduling loops"*. It stays off. An agent may improve a job's
prompt from an interactive session, where a human is present; nothing unattended grows the
schedule. Turning it on is a decision a specific job has to earn, never a side effect of wanting
prompt self-improvement.

## What this costs

A job is invisible to anyone reading the flake. `hermes cron list` on a live host is the only
authority on what exists. That is the same invisibility the backup entry already worries about
for UI-authored dashboards, and it is paid for deliberately: `docs/agent-jobs.md` indexes what
exists and why, without becoming a second source of truth for *when* it runs.

A job that silently stops firing is not caught by the gateway being `active` — the blind spot
that cost six days on the failed-units canary. A deterministic check in the watcher tier reads
hermes's own `ticker_last_success` and each job's last run, and alerts when one is overdue. It
is deliberately not an agent job: an agent job that watches agent jobs fails silently in exactly
the same way.

## See also

- [ADR-0038](0038-held-back-packages-are-a-registry-an-agent-rechecks.md) — the doctrine this
  inherits: the model judges what moved and never detects. Its holds recheck is the first agent
  job this ADR governs.
- `docs/agents/agent-jobs.md` — the operational reference, including the handover checklist.
- `GLOSSARY.md` → **Agent job**, **Source script**.
