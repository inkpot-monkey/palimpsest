# AGENTS.md - Nix conventions for this repo

## Build / lint / test commands

- **Check:** `nix flake check -L`
- **Format:** `nix fmt` (uses nixfmt, enabled in git hooks)
- **Lint (statix):** `statix check .`
- **Lint (deadnix):** `deadnix .`
- **Nix packages:** `nix build .#<name>`
- **Deploy host:** `nixos-rebuild --target-host <host> --sudo --ask-sudo-password switch --flake .#<host>`
- **Everything:** `just check` / `just build [host]` / `just switch [host]`

## Code style

- **Formatting:** nixfmt (mandatory, enforced via pre-commit hook)
- **Linting:** statix (disable `repeated_keys`), deadnix
- **Structure:** flake-parts modules, each in its own file under parts/, users/, hosts/, modules/
- **Naming:** kebab-case for Nix files and attribute names
- **Error handling:** avoid bare builtins.abort; use lib.assertMsg / lib.warn where appropriate
- **Flake inputs:** declare in flake.nix, follow other inputs where possible to avoid version mismatches
- **pkgs:** custom packages in pkgs/<name>/default.nix, wired via pkgs/default.nix

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
