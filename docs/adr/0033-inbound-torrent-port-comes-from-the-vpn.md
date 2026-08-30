# The inbound BitTorrent port comes from ProtonVPN, not from the host

ADR-0029 rejected publishing a P2P listen port on kelpy and named the alternative as
future work: "Real direct inbound would require ProtonVPN port forwarding — gluetun's
`VPN_PORT_FORWARDING` surfacing a tunnel port, plumbed into [the client's] advertised
port." Commit `e19c9fe` then removed qBittorrent's `6881:6881` host publish, which had
been leaking kelpy's real address to peers while buying no inbound over the tunnel. That
left the stack correct and completely unconnectable.

The cost of unconnectable is not abstract. On 2026-08-30 kelpy's qBittorrent showed
`connection_status: connected`, a healthy DHT at 368 nodes, thirteen torrents — and
0 B/s of upload across the twelve that were complete and seeding, plus the thirteenth
stuck in `stalledDL` at 69% with `availability: 0.69`: the peers holding the missing
third could not reach us, and we had not happened to dial them.

## Decision

**Inbound comes from the VPN side. gluetun asks ProtonVPN for a forwarded port over
NAT-PMP, and a host-side reconciler copies that port into qBittorrent's listener.**
Nothing new is published on kelpy; ADR-0029's rule is unchanged and now load-bearing
rather than merely tidy.

- **The port is dynamic, so syncing it is part of the feature, not an operational
  afterthought.** ProtonVPN assigns the number and gluetun renews the lease every ~45s;
  a statically configured `Session\Port` is wrong the moment a lease is issued. A
  forwarded port nothing listens on is worth exactly as much as no forwarded port, which
  is the failure mode this ADR exists to prevent.
- **The reconciler talks to the WebUI over the existing loopback publish**, authenticating
  with the sops-held admin password, rather than setting `WebUI\LocalHostAuth=false`.
  podman's published-port DNAT makes host traffic arrive from the bridge address, so
  "trust localhost" would have meant trusting every process on kelpy — a strictly wider
  grant than the one credential it replaces.
- **It reconciles on a timer and is idempotent**, comparing before writing. The number
  changes only when gluetun reconnects, so the interval is a convergence bound on a rare
  event, not a poll of a fast-moving value.
- **A tick that lands while qBittorrent is down is not a failure.** `podman-qbittorrent-app`
  being down is already the `monitoring-unit-state` check's alarm; a second one for the
  same fault is noise. Bad credentials, a non-numeric status file, or a rejected write do
  fail the unit.

## Rejected: `VPN_PORT_FORWARDING_UP_COMMAND` inside the container

gluetun can run a command when the lease comes up, and from inside the shared netns
qBittorrent's WebUI genuinely is on localhost. But the hook would still need the admin
password (or the localhost-auth bypass above) inside a busybox one-liner, it re-runs on
gluetun's schedule rather than reconciling on demand, and it cannot correct drift after a
qBittorrent restart because gluetun's state has not changed. The host-side reconciler
covers all three.

## Consequences

- Port forwarding and the sync live in
  [`modules/nixos/profiles/media/qbittorrent-port-forward.nix`](../../modules/nixos/profiles/media/qbittorrent-port-forward.nix),
  gated on `custom.profiles.media.portForward.enable` (default: media profile on, test
  mode off).
- **`PORT_FORWARD_ONLY=on` becomes load-bearing.** It restricts server selection to
  forwarding-capable ProtonVPN servers; that was previously only a way to avoid Tor exits.
- **The ProtonVPN credentials must carry the NAT-PMP grant.** For WireGuard that is a
  toggle set when the config is generated; an existing key made without it cannot be
  upgraded in place and must be regenerated into `profiles/media.yaml`. Without it gluetun
  never publishes a port and the reconciler logs "not published yet" forever — the most
  likely reason for this to silently do nothing.
- **One connection, one forwarded port, and it goes to qBittorrent.** slskd shares the
  netns and stays without inbound, exactly as ADR-0029 has it. Splitting the single port
  between two P2P applications is not possible; if slskd ever needs inbound more than
  qBittorrent does, this is a re-decision, not a configuration change.
- **A new sops consumer on kelpy**: `qbittorrent_webui_password`, read from
  `users/inkpotmonkey.yaml` (key `admin@torrent.palebluebytes.space`), which kelpy is
  already a recipient of — no new secret file and no re-keying.
