# Host presence is a scrape label, and Fleet Overview is the hosts board

The fleet mixes machines that run 24/7 (`kelpy`, the `rk1a`/`rk1b` nodes, the
`porcupineFish` audio host) with ones that run only when in use (the interactive
workstations and the laptop). `node-exporter` scrapes **every** host by MagicDNS
name, so an off workstation reports `up == 0` — indistinguishable, to a query,
from an always-on host that has actually fallen over. The old Fleet Overview board
papered over this in prose ("offline laptops read down by design") while still
lighting them red, and it carried service probes alongside host health, so it read
as an unfocused everything-bucket. This ADR records how a host's *nature* is
declared once and how the health boards divide their responsibility.

## Decision

**Each host declares its operational cadence as `presence` in
`settings.nodes.<host>` (`"always-on" | "on-demand"`), and that value is emitted
as a Prometheus target label on the `node` scrape job.** Monitoring then *derives*
a host's alert-worthiness from the label rather than hard-coding a host list per
board — an on-demand host being unreachable is expected and never colours a health
signal red; an always-on host down is the real alarm.

- **Model** — `presence` is a plain key on the freeform `settings.nodes` attrset
  (`parts/settings.nix`). It is a *fact about the machine*, not a monitoring
  policy: there is no per-host opt-out, and alert-worthiness is `presence == "always-on"`, computed in the query. (CONTEXT.md → **Always-on host** /
  **On-demand host**.)
- **Label plumbing** — `server.nix`'s `makeTargets` emits one `static_config` per
  host carrying `labels.presence` (defaulting `on-demand` when a host omits the
  key — fail-safe-quiet). The label rides onto `up` and every `node_*` series, so
  any board or rule can filter `{presence="always-on"}`.
- **Board split** — **Fleet Overview** is the hosts board: presence-aware host
  up/down (an always-on-only status strip, a "hosts down" / "failed units" glance,
  a per-host lifecycle table with a grey `OFF` state and a "last online" for
  on-demand hosts). Service signals — probe success/latency, per-service errors,
  TLS cert expiry, curated unit-state — live on the separate **Per-Service
  Health** board. Each board answers one question.

## Why a scrape label, not a hard-coded host list

The repo's existing precedent hard-codes host/unit sets *inside* dashboard PromQL
(the `instance=~"kelpy.*|rk1b.*"` unit regexes in `per-service-health.json` and
`host-drill-down.json`). That was rejected here: the always-on set would then live
duplicated across every board's JSON, drift independently, and be invisible to the
alerting tier. Declaring `presence` once in `settings.nodes` — the same place the
scrape targets are already derived from — makes it single-source, and a target
label is the cheapest way to carry a build-time fact onto every runtime series
(no textfile exporter, no relabel config, no new metric).

## Why presence is a nature, not a policy (contrast with ADR-0019)

An **Expected-up service** (ADR-0019) is a uniform *monitor-by-default policy* with
explicit opt-outs — every service should be up unless a `monitor.reason` says
otherwise. Hosts are the opposite: workstations *legitimately* aren't expected up,
so the axis is the host's intrinsic run cadence, read off the machine, not a
watch/don't-watch choice. Modelling it as a nature (and deriving alerting) keeps
the two axes honest and avoids a false parallel. The cost is that an always-on
host you want *temporarily silenced* isn't expressible; that's deliberate and can
be revisited if a maintenance-window need ever appears.

## Consequences

- The `presence` label only attaches after `rk1b` redeploys and Prometheus
  rescrapes; presence-filtered panels are **empty until then**, and historical
  series predating the deploy lack the label. All board queries are `instant`, so
  they use the latest sample and are correct post-deploy.
- Adding a host to the fleet now means setting its `presence` (omission defaults to
  `on-demand`, so a new, unclassified host never cries red — you promote it to
  `always-on` deliberately). This is the *opposite* default from services'
  monitor-by-default, and intentionally so: an unclassified host is far more likely
  a new laptop than a new server.
- The four reserved status roles and the categorical host palette are unchanged;
  the new `OFF` state uses a neutral grey (`#8e8e8e`), not a status role, because
  it is explicitly *not* a health signal.
