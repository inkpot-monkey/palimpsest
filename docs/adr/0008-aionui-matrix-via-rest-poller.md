______________________________________________________________________

## status: superseded by ADR-0025

# AionUi→Matrix notifications via a REST poller, not a native aioncore channel

> **Superseded by [ADR-0025](0025-claude-relay-matrix-interface.md):** the one-way poller
> is replaced by the Claude relay's two-way, transcript-driven Matrix interface. This ADR's
> deferral ("if richer two-way Matrix integration is ever wanted, reopen the fork decision
> deliberately") is exactly what ADR-0025 does.

AionUi can surface agent events (finished / needs-input / error) into a Matrix room. This is done with a small standalone poller (`services.aionui-notifier`) that watches aioncore's local `/api` and posts to Matrix via the client-server API — *not* by writing a native AionUi "channel" for Matrix.

A spike established that the native-channel route is not viable on the headless `aioncore` backend: an extension can register a channel's metadata/config UI, but aioncore runs extension channels in **metadata-only mode** — there is no runtime path to actually connect/send/receive. Only the compiled-in Rust channel plugins run. A real Matrix channel would mean forking aioncore (Rust) and adding a `plugins/matrix/`, i.e. weeks of build-from-source and ongoing maintenance, versus ~half a day for the poller.

## Consequences

- The poller is intentionally outside AionUi; it self-registers its bot and auto-creates the alerts room, so the only manual step is adding `aionui_matrix_bot_password` to the stash.
- If richer two-way Matrix integration is ever wanted, reopen the fork decision deliberately — don't assume the extension system can do it.
