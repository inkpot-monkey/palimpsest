# slskd seeds the music library through the VPN, as a container joined to gluetun

ADR-0028 made kelpy's copy of the music library a git-annex replica specifically so
**slskd** could seed it on Soulseek, and left the seeder itself unbuilt. Building it
forces three choices ADR-0028 did not settle: where slskd's peer-to-peer traffic
egresses, how it runs given that answer, and whether it accepts inbound connections.

nixpkgs ships a native `services.slskd` module — a hardened systemd service. Taking it
at face value would put Soulseek traffic straight onto kelpy's public VPS IP, which is
the same posture we already rejected for qBittorrent: kelpy fronts the fleet's web
surface, and associating that IP with a public P2P file-sharing swarm is exactly the
exposure the torrent stack routes around by egressing through a ProtonVPN tunnel
(gluetun container, WireGuard, kill-switch).

## Decision

**slskd runs on kelpy as an OCI container joined to the existing gluetun VPN container's
network namespace (`--network=container:gluetun`), seeding the git-annex `music` replica
read-only, and does not publish an inbound Soulseek port.**

- **Egress through the VPN, so a container, not the native module.** Consistency with
  qBittorrent decides the egress: P2P leaves kelpy through ProtonVPN or not at all. The
  only clean way to put a service on gluetun's netns is to join it as a container — a
  native systemd service cannot share a podman container's namespace without fragile
  hand-plumbed `NetworkNamespacePath` glue. So the native `services.slskd` module is
  *not* used; slskd is a pinned `slskd/slskd` image alongside gluetun and qBittorrent in
  the media profile, which is where the VPN container already lives. slskd's ports are
  therefore published *on gluetun* (a joined container has none of its own).
- **The library is mounted read-only.** kelpy's replica is `unlock`+`thin` (ADR-0028):
  the working files are hardlinks to the annex objects. slskd only ever reads bytes to
  seed them, and a write would mutate the shared object behind the hardlink and corrupt
  the replica. Read-only is the enforcement, not a convention — and it is why running the
  container as root (which reads the tree without any group juggling) is safe. kelpy's
  replica is a plain `0770 git-annex:git-annex` tree — not rk1b's `2770 git-annex:music`
  setgid share — because nothing else on kelpy touches it (ADR-0028), so root-reads-all
  is all the access slskd needs.
- **No inbound Soulseek port on the host.** Behind the VPN, slskd advertises the VPN exit
  IP to peers, never kelpy's public IP — so publishing the listen port on the host would
  open an internet-facing port that no peer ever connects to: pure attack surface for no
  reach. Seeding survives without it, because Soulseek brokers *indirect* connections
  (we dial the downloader) when a peer cannot reach us directly. Only the loopback web-UI
  port is published, for Caddy to front tailnet-only at `slskd.<domain>`.

## Rejected: the native `services.slskd` module on the host IP

The obvious path — enable `services.slskd`, point `shares` at the replica — is simpler
and better-hardened per-process, but it egresses on kelpy's public IP. That reintroduces
precisely the exposure qBittorrent's VPN routing exists to avoid, on the same host, for
the same class of traffic. Two P2P services on one VPS taking two different egress
postures is not a defensible split. The module stays unused until (if ever) slskd is
wanted without the VPN.

## Rejected: publishing the listen port for direct inbound

Copying qBittorrent's `6881` host publish onto slskd's `50300` looks like parity but is
cargo-culting: under the VPN it buys no inbound reachability (peers never see the host
IP) while adding a public port. Real direct inbound would require ProtonVPN port
forwarding — gluetun's `VPN_PORT_FORWARDING` surfacing a tunnel port, plumbed into
slskd's advertised port. That is a genuine future enhancement, not this.

## Consequences

- slskd lives in [`modules/nixos/profiles/media/slskd.nix`](../../modules/nixos/profiles/media/slskd.nix),
  gated on `custom.profiles.media.slskd.enable` under the media profile (which already
  brings up gluetun + podman). Enabled on kelpy.
- **A new secret, `slskd_env`**, in `profiles/media.yaml` (Soulseek account + web-UI
  login). The service starts without it but cannot connect. See the slskd runbook.
- **A `slskd` service-registry entry** (`kelpy:5030`) gives the web UI its `internal_only`
  Caddy vhost and, monitor-by-default, a Gatus probe. `podman-slskd.service` also joins
  kelpy's `monitoring-unit-state` list.
- **The module asserts** its `libraryPath` is a declared `services.git-annex`
  repository — it fails the build rather than silently seed a missing or empty tree.
- **Downloads are not wired into the pipeline.** slskd's downloads land in a local
  directory on kelpy; the beets inbox is on rk1b. Bridging them is ADR-0027 Phase 2 and
  deliberately out of scope here.
