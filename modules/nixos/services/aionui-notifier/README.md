# aionui-notifier

Posts AionUi agent events to a Matrix room so you can review from your phone.
A small stdlib-Python poller watches the local `aioncore` API and sends a message
on three transitions:

| Event | Signal |
|-------|--------|
| `✅ finished: <name>` | conversation `status == "finished"` and `modified_at` advanced (no pending confirmation) |
| `❓ needs input: <name> — <tool>` | a new pending tool/permission approval appears in `/api/conversations/{id}/confirmations` |
| `⚠️ error (<status>): <name>` | conversation `status` becomes `failed`/`cancelled` |

`aioncore` runs in `--local` mode, so its `/api/*` is reachable on localhost without
auth.

> Why a poller and not a native AionUi Matrix *channel*: on the headless WebUI
> backend (`aioncore`), extension channel plugins are **metadata-only** — aioncore
> won't run an extension-provided channel. Only its built-in Rust channels
> (Telegram/Lark/DingTalk/WeChat) actually connect. A native Matrix channel would
> need a fork of `aioncore`. The poller delivers the same events with no fork.

## Delivery (webhook-only, via matrix-hookshot)

Each event is POSTed as `{"text": …}` to a [matrix-hookshot](../../profiles/matrix/hookshot.nix)
generic webhook; hookshot owns the Matrix side (room, formatting, posting). The
notifier has no bot, login, or token of its own. `webhookUrlFile` points at a
file holding the webhook URL — it may be empty initially and the notifier idles
until it's written, then delivers without a restart. See
[ADR-0024](../../../../docs/adr/0024-matrix-hookshot-webhooks-and-feeds.md).

## Setup (fully declarative)

Just enable it on the host (e.g. `hosts/kelpy/configuration.nix`); it requires
the hookshot bridge (`custom.profiles.matrix.hookshot.enable`):

```nix
custom.profiles.aionui = {
  enable = true;                 # the AionUi WebUI itself
  notifications.enable = true;   # provisions the room + hookshot connection
};
```

The `aionui-hookshot-provision` oneshot (in `profiles/aionui.nix`) reuses the
hookshot appservice `as_token` to create the `#aionui-alerts` room and a generic
webhook connection (with a persisted secret hook id), then writes the webhook URL
to `webhookUrlFile`. No manual `webhook` bot command and no notifier secret.

`just deploy kelpy`, then accept the room invite from your phone. The journal
shows `aionui hookshot connection provisioned in !…` then the notifier delivering.

## Options (`services.aionui-notifier`)

`enable`, `aionuiUrl`, `webhookUrlFile`, `pollInterval` (default 10s), `stateDir`,
`user`/`group`.

State (per-conversation status, the persisted hook id, the webhook URL file) lives
in `stateDir` (`/var/lib/aionui-notifier`, persisted under impermanence). On first
ever run the notifier seeds state silently so you don't get a backlog.

## Troubleshooting

- `journalctl -u aionui-notifier -f` and `journalctl -u aionui-hookshot-provision`.
- No messages: check the provision unit succeeded (`provisioned in !…`) and that
  the `@hookshot` bot is in the room; confirm `hookshot_webhook_url` exists in the
  state dir. The notifier logs an idle notice until that file has content.
