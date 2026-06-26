# Out-of-band alerts via a self-hosted, ntfy-compatible web-push relay on Cloudflare

______________________________________________________________________

## Status: accepted (supersedes the "ntfy is the sole out-of-band channel" consequence of [ADR-0026](0026-uptime-alerting.md))

[ADR-0026](0026-uptime-alerting.md) deferred the **out-of-band channel** — the notification path that shares none of `kelpy`'s failure domain — to "ntfy" (the public ntfy.sh). ntfy.sh is no longer free, so we replace it with a **self-hosted, ntfy-compatible web-push relay**: a **Cloudflare Worker written in Rust→WASM** that accepts a publish from the `rk1b` **watcher** and delivers a browser **push notification** to the operator's installed phone **PWA**. It is off-site (so it survives `kelpy` being down) and fires *only* when the Matrix delivery path itself can't deliver. See the **Push relay** and **Out-of-band channel** terms in [CONTEXT.md](../../CONTEXT.md).

## Considered Options

- **Public ntfy.sh** — rejected: no longer free, which is the whole reason this ADR exists.
- **Self-hosted ntfy on home hardware** — rejected: wrong failure domain. The out-of-band channel must be *off-site*; an ntfy server on `kelpy`/`rk1b` dies in the same outage it is meant to report.
- **Telegram / Discord bot** — rejected for v1: free and reliable, but third-party-app-dependent and off-brand for a self-owned fleet. Kept in reserve as a delivery fallback if Web Push proves flaky in practice.
- **PushForge (JS) on a Worker** — rejected: the fastest build, but JavaScript does not port off Cloudflare. "Portability" would mean a rewrite, which defeats the stated goal.
- **Fermyon Spin / a pure WASI component** — *deferred, not rejected.* This is the most portable target and is genuinely buildable today (Spin's KV + outbound HTTP + HTTP trigger, with RustCrypto compiled in). The blocker is hosting: its free, always-on, off-site home (Fermyon Cloud's free tier) is strategically wobbly given Fermyon's pivot to Akamai, whereas Cloudflare's free Workers tier is entrenched and the account is already held. The Rust core crate below keeps this path a redeploy rather than a rewrite.
- **Cloudflare Worker in Rust→WASM (chosen)** — entrenched free tier, account already in hand, and the crypto/push logic lives in a standalone, I/O-free core crate so the Cloudflare-specific shell is swappable for Spin/WASI later. Best blend of "free and reliable today" with "not locked in tomorrow."

## Consequences

- **Supersedes ADR-0026's "ntfy is the sole out-of-band channel."** The realized out-of-band channel is now the **Push relay**; ntfy is a *protocol* it speaks, not the service it uses.
- **Portability is a built asset, not a promise.** A `push-relay` **core crate** — RustCrypto P-256 VAPID signing + HKDF + aes128gcm payload encryption, **no I/O** — compiles unchanged into a Spin/WASI component. Only the thin shell (routing, Workers KV, secrets, outbound `fetch`, serving the PWA) is Cloudflare-specific. Leaving Cloudflare swaps the shell, never the crate.
- **ntfy-shaped on purpose.** The relay implements the minimal ntfy *publish* protocol so Gatus's stock `ntfy` alerter drives it. This sidesteps Gatus's single-`custom`-provider limit (already spent on the hookshot webhook) and means any ntfy client can target it later.
- **Fires only on the delivery path.** The `ntfy` alerter is attached to the `matrix` + `hookshot` endpoints *only* — the phone buzzes exactly when the in-band Matrix path can't carry the message, not for an ordinary "a service is down while `kelpy` is up" (which Matrix still handles). Recovery notices ride Gatus's `send-on-resolved`.
- **Capability model.** The **subscribe** capability is a *memorable phrase* (`adjective-noun-noun`) that doubles as the ntfy **topic** — knowing it lets a device subscribe. **Publishing** additionally requires an opaque server token held only by `rk1b`, because a publish can buzz the phone. The VAPID private key, the publish token, and the Cloudflare API token are **sops-canonical** and pushed into the Worker at deploy; the deploy runs from the workstation (which holds `&admin` and can decrypt sops — *not* a headless host).
- **Packaging.** Source starts in-repo at `parts/apps/push-relay/` (core crate + Worker shell + PWA), deployed by a `wrangler` `just` recipe — a candidate for later extraction to its own public repo (the jmap-bridge trajectory, ADR-0017). Served at `push.<domain>` as a Worker custom domain, so dnscontrol `IGNORE`s the record exactly like the apex.
- **Still does not cover a full-site blackout.** The relay needs `rk1b` alive to publish, so a power/ISP outage is uncovered — that remains ADR-0026's named-but-unbuilt **dead-man's switch**. But a Cloudflare Worker is a natural future home for it (a cron trigger alerting on the *silence* of an `rk1b` heartbeat), so this choice leaves that door open rather than foreclosing it.
- **Android-primary.** Chrome Web Push delivers with the browser closed; an iOS device would first need the PWA "Added to Home Screen" (noted, not built for).
