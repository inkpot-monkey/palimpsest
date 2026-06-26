# AGENTS.md - Nix conventions for this repo

## Build / lint / test commands

- **Check:** `nix flake check -L`
- **Format:** `nix fmt` (treefmt; runs nixfmt/deadnix/statix, ruff
  (format+check), rustfmt, shfmt, taplo, prettier, mdformat, elisp-autofmt —
  enforced via pre-commit hook). Config in `parts/treefmt.nix`.
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

### Searching the user's past commands & their output (recall)

The user's Emacs persistently logs **every async shell command they run and its
full stdout/stderr** (the `recall` package + the local `chelys-galactica`
package). You can — and should — search these when debugging something the user
ran interactively, instead of re-running it:

- **Output logs:** `~/.config/emacs/var/recall/*.log` — one timestamped file per
  run, containing the command output and (on the first line) the command itself.
- **Metadata index:** `~/.config/emacs/var/recall/history` (command, cwd, exit
  code, start/end time per run).
- **Retention:** four weeks (`recall-prune-after`), then logs are pruned.

So to see what a command printed, its exit status, or which directory it ran in,
`grep`/read those files (e.g. `grep -rl 'just deploy kelpy' ~/.config/emacs/var/recall/`).
From Emacs the user browses the same data per-command via
`chelys-galactica-view-outputs` (Embark `o`).

Interactive **bash** commands (ghostel terminals, ssh sessions, ttys) are
captured separately: bash is configured (`users/inkpotmonkey/home/shell.nix`) to
flush every command to `~/.local/state/bash/history` immediately, with `HISTTIMEFORMAT`
timestamps (lines `#<epoch>` precede each command). Only the *command line* is
recorded there, not its output — for output, use the recall logs above. Each
NixOS host has its own `~/.local/state/bash/history`; for a command run on a
server, read it there over ssh. (recall captures Emacs `async-shell-command` runs
*with* output; the bash history file captures interactive bash *commands*.
Together they're the full picture.)
