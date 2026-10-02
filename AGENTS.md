# AGENTS.md - Nix conventions for this repo

## Build / lint / test commands

- **Check:** `nix flake check -L`. Also runs in CI (`.github/workflows/checks.yml`,
  one job per check) on every push to `main` and every PR, against the **mock**
  secret set — so CI cannot catch a secret-dependent regression. CI runs 16 of the
  22 non-git-annex checks, in ~10 min. Two lists in that workflow name the rest,
  each with its reason inline: `EXCLUDE` (four it *cannot* run — three need the
  private `users` flake input, which the ADR-0012 mocks do not cover, and
  `git_annex_alert` builds git-annex from source and trips its upstream test suite)
  and `SLOW` (`supernote_mirror`, `stump` — 27 and 23 min, which alone tripled the
  push-gate wall-clock). **All six, and the git-annex VM suite, are yours to run
  locally** — `nix flake check` remains the only complete gate. workflow_dispatch
  takes an `only` substring filter that reaches any check, excluded or not.
- **Format:** `nix fmt` (treefmt; runs nixfmt/deadnix/statix, ruff
  (format+check), rustfmt, shfmt, taplo, prettier, mdformat, elisp-autofmt —
  enforced via pre-commit hook). Config in `parts/treefmt.nix`.
- **Lint (statix):** `statix check .`
- **Lint (deadnix):** `deadnix .`
- **Nix packages:** `nix build .#<name>`
- **Deploy host:** `just deploy <host>` (switch now) or `just deployBoot <host>`
  (next boot). Wraps `nixos-rebuild` with SSH keepalives and adds
  `--ask-sudo-password` *only* for kelpy — other hosts have passwordless wheel
  sudo, so don't pass it yourself (it hangs waiting on stdin non-interactively).
- **Everything:** `just check` / `just build [host]` / `just switch [host]` (local)

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
  `jmap-matrix-bridge` and `host-user-contract` (ADR-0016). Only host glue lives
  here; change behaviour in the upstream repo, then `nix flake update <input>`.
- **`jmap-bridge` is pinned to a release tag, so `nix flake update jmap-bridge`
  is a no-op.** Bump it by editing the tag in `flake.nix` by hand
  (`gh release list --repo palebluebytes/jmap-matrix-bridge`). The pin exists
  because the input's cache hit depends on the bridge's CI having pushed that
  exact rev to `palebluebytes.cachix.org` (ADR-0016 amendment); tracking `main`
  could re-lock onto a tip CI never built, and a deploy would then silently
  compile matrix-sdk/sqlx from source — no error, just half an hour. A tag is
  always a released, CI-built rev. If you ever do point it at a raw rev, check
  first: `gh run list --repo palebluebytes/jmap-matrix-bridge --commit <rev>`.
- **`nix flake update` gets rate-limited** (`429: Too Many Requests`) because it
  calls the GitHub API anonymously. Add
  `--option access-tokens github.com=$(gh auth token)`.
- **A new file must be `git add`ed before the flake can see it.** The source is
  git-tracked-files-only, so an untracked file fails at *eval* with
  `error: Path '…' is not tracked by Git` rather than as a missing file.
- **Raspberry Pi kernel pin:** porcupineFish must run a `stable_*`-tagged vendor kernel
  — unstable/next ones hang in initrd, a silent brick (no console, no network, and
  extlinux does not fall back). The host `lib.mkForce`s `boot.kernelPackages` to a named
  bundle, so the `nixos-raspberrypi` rev's *default* no longer has to be stable, but the
  forced bundle does. Read the `tag` in the rev's `pkgs/linux-rpi/linux-sources.nix`, not
  the version number: the same `6.18.34` is `stable_*` on one branch and `unstable_*` on
  another. Bumping that rev also moves the Pi's whole userspace (it pins its own nixpkgs),
  so `home-manager-pi` moves with it in lockstep. **Never deploy a kernel change to this
  host remotely** — validate at the device. See `hosts/porcupineFish/README.md`.
- **Services are monitored by default (ADR-0019).** Every `settings.services` entry
  is uptime-probed automatically. To exempt a *served* service, set
  `monitor = { enable = false; reason = "…"; }` on its entry (not delete it — that
  also drops its Caddy vhost). The `uptime_monitoring` flake check enforces the
  reason and that every monitored service has a buildable probe.

## Agent skills

### Issue tracker

Issues live as GitHub issues on `inkpot-monkey/palimpsest` (via the `gh` CLI); external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

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
