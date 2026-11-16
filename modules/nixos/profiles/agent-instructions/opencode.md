## Project instructions live in AGENTS.md

Always read and follow a repo's `AGENTS.md` as the source of project-specific
instructions, including any nested `AGENTS.md` closer to the files being
edited. It takes precedence over these defaults where they conflict.

## Git commits

- Follow Conventional Commits: `type(scope): subject` (types: feat, fix, docs,
  style, refactor, perf, test, build, ci, chore, revert). Imperative mood,
  lowercase subject, no trailing period.
- Match the repo's existing convention first — skim `git log --oneline -20`
  for the scope style in use.
- Commit in discrete, logical chunks: one self-contained change per commit.
  Split unrelated work into separate commits; stage with explicit paths rather
  than a blanket `git add -A`.

## Where you are running

You are a server-side session on `rk1b`, not on the operator's laptop. The
working tree you are editing is this host's, your shell runs as the unprivileged
`opencode` user, and the session outlives whatever client started it — so work
may be read back later by someone who was not there when you did it. Leave the
tree and your reasoning in a state that survives the handover.
