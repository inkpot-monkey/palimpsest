# Fleet DNS: dual blocky (`kelpy` + `rk1b`), no public fail-open, laptops stay tailscale clients

The tailnet's split-horizon DNS + ad-blocking runs on a single **blocky**
([ADR-0011](0011-blocky-runtime-tailscale-dns.md)) on `kelpy`, registered as the
tailnet's one global nameserver. That makes `kelpy` a DNS single point of
failure, and the intended secondary — `porcupineFish` — had silently stopped
being one: a reflash drifted its tailscale IP, so the admin-console nameserver
entry (`100.107.42.51`) pointed at nothing. This ADR records how we make fleet
DNS redundant and decides, per device class, who depends on it.

The design hinges on one non-obvious fact about how tailscale uses multiple
global nameservers, which drove almost every choice below.

## The load-bearing fact: parallel query, fastest wins

With **"Override local DNS" ON**, tailscale *proxies* DNS and queries **all
global nameservers in parallel, taking the quickest response** — it is **not**
sequential failover ([DNS in Tailscale](https://tailscale.com/docs/reference/dns-in-tailscale)).
Two consequences fall straight out:

- Redundancy is real and delay-free: if one blocky is down, the other answers
  and its response is simply the one that arrives. Both run identical blocky
  (same denylists, same split-horizon), so the winning answer is the same.
- A co-equal *public* resolver in that list is corrosive, not a safety net (see
  the fail-open decision).

## Decision

**Run blocky on `kelpy` and `rk1b`; both are the tailnet's global nameservers.**
`rk1b` replaces the drifted `porcupineFish` as the second. `rk1b` needs no code
beyond `custom.profiles.blocky.enable = true` — it is built with `mkSystem`
(main `nixpkgs`, so blocky 0.30's module is already present); the
`disabledModules`/`imports` swap in `hosts/default.nix` is Pi-only
(`mkPiSystem`). Both DNS hosts keep `acceptDns = false` and resolve through their
own local blocky (`nameservers = 127.0.0.1`), so each is self-sufficient.

**No public fail-open nameserver.** We do *not* add `1.1.1.1` as a third global
nameserver. Under parallel-query, a raw-UDP anycast resolver beats blocky's DoH
upstreams on nearly every race, so it would (a) bypass ad-block wholesale, not
"occasionally", and (b) hijack split-horizon — returning NXDOMAIN or a public IP
for tailscale-only names and, when it wins the race, handing the client the
wrong answer. Two independent blockies **are** the availability story; each
already fails open to the internet via its own DoH upstreams while it is up.
Both-down means a brief no-DNS window until one recovers — an accepted tail risk
across two independent hosts (a VPS and a home node).

**Remove blocky from `porcupineFish`.** It is an audio appliance whose
documented recovery is a cold power-cycle; a node that goes down for non-DNS
reasons and stays down until physically reset is a liability in a
fastest-wins nameserver list, not a fallback.

**Keep "Override local DNS" ON.** It is the only lever that gives an unmanaged
device (the operator's Android phone) ad-block and internal names — the phone
can only get them by having blocky as its general resolver.

**Per-device-class posture:**

| Class | Hosts | `acceptDns` | Resolves via |
|-------|-------|-------------|--------------|
| DNS servers | `kelpy`, `rk1b` | `false` | own local blocky (also the fleet's global nameservers) |
| Clients | phone, `stargazer`, `sawtoothShark`, `weedySeadragon` | `true` | the two global nameservers (parallel, fastest) → ad-block + internal names |
| Plain servers | `rk1a`, `potbelliedSeahorse` | `false` | LAN DNS + build-time `/etc/hosts` pins; independent of the DNS plane |

**Laptops stay `acceptDns = true` clients — they do *not* run a local blocky.**
This was reconsidered and rejected. All three workstations are **roaming
laptops** on NetworkManager, and an always-on local DoH blocky breaks two things
a server never hits: it **fights NetworkManager's per-connection DHCP DNS**
(needs extra `ignore-auto-dns` wiring), and — the real footgun — **breaks
captive portals**, because portals redirect by intercepting *plaintext* DNS and
a local DoH resolver bypasses that interception, leaving the laptop unable to
reach the login page. Going from one blocky to two already turns "`kelpy` down =
no DNS" into "both down = no DNS", which is the redundancy win; per-laptop local
blocky is available later for a specific machine if "both down" ever bites.

**Service names stay FQDN** (`monitoring.palebluebytes.space`, not `monitoring`).
Services front on Caddy with public Let's Encrypt certs; a browser validates the
cert SAN against the typed name, and no public CA will issue for a bare
single-label name — so shortening breaks HTTPS. Host *names* are already bare via
MagicDNS (`ssh rk1b`); a search domain could expand short service names in a
terminal but is unreliable in browsers, so it is not adopted.

## Out-of-band steps (tailscale admin console — not Nix)

Nameservers must be entered as **IPs, not MagicDNS names**, so they live in the
admin console, outside this repo:

- Set global nameservers to **`kelpy` and `rk1b`'s current tailscale IPs**
  (`tailscale ip -4 kelpy` / `tailscale ip -4 rk1b`); **delete** the stale
  `porcupineFish` entry `100.107.42.51`.
- Keep **"Override local DNS" ON**.
- The phone needs nothing beyond being on the tailnet — it inherits the global
  nameservers.

**Reflash runbook drift step.** `/var/lib/tailscale` is persisted under
impermanence, so a node's tailscale IP survives reboots and normal redeploys and
drifts **only on a full reflash that wipes `/persistent`**. After reflashing
`kelpy` or `rk1b`, re-enter its new IP in the admin-console nameserver list. This
is the irreducible manual step — the same drift that killed the `porcupineFish`
secondary.

## Consequences

- `rk1b` now runs blocky in addition to the monitoring server, uptime watcher,
  out-of-band push, Home Assistant, and the aarch64 builder. This does **not**
  weaken DNS redundancy: `kelpy` (the primary) is a separate host, so DNS fails
  only if *both* die. Enabling blocky on `rk1b` also makes its own resolution
  self-sufficient (own DoH), and does **not** hijack the Cloudflare-hosted
  out-of-band push relay — `push.palebluebytes.space` is not in
  `settings.services`, so blocky forwards it upstream unchanged.
- Ad-block on a roaming laptop still only applies while it is on the tailnet;
  off-tailnet it uses the local network's resolver. Accepted, given the
  captive-portal cost of the alternative.
- The `domain = settings.nodes.kelpy.domain` binding in `blocky.nix` is a naming
  smell, not a bug: it equals the fleet `primaryDomain`, so it reads the same
  value on `rk1b`. Left as-is; renaming to a fleet-level accessor is optional.
