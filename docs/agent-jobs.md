# Agent jobs

What scheduled agent work exists on rk1b, and where its reasoning lives. One line per **agent
job** (`GLOSSARY.md`).

This index is deliberately **not** the schedule. When a job runs is `jobs.json`'s to say, read
with `hermes cron list`; an index that restated it would be a second source of truth that drifts
the first time someone edits a job in the dashboard. What lives here is what the scheduler
cannot tell you: why the job exists, who hears from it, and whether its **source script** is
frozen in the flake or left for the agent to improve.

How a job gets here: [ADR-0041](adr/0041-an-agent-job-is-state-and-the-fleet-declares-its-boundaries.md),
with the process in `.claude/skills/make-agent-job/` and the operational reference in
`docs/agents/agent-jobs.md`.

| Job | Issue | Channel | Source script |
| --- | --- | --- | --- |
| `property-watch` | forge `inkpotmonkey/property#4` | Matrix room **Property Watch** (`hermesRooms.rooms.property-watch`); failures to Infra Alerts | **declared** — `modules/nixos/profiles/property-watch.py` |

**Why that issue is not on palimpsest.** The process in `.claude/skills/make-agent-job/`
says an agent job's reasoning goes in an issue on `inkpot-monkey/palimpsest`. This repo is
public, and this job's reasoning is a buying brief — a budget, eleven target outcodes, and
what its owner will compromise on. That is a negotiating position whose most interested
reader is an estate agent on the other side of a bid. So the reasoning lives on the private
forge and the plumbing stays here. The departure is deliberate, not an oversight.

The same split runs through the job: the **source script is declared** in this public repo
because it is a fetcher and nothing about it is sensitive, while the **criteria it reads**
are never committed at all — they sit host-local at `/var/lib/property-watch/`, owned by the
operator at mode `0644`, so hermes can read them and cannot rewrite them.

Expected next is the holds recheck ([ADR-0038](adr/0038-held-back-packages-are-a-registry-an-agent-rechecks.md),
palimpsest#226/#227): its probes are deterministic, it writes `docs/holds.md` and nothing else,
and because it writes outside the agent's own state its source script is declared too.
