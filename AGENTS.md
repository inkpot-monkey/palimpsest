# AGENTS.md - Nix conventions for this repo

## Build / lint / test commands

- **Check:** `nix flake check -L`
- **Format:** `nix fmt` (treefmt; runs nixfmt/deadnix/statix, ruff-format,
  rustfmt, shfmt, taplo, prettier, mdformat, elisp-autofmt — enforced via
  pre-commit hook). Config in `parts/treefmt.nix`.
- **Lint (statix):** `statix check .`
- **Lint (deadnix):** `deadnix .`
- **Nix packages:** `nix build .#<name>`
- **Deploy host:** `nixos-rebuild --target-host <host> --sudo --ask-sudo-password switch --flake .#<host>`
- **Everything:** `just check` / `just build [host]` / `just switch [host]`

## Code style

- **Formatting:** treefmt drives per-language formatters (`nix fmt`),
  mandatory and enforced via the pre-commit hook; nixfmt for Nix
- **Linting:** statix (disable `repeated_keys`), deadnix
- **Structure:** flake-parts modules, each in its own file under parts/, users/, hosts/, modules/
- **Naming:** kebab-case for Nix files and attribute names
- **Error handling:** avoid bare builtins.abort; use lib.assertMsg / lib.warn where appropriate
- **Flake inputs:** declare in flake.nix, follow other inputs where possible to avoid version mismatches
- **pkgs:** custom packages in pkgs/<name>/default.nix, wired via pkgs/default.nix

## Operational gotchas

Non-obvious traps that have bitten before — check these before deploying or
touching secrets:

- **`secrets/` is a separate repo** (pinned as a flake input). Editing a secret
  is not enough: commit + push it in the secrets repo, then `nix flake update secrets` here, *before* deploy — otherwise sops activation fails on the target.
- **sops is all-or-nothing per host.** A host needs its age key on *every* sops
  file, or `sops-install-secrets` installs none (e.g. no wifi on a Pi). When
  adding/rotating a host key, re-key all files together.
- **Never ship the admin SSH key to headless/agent hosts.** `~/.ssh/id_ed25519`
  is the sops admin key (`&admin`) and decrypts everything. Use a host's
  dedicated `signing_key`, not the admin key.
- **Some components live in their own repos**, consumed as flake inputs — e.g.
  `jmap-matrix-bridge` and `host-user-contract` (ADR-0017). Only host glue lives
  here; change behaviour in the upstream repo, then `nix flake update <input>`.
- **Raspberry Pi kernel pin:** `nixos-raspberrypi` must pin a rev whose *default*
  kernel is stable; unstable/next kernels hang in initrd and aren't cached.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
