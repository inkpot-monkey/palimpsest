# Split-horizon DNS via blocky with runtime tailscale-IP resolution

`modules/nixos/profiles/blocky.nix` serves split-horizon DNS for `*.palebluebytes.space`. Public services resolve to static `customDNS` entries, but **Tailscale-targeted** services (litellm, monitoring, the LLM nodes, …) are resolved at **runtime**: a `blocky-service-hosts` generator runs `tailscale ip -4 <node>` for each, writes a hosts file, and blocky loads it via `hostsFile.sources`.

This indirection exists because a Tailscale IP drifts when a node re-registers (a reflash gave `porcupineFish` a new TS IP and broke hardcoded DNS), and blocky's `customDNS` is **IP-only** — it can't `CNAME` to a node's MagicDNS name. So the IPs cannot be static and cannot be aliased; they must be looked up live. blocky is pinned to **0.30 fleet-wide** (injecting the unstable package) because 0.27 — what the pinned Pi toolchain otherwise provides — doesn't serve local hostsFile entries the same way.

## Consequences

- The generator must wait for *all* peers before writing (tailscale streams its netmap in gradually; breaking on the first write locks in a partial file), and must not write into `/run/blocky` (blocky wipes its own `RuntimeDirectory` on restart) — use `/run/blocky-services`.
- blocky's metrics/API port must be scoped to `tailscale0`, never global `allowedTCPPorts`.
