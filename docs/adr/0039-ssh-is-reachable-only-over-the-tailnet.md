# SSH is reachable only over the tailnet

Every host that runs sshd — kelpy, rk1a, rk1b, porcupineFish — had port 22 open on every
interface, because `services.openssh.openFirewall` defaults to true and nothing had ever
turned it off. On kelpy that is a public address: an internet-wide key-only prompt,
answering every scanner that walks the v4 space.

Key-only SSH is good authentication, and that is what made the open port easy to leave
alone. But it is authentication offered to anyone who asks. The fleet has not addressed a
host by a routable non-tailnet address in a long time: `flake.settings.tailnet` is the
suffix every scrape target, Gatus probe and Caddy upstream uses, `just deploy <host>`
dials the bare MagicDNS name, and `programs.ssh.knownHosts` pins the fleet keys under
their MagicDNS forms. The reachable surface was wider than the used one, and had been for
months.

## Decision

**sshd is reached over `tailscale0` and nowhere else.** `custom.profiles.ssh` sets
`openFirewall = false` by default (`tailnetOnly`, on everywhere); the way in is that
`custom.profiles.tailscale` already lists `tailscale0` in `networking.firewall.trustedInterfaces`.

- **The firewall, not `ListenAddress`.** Binding sshd to the tailscale address would mean
  knowing that address at build time and would race the interface at boot — a sshd that
  fails to start because `tailscale0` has not appeared yet is a worse failure than a
  filtered port. Binding everywhere and filtering the way in has neither problem, and it
  is the same shape the forge already uses for git-over-SSH
  (`modules/nixos/profiles/forge.nix`).
- **On by default, with an assertion rather than a footgun.** `tailnetOnly` without
  `custom.profiles.tailscale` would leave a host with no interface at all to answer on,
  and a lockout that evaluates green is exactly the kind this repo asserts against. A host
  that genuinely must answer an untrusted network sets it false and says why at the call
  site.
- **kelpy's sudo password goes with it.** It was defence-in-depth against a public SSH
  prompt (`hosts/kelpy/configuration.nix`); with no public prompt left it only cost a
  password typed into every deploy, and made kelpy the one host whose non-interactive
  deploy could hang on stdin. kelpy now enables `custom.profiles.sudo` like the rest of
  the fleet, and the `--ask-sudo-password` special case leaves the `Justfile`.

## What this costs

- **Tailscale becomes the only remote door.** If `tailscaled` fails to come up, the host
  is unreachable until someone reaches it physically — or, for kelpy, through the
  vpsAdmin remote console, which is the escape hatch this decision assumes exists. The
  tailscale state directory is already persisted through impermanence, and the auth key
  is a sops secret installed before the service starts, so a boot that loses the tailnet
  is a boot that lost its secrets too.
- **First contact with a fresh machine needs a plan.** A newly imaged host joins the
  tailnet at first boot from its auth key, so the normal path is unaffected; a machine
  that has not been given one yet must be provisioned at the console or with
  `tailnetOnly = false` for exactly that first switch.
- **LAN-address SSH stops working.** `ssh 192.168.x.y` to an rk1 node or the Pi now
  times out. Use the name.

## Consequences

- `custom.profiles.ssh.tailnetOnly`, default true, in
  [`modules/nixos/profiles/ssh.nix`](../../modules/nixos/profiles/ssh.nix).
- `custom.profiles.sudo` is now enabled on every host that runs sshd, so passwordless
  wheel sudo is a fleet invariant rather than a per-host convenience.
- Deploy order matters once, in the direction that cannot lock you out: kelpy's switch
  closes its own port 22 while you are connected over the tailnet — an established
  connection is unaffected, and the next one comes in the same way.
