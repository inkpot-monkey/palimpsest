# Secret expiry is tracked by a declared plaintext registry, alerted like a unit-state check

Some secrets lapse on a clock: the Tailscale auth key is capped at **90 days**,
API tokens and Cloudflare tokens expire, etc. A sops value's ciphertext carries
**no expiry metadata** — `tailscale_key` looks identical whether it dies tomorrow
or never — so nothing on-disk can be observed to know when to rotate. Left to
memory, a key silently lapses and something breaks. This ADR records how the
fleet tracks and alerts on secret expiry.

## Decision

**A declared plaintext registry (`secrets/expiry.nix`) is the source of truth for
when each rotatable secret expires, and a daily on-host check
(`monitoring/secret-expiry.nix`) alerts `#infra-alerts` before it lapses** —
reusing the ADR-0026 alerting tier wholesale.

- **Registry** — `secrets/expiry.nix`, a normal (non-sops) Nix file: per secret,
  `{ file; warnDays?; runbook; }` plus expiry declared either as an absolute
  `expires` (YYYY-MM-DD, when you only know the deadline) or `issued` + `expiresDays`.
  Only secrets that actually lapse are listed; passwords, the VAPID keypair,
  `signing_key` and encryption keys are deliberately absent.
- **Check** — `custom.profiles.monitoring-secret-expiry` (enabled on `kelpy`): a
  daily `systemd` timer computes days-remaining per entry and POSTs to the hookshot
  loopback webhook — the same sink, jq body and `webhookUrlFile` plumbing as the
  ADR-0026 unit-state check. It alerts once as each `warnDays` band is first entered
  (default `30 → 14 → 3 → EXPIRED`), does **not** re-spam within a band, and sends a
  ✅ notice when the value is renewed. Per-secret state (the tightest band already
  reported) lives in `StateDirectory`, so the daily run is idempotent.
- **Metric** — it also writes `secret_expiry_timestamp_seconds{secret="…"}` to the
  node-exporter textfile dir, for a Grafana "days remaining" gauge. Since the
  monitoring stack is collection-only (no vmalert, ADR-0028), the webhook POST *is*
  the alert; the metric is just free visibility. A provisioned in-tree dashboard
  (`monitoring/dashboards/secret-expiry.json`, "Secret Expiry") renders it as a
  days-remaining stat coloured on the same bands, alongside the expiry date.

## Why the registry lives in the secrets repo (plaintext), not the main repo

Expiry dates are not secret, so colocation vs. edit-friction was the real tension.
The registry lives **in the secrets repo alongside the sops files it describes**
because rotation *already* forces the secrets-repo cycle — regen the key,
`sops set <file>`, commit, push, `nix flake update secrets`, deploy. Bumping
`issued` in that **same commit** costs nothing extra and guarantees the value and
its expiry date never drift into separate PRs. It is a plaintext `.nix` file, not a
comment inside the sops YAML: **sops encrypts comments by default**
(`#ENC[…,type:comment]`), so an in-file comment would neither stay plaintext nor be
readable by the watcher. `kelpy` reads the file at eval time through the locked
`secrets` flake input; a public clone without that input falls back to `{}` (no
watched secrets), guarded by `pathExists` rather than the identities mock.

## Why declared, not live-probed

Probing each provider's API for the *real* expiry (Tailscale's keys endpoint,
GitHub's `github-authentication-token-expiration` header) would self-heal the one
weakness of a declared registry — it drifts if you rotate but forget to bump
`issued`. It is **deferred to Phase 2**, per-secret and opt-in, because it adds a
provider credential each (and Tailscale needs a *non-expiring* OAuth client, since
an API token would itself expire). The declared registry covers **every** secret
uniformly today with zero new secrets; the discipline is "bump `issued` in the
rotation commit," which the colocation above makes a one-line, same-PR edit.

## Consequences

- Adding a rotatable secret means adding a registry entry; a typo in its `file`
  fails the flake check (eval-time `pathExists` assertion), not silently at runtime.
- The alert fires from `kelpy` — the host most likely to *hold* the expiring key —
  which is acceptable here (unlike ADR-0026's reachability probe, expiry is not an
  outage the observer could be blind to).
- First consumer: the 90-day fleet `tailscale_key` (`issued = 2026-05-09` →
  **2026-08-07**), which is already inside the 30-day warn band.
