______________________________________________________________________

## status: superseded by ADR-0025

# AionUi has no app-level auth; the Tailscale boundary is load-bearing

> **Superseded by [ADR-0025](0025-claude-relay-matrix-interface.md):** AionUi is replaced
> by the Claude relay; its security reasoning no longer applies. Note the relay's boundary
> is *weaker* than this one (a public federated homeserver, not the Tailscale range) — see
> ADR-0025's security model for the deliberate trade-off.

AionUi is deployed on `kelpy` as a phone-accessible Claude Code frontend. In the headless `aionui-web` mode it always launches its `aioncore` backend with `--local`, which **disables the admin password** — `/api/*` answers 200 with no credentials. We accept this rather than patching auth in, because the surrounding network controls already constrain access.

The security therefore rests entirely on two external controls: the service binds to `127.0.0.1`, and Caddy fronts it as `internal_only` so it is reachable only from the Tailscale range over TLS. These are not defence-in-depth niceties — they are the *only* boundary. Never run aioncore with `--remote`, and never open the firewall port.

## Consequences

- Any change that exposes the AionUi port beyond loopback + Tailscale is a full compromise of whatever the agent can reach (it runs as `inkpotmonkey` and can execute arbitrary code). See [0003](0003-personal-key-is-sops-admin-key.md).
