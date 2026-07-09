# push-relay

The out-of-band alert **Push relay** (ADR-0020): a self-hosted, ntfy-compatible
**web-push** service. `rk1b`'s watcher publishes to it when the Matrix delivery path
is down; it delivers a browser push to the operator's installed phone PWA. Off-site
(a Cloudflare Worker) so it survives `kelpy` being down.

## Layout

| Path | What | Status |
|------|------|--------|
| `core/` | Portable, I/O-free Rust crate: RFC 8291 (`aes128gcm`) encryption + RFC 8292 (VAPID/ES256). The host-agnostic asset; compiles into a Worker *or* a Spin/WASI component. | **built + tested** (RFC 8291 Appendix A interop vector passes) |
| `worker/` | `workers-rs` shell: `/sub`, ntfy publish, Workers KV, outbound `fetch`. Uses `core/`. | scaffold (verify at deploy) |
| `public/` | The PWA: `index.html`, `sw.js`, `manifest.json`. | scaffold (verify at deploy) |
| `wrangler.toml` | Worker + KV + custom-domain config. | scaffold |

## Verify the core crate (AFK)

```
cd core && cargo test     # RFC 8291 Appendix A vector + VAPID JWT round-trip
```

## Remaining HITL (slice 01 — the bootstrap)

1. Generate a VAPID keypair; put these keys into `secrets/profiles/monitoring.yaml`
   (sops), alongside the grafana secrets:
   `vapid_private`, `vapid_public`, `publish_token`, `cloudflare_token`,
   `cloudflare_account_id`. The topic phrase stays a plain (non-secret) value.
   - `publish_token` is the **write** capability rk1b presents (opaque, high-entropy —
     `openssl rand -base64 32 | tr '+/' '-_' | tr -d '='`); the topic phrase is the
     **read**/subscribe capability. Keep them distinct.
   - `cloudflare_token` needs the **"Edit Cloudflare Workers"** token template
     (Account → Workers Scripts + Workers KV; Zone `palebluebytes.space` → Workers
     Routes + DNS, for the `push.` custom domain).
1. Nothing to pre-create: the first `wrangler deploy` provisions the Worker, the SUBS
   KV namespace (auto-provisioning, [Beta]), and the `push.palebluebytes.space` custom
   domain. VAPID public key + account id come from sops; nothing per-deploy is committed.
1. `just deploy-push-relay` (≡ `nix run .#push-relay-deploy`): hermetic — pins the wasm
   toolchain + `wrangler`, reads sops, builds, `wrangler secret put`, then `wrangler deploy`.
   Run it from the operator workstation (holds `&admin`), never a headless host.
1. On the phone: open the PWA, Add to Home Screen, allow notifications, subscribe.
1. `curl` the relay → confirm the phone buzzes. Then enable the `rk1b` `ntfy` alerter
   (issue 04) and force a `matrix`/`hookshot` probe failure to prove the out-of-band path.

See `.scratch/push-relay/` for the per-slice issues.
