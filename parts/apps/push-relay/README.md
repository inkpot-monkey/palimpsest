# push-relay

The out-of-band alert **Push relay** (ADR-0027): a self-hosted, ntfy-compatible
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

1. Generate a VAPID keypair; put the private key + a publish token + a Cloudflare API
   token into the `secrets` repo (sops). The VAPID *public* key + the topic phrase are
   plain values.
1. Create the Worker + a KV namespace + the `push.palebluebytes.space` custom domain.
1. `just deploy-push-relay` (pushes secrets via `wrangler secret put`, then `wrangler deploy`).
1. On the phone: open the PWA, Add to Home Screen, allow notifications, subscribe.
1. `curl` the relay → confirm the phone buzzes. Then enable the `rk1b` `ntfy` alerter
   (issue 04) and force a `matrix`/`hookshot` probe failure to prove the out-of-band path.

See `.scratch/push-relay/` for the per-slice issues.
