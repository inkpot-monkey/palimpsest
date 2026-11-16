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
| _none yet_ | | | |

The first entry will be the holds recheck ([ADR-0038](adr/0038-held-back-packages-are-a-registry-an-agent-rechecks.md),
palimpsest#226/#227): its probes are deterministic, it writes `docs/holds.md` and nothing else,
and because it writes outside the agent's own state its source script is declared.
