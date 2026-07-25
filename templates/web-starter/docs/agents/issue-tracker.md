# Issue tracker

Issues and PRDs for this site are tracked as **GitHub issues** via the `gh` CLI.
`gh` infers the repo from `git remote -v` when run inside the clone.

- **Create:** `gh issue create --title "..." --body "..."` (heredoc for multi-line).
- **Read:** `gh issue view <number> --comments`
- **List:** `gh issue list --state open`
- **Comment / label / close:** `gh issue comment`, `gh issue edit --add-label`,
  `gh issue close`.

Architecture decisions are recorded separately as ADRs under `docs/adr/`.
