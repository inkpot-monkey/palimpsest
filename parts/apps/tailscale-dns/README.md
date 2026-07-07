# `tailscale-dns` app

Manages the tailnet's **global nameservers** (the admin-console DNS list) from the
command line, so the reflash IP-drift step in
[ADR-0030](../../../docs/adr/0030-fleet-dns-dual-blocky.md) is one command, not a
manual console edit.

```sh
nix run .#tailscale-dns            # preview: current vs computed list (default)
nix run .#tailscale-dns -- get     # just print the current + computed lists
nix run .#tailscale-dns -- push    # replace the list with the computed one
```

## What it does

The nameserver hosts are declared once in `settings.dns.nameserverHosts`
(the fleet's blocky resolvers — `kelpy` + `rk1b`). The app resolves each host's
**current** tailscale IP with `tailscale ip -4 <host>` (so it self-heals against
drift), then POSTs the list — which **replaces** it, dropping any stale entry
(e.g. the dead `porcupineFish` IP) in the same call.

It refuses to push a **partial** list: if any host won't resolve, it aborts rather
than silently halving DNS redundancy.

## Requirements

- You must be **on the tailnet** (the app resolves peer IPs from your local
  `tailscaled` netmap).
- Auth is inkpotmonkey's Tailscale **API key**, stored at `users/inkpotmonkey.yaml`
  (key `tailscale`) in the secrets repo and decrypted at runtime — never written
  to disk or the process table. Assumes a personal API key (`tskey-api-…`); an
  OAuth client secret would need a token-exchange step first.

## Not managed here

The **"Override local DNS"** toggle. The Tailscale API exposes only `magicDNS`,
not that toggle, so it stays a one-time console setting — keep it **ON** (ADR-0030)
so the unmanaged phone gets ad-block through blocky.
