# Runbook: slskd — seeding the music library on Soulseek (kelpy)

The shared music library (`/var/cache/music` on rk1b, served by Navidrome) is
replicated to kelpy as a git-annex `music` repo (ADR-0028). **slskd** is the other
half of that plan: it shares that replica out on the **Soulseek** network so the
library gives back to the community it is partly sourced from.

slskd runs on **kelpy**, inside the **ProtonVPN** container's network namespace — all
its Soulseek traffic egresses through the VPN, exactly like qBittorrent (ADR-0029). Its
web UI is fronted tailnet-only by kelpy's Caddy at `slskd.<domain>`.

Served by [`modules/nixos/profiles/media/slskd.nix`](../../modules/nixos/profiles/media/slskd.nix)
(enabled on kelpy via `custom.profiles.media.slskd.enable` in
[`hosts/kelpy/configuration.nix`](../../hosts/kelpy/configuration.nix)). Design: ADR-0028
(the library) and ADR-0029 (the egress).

## What it touches

| Path (host) | In container | Role |
| --- | --- | --- |
| `/var/lib/git-annex/music` | `/music` (**ro**) | The library it seeds. Read-only — a write would mutate the `thin` hardlink and corrupt the annex object. |
| `/var/lib/slskd` | `/app` | slskd's own state: share database, generated `slskd.yml`, transfer history. Persisted. |
| `/var/lib/media/slskd-downloads` | `/downloads` | Where slskd's own downloads land. Not yet wired into the beets inbox (that inbox is on rk1b — a Phase-2 cross-host concern). |

## One-time setup: the `slskd_env` secret

slskd needs a Soulseek account and a web-UI login. Both live as **nested keys** under
`slskd` in **`profiles/media.yaml`** in the secrets repo (same file as `protonvpn_env`).
The module assembles them into slskd's env file via a sops template — you never write the
`SLSKD_*` variable names, just the values:

```yaml
slskd:
  slsk:
    username: <your-soulseek-username>
    password: <your-soulseek-password>
  username: <web-ui-username>      # e.g. admin
  password: <web-ui-password>
```

The Soulseek account itself is created on first login (there is no web signup) — pick a
username/password, or register it first with a client (`nix run nixpkgs#nicotine-plus`).
The web-UI username/password are yours to invent; they only gate slskd's own web UI.

Add the keys in the secrets repo, then (see the secrets-repo note in `AGENTS.md`):

```sh
# in the secrets repo
sops profiles/media.yaml          # add the nested slskd.* keys
git commit -am 'feat: slskd credentials' && git push
# back in this repo
nix flake update secrets
```

Deploy only after that lands — without the secret, `podman-slskd.service` starts but
slskd can't log in to Soulseek.

## Deploy

```sh
just deploy kelpy    # prompts for the sudo password (kelpy keeps password sudo)
```

Order does not matter relative to rk1b: kelpy holds a full replica, so slskd shares
whatever the replica currently has and picks up new tracks as git-annex propagates them.

## Verify

```sh
# On kelpy:
systemctl status podman-slskd.service podman-gluetun.service
# Web UI (from a tailnet host):
curl -sS -o /dev/null -w '%{http_code}\n' https://slskd.<domain>/   # expect 200
```

Then log in to `https://slskd.<domain>`, check **System → Shares** lists the library
under `/music`, and confirm slskd shows **Connected** to the Soulseek server.

## Notes and limits

- **Egress is the VPN.** slskd shares gluetun's netns; if `podman-gluetun.service` is
  down, slskd has no network. `podman-slskd.service` `dependsOn` gluetun.
- **No inbound port.** The Soulseek listen port is *not* published on kelpy's public IP
  (peers would be told the VPN exit IP, never kelpy's, so a host publish is useless and
  is pure exposure). Seeding still works: Soulseek brokers indirect connections outbound
  when a downloader can't reach us. True direct inbound would need ProtonVPN port
  forwarding (gluetun `VPN_PORT_FORWARDING`) plumbed through to slskd — not done.
- **Read-only library.** slskd can never modify the library; downloads go to their own
  directory. Getting downloaded music *into* the library is the beets pipeline's job on
  rk1b, and wiring kelpy's slskd downloads across to it is deliberately out of scope
  (ADR-0027 Phase 2).
- **Monitoring.** `podman-slskd.service` is in kelpy's `monitoring-unit-state` list, and
  the `slskd` service-registry entry gives it a Gatus reachability probe through Caddy —
  both alert to `#infra-alerts`.
