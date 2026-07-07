# Monitoring resolves peers by build-time tailscale-IP pins, independent of the DNS plane

When the **monitoring server** moved from `kelpy` to `rk1b`
([ADR-0028](0028-telemetry-durable-disk-capped-retention.md)), scraping broke:
on `kelpy` the server resolved peer hostnames through the co-located blocky, but
`rk1b` has neither MagicDNS (`acceptDns = false`) nor, at the time, a blocky.
Grafana showed only `rk1b` itself. This ADR records how monitoring resolves the
fleet's nodes, and why it deliberately does **not** use the tailnet's DNS.

## Decision

**Monitoring resolves peers by pinning their tailscale IPs into `/etc/hosts` at
build time**, via `networking.hosts` fed from the `settings.nodes` declaration —
not through DNS.

- **Server** (`monitoring/server.nix`) pins *every* node's `tailscale.ip4` and
  scrapes static targets built from the same `settings.nodes` list.
- **Client** (`monitoring/client.nix`) pins only the single **receiver** it ships
  to (`settings.services.private.monitoring.origin or .edge` = `rk1b`), so Vector
  can resolve it on nodes without MagicDNS (e.g. `rk1a`).

**Membership comes from the declaration; resolution is the build-time tailscale
IP.** A node is scraped because it is declared in `settings.nodes`, and its
address is whatever `secrets/nodes.nix` records — baked into `/etc/hosts` when
the host is built.

## Why not DNS

The monitoring host **must stay independent of the host it watches.** The tailnet
DNS is centralised on `kelpy`'s blocky (its global nameserver); resolving scrape
targets through it would couple the observer to `kelpy` — so a `kelpy` outage
would blind the very system meant to detect it. This is the same failure-domain
logic that puts the uptime **watcher** and out-of-band push on `rk1b`
([ADR-0026](0026-uptime-alerting.md), [ADR-0027](0027-out-of-band-web-push-relay.md)).
`/etc/hosts` is consulted by glibc *before* any resolver, so these pins hold
regardless of what DNS is doing.

Note this holds even now that `rk1b` runs its own blocky
([ADR-0030](0030-fleet-dns-dual-blocky.md)): monitoring still resolves via
`/etc/hosts`, not that blocky, keeping the collection path free of *any* DNS
dependency — including its own.

## Why build-time is acceptable (not a runtime generator)

A tailscale IP is drift-prone — it changes when a node re-registers. blocky
solves this with a **runtime** generator (`tailscale ip -4 <node>` on a timer,
[ADR-0011](0011-blocky-runtime-tailscale-dns.md)) because blocky serves diverse,
unmanaged clients that cannot rebuild. Monitoring is different: the server and
clients **rebuild themselves**, and `/var/lib/tailscale` is persisted so an IP
drifts **only on a full reflash** — which already forces a redeploy that
regenerates `/etc/hosts`. So a build-time pin **self-heals on the same operation
that would drift it**, and a runtime `file_sd` generator would be complexity with
no payoff here. (`watcher.nix` already pins Caddy service FQDNs to build-time
tailscale IPs the same way — this is established practice on `rk1b`.)

## Rejected alternatives

- **`acceptDns = true` on `rk1b` + resolve FQDNs via the tailnet DNS.** Couples
  monitoring to `kelpy`'s blocky — the exact coupling this avoids — and would
  also route `rk1b`'s general DNS (including the out-of-band push relay) through
  `kelpy`, breaking alerting during a `kelpy` outage.
- **A runtime `file_sd` generator** (writing current IPs to
  `/run/.../node-targets.json`, hot-reloaded by VictoriaMetrics). Correct in
  spirit but unnecessary here (see above); rejected for complexity.
- **Runtime resolution into `/etc/hosts`.** Impossible: NixOS builds `/etc/hosts`
  at activation from `networking.hosts` — it cannot be rewritten at runtime.

## Consequences

- A node added to or renamed in `settings.nodes` is picked up on the next build;
  no separate registration.
- A node whose tailscale IP drifts without a redeploy (the reflash-without-deploy
  case) would go unscraped until rebuilt — acceptable, since a reflashed node is
  redeployed to be brought back at all.
