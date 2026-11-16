# Operator-authored skills for hermes

Skills declared by the fleet and handed to hermes read-only through
`skills.external_dirs`. One directory per skill, each holding a `SKILL.md`
with YAML frontmatter — the same format Claude Code and opencode read.

This directory is deliberately separate from `$HERMES_HOME/skills/`, which
belongs to the agent: hermes creates skills there from experience and
improves them during use, and anything declared into it would be overwritten
on the next activation. See
[ADR-0041](../../../../docs/adr/0041-an-agent-job-is-state-and-the-fleet-declares-its-boundaries.md).
