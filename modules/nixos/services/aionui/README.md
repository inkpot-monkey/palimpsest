# aionui

Runs the headless **AionUi WebUI** (`aionui-web` / `aioncore`) as a service — a
browser frontend that drives **Claude Code** (and other agents) over ACP. Intended
for phone access: reach it via the reverse proxy on your private network.

The package (`pkgs/aionui`) wraps the official `aionui-web` standalone release
tarball (bundles the `aioncore` Rust backend, the SPA, a Node runtime and the ACP
adapters).

## Enabling (via the profile)

`modules/nixos/profiles/aionui.nix` (`custom.profiles.aionui.enable`) enables the
service as the interactive user (`inkpotmonkey`) so the agent reuses that user's
`claude login` credentials (`~/.claude`) and works inside `~/code`. It is exposed
as a **private** service (Tailscale-only) at `aionui.<domain>` via Caddy.

> Security note: the web-host launches `aioncore` in `--local` mode, which does
> **not** enforce the admin password — the only access control is the network
> boundary (localhost bind + the Tailscale-restricted Caddy vhost). Do not expose
> it publicly or set `allowRemote`.

## The writable-backend workaround (important)

`aioncore` activates a **managed Node runtime** (and npm-based ACP tools) by
copying them out of its bundled `managed-resources` into `<data-dir>/runtime`.
When the bundle sits in the read-only Nix store (`0555` dirs) that copy fails with
`bundled Node runtime is invalid … Permission denied`, and **Claude Code cannot
launch at all** (it's an npm-based ACP agent — a system `node` on `$PATH` does not
help).

The service therefore stages a **writable copy** of `bundled-aioncore` under
`${dataDir}/backend` (`ExecStartPre`, version-guarded) and points `--backend-bin`
at it. Cost: ~hundreds of MB under the persisted data dir, re-staged only on a
package-version change. Without this, AionUi is non-functional for running agents.

## One-time operational bootstrap (after first deploy)

1. **Claude login** as the service user over SSH: run `claude` (or `claude login`)
   once to populate `~/.claude` (persisted under impermanence).
2. **Clone projects** into `~/code` (e.g. this repo, `inventoria`).
3. Open `https://aionui.<domain>` from your phone (on the tailnet), pick the Claude
   Code agent in a project, and go.

The first launch also seeds the SQLite DB and an admin user (~30s) — `TimeoutStartSec`
is set generously to cover the backend staging + DB init.

## Notifications

To get Matrix pings when an agent finishes / needs input / errors, see the sibling
[`aionui-notifier`](../aionui-notifier/README.md) (`notifications.enable`).
