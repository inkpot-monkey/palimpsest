# git-annex and backups, surfaced across hosts and users

palimpsest#60 gave git-annex the health signal it never had — a per-repo node-exporter
textfile metric (`git_annex_*`) plus a #infra-alerts watcher ([ADR-0019](0019-uptime-alerting.md)),
in the cheap textfile idiom [ADR-0024](0024-secret-expiry-registry.md) established. But it
only ever saw **system** annexes ([ADR-0028](0028-git-annex-owns-the-shared-music-library.md)):
the workstation's `~/Pictures` assistant — a *user* repo — published nothing, so the one
replication link with no second observer (kelpy's `pictures` repo is a passive receiver)
was invisible. And there was no view of *backups* as a whole: restic off-site
([ADR-0021](0021-telemetry-durable-disk-capped-retention.md)) sat in a different mechanism
entirely, currently switched off (deferred — palimpsest#150) — an off backup that
vanishes from monitoring being exactly the silent gap #60 exists to close.

This ADR records how git-annex usage — and the wider backup story — is surfaced **across
both hosts and users**, and the one sharp decision that fell out of it: **where a
user-level watcher's secret lives.**

## Decision

**One metric schema, published by whoever owns the repo; a user-level watcher for the
workstation that keeps its secret in the user's own domain; and a single Backups board
that shows the whole flow, off-site jobs included, as a known state rather than as
silence.**

1. **Schema across hosts and users.** Every `git_annex_*` series carries a `user` label,
   and each repo emits a constant-1 `git_annex_repo_info{repo,user,description,group,wanted}`
   inventory series (info-metric, joined via `group_left`). The metric-emitting shell body
   is factored into `modules/shared/git-annex/metrics.nix`; the alert-check body into
   `modules/shared/git-annex/alert.nix`. Host and home callers share both, so they cannot
   drift — the same seam `lib.nix` already gives the init path.

1. **The workstation publishes as the user.** The home-manager module gains a
   `services.git-annex.metrics` **user** systemd unit that writes
   `git-annex-<user>-<repo>.prom` into the node-exporter textfile dir. Because that dir is
   `node-exporter`-group-owned, the NixOS layer grants the user that group and asserts the
   exporter is present — wired together, opt-in, in `hosts/default.nix` — since home-manager
   can grant neither.

1. **The workstation alerts as a user unit — no host secret.** The workstation pages via
   `services.git-annex.alert`, a **user** unit, not the NixOS `monitoring-git-annex-alert`
   profile. Its webhook is assembled from a **home** `sops.template` over the fleet's
   `infra_alerts_hook_id`, decrypted by the user's own sops — which already decrypts every
   fleet secret, because that key **is** the sops admin key
   ([ADR-0003](0003-personal-key-is-sops-admin-key.md)). So the secret needs **no host
   re-key and no secrets-repo change of any kind.** The NixOS profile is unchanged and still
   runs on the always-on hosts.

1. **Presence gates staleness in the check, not in a query.** The alert reads the host's
   `presence` ([ADR-0026](0026-host-presence-scrape-label.md)) from `settings.nodes` and, on
   an `on-demand` host, treats absent/stale metrics as expected quiet (a closed laptop lid
   must not page), alerting only on a *fresh* bad signal. Always-on hosts keep the strict
   "stale means the exporter died" rule.

1. **Restic off fleet-wide, but visible.** Both live jobs are disabled (breadcrumbed: meant
   to return when rsync.net is reachable). A host declares the off-site jobs it *owns* via
   `custom.profiles.backup.reportJobs`, and a status oneshot publishes
   `backup_restic_enabled{job}` from config — `0` when off — so a disabled job is a
   **known-off edge, not missing data.** A job's unit stamps
   `backup_restic_last_success_timestamp_seconds` on success (ExecStartPost), dormant until
   restic returns.

1. **A dedicated Backups board.** A third board (`uid: backups`) beside Fleet Overview and
   Per-Service Health: a fixed-layout topology (git-annex on-fleet replication → kelpy;
   restic → rsync.net) plus the inventory and off-site tables.

## Why the user's secret, not a host secret (the sharp one)

The alert check is a body that reads local textfiles and POSTs a webhook; it can run as
root (a system unit) or as the user. That choice *is* the secret-placement choice, because
a root unit reads a host secret cleanly and a user unit reads a user secret cleanly, and
the cross pairings are worse:

- **Host secret + root system unit on the workstation** — rejected. It works, but re-keying
  `matrix.yaml` to the workstation's *host* key is pure ceremony: root there can already
  read the admin key in the user's home ([ADR-0003](0003-personal-key-is-sops-admin-key.md)),
  so it can already decrypt every fleet secret — the re-key buys no isolation, only a
  secrets-repo edit and a wider recipient list.
- **User secret read by a root unit** — rejected as fragile. home-manager sops secrets live
  under `/run/user/<uid>`, torn down on logout; a root timer cannot reliably read them.
- **User secret + user unit** — chosen. Everything (writer, alert, secret) lives in the
  user's domain, session-scoped, with zero secrets-repo work. Running under the session also
  means the check only ticks while metrics are fresh, so the presence rule is
  belt-and-suspenders here and load-bearing only on an on-demand host that runs the *system*
  check.

### Relationship to consumption purity (ADR-0025)

[ADR-0025](0025-fleet-user-secret-consumption-purity.md) forbids the **fleet** from
consuming a **user** secret, so that extracting the user breaks nothing fleet-side. This is
the **mirror**: a *user* unit consuming a *fleet* secret (the #infra-alerts hookId). The
0025 invariant is untouched — the fleet does not depend on the user's alert, so extraction
still breaks nothing on the fleet. The residual is a *reverse*, soft coupling: the user's
own feature leans on a fleet notification channel. That is accepted deliberately — the
git-annex sync is a user feature that opts into the fleet's alert room, and at extraction
the seam is a one-line webhook repoint the user makes for themselves, not a fleet break. A
truly self-contained user alert (its own channel) is a larger platform-identity question,
deferred exactly as 0025 defers the Tailscale identity layer.

## Why a third board (contrast with ADR-0026)

[ADR-0026](0026-host-presence-scrape-label.md) split monitoring into Fleet Overview (hosts)
and Per-Service Health (services), each answering one question, and the abandoned "fog"
per-subsystem boards are the cautionary precedent. Backups earns a board because it is
neither a host axis nor a service axis: it is a **cross-cutting flow** spanning both
system and user repos and a second mechanism (restic), and its central artefact — the
topology — has no home on either existing board. The topology is a Grafana **canvas** with
**fixed** colours (current state), because canvas has no precedent in the fleet and cannot
be authored against the live preview headlessly; authoritative live health stays in
house-style tables/tiles, and dynamic per-link colouring is a `just grafana-preview`
follow-up.

## Consequences

- **Deploy order:** rk1b → kelpy (enriched schema + shared alert body), then sawtoothShark
  (user metrics writer + user alert). No secrets-repo change anywhere; the workstation
  activates purely from the admin key already on it.
- **First user-level entry in the alerting tier** ([ADR-0019](0019-uptime-alerting.md)): the
  watcher is no longer root-only, and it now spans home repos. The always-on system profile
  is unchanged.
- **The `user` label churns each alert's per-series state key once** on first deploy (a
  benign single re-evaluation), and historical series predating the deploy lack the label —
  the board's queries are `instant`, so this is invisible after the rescrape.
- **Restic status is emitted from config, so it is correct even with restic uninstalled**:
  the board shows off-site as off, and lights up with real last-success ages the day the
  jobs are re-enabled — no board rework.
- **Coverage is not paging for a workstation that is off the tailnet** when a fault occurs
  (it cannot reach hookshot); the check fails gracefully. Inherent to an on-demand roaming
  device, knowingly accepted.
- VM-tested end to end: `git-annex-metrics`, `git-annex-home-manager` (drives the user
  alert), `git_annex_alert`, `backup_status`.
