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

## Delivery modes

- **Webhook mode (preferred, current default on kelpy).** Set `webhookUrlFile`
  to a file holding a [matrix-hookshot](../../profiles/matrix/hookshot.nix) generic
  webhook URL. Each event is POSTed as `{"text": …}` and hookshot owns the Matrix
  side — no bot login, room, or token here. See [ADR-0024](../../../../docs/adr/0024-matrix-hookshot-webhooks-and-feeds.md).
- **Matrix-direct mode (legacy).** Leave `webhookUrlFile` unset and the notifier
  self-bootstraps a bot (registers if needed, logs in, resolves/creates the room
  alias) and posts straight to a room via the client-server API.

## Setup (webhook mode)

In Matrix, invite the `@hookshot` bot to a room and create a generic webhook
(`webhook` bot command); copy its URL into sops (it may start empty — the notifier
idles until the URL is present, then delivers without a restart):

```console
$ sops secrets/profiles/matrix.yaml      # add one line (value can be empty at first):
aionui_hookshot_webhook_url: https://hookshot.<domain>/webhook/<id>
```

Enable it on the host (e.g. `hosts/kelpy/configuration.nix`):

```nix
custom.profiles.aionui = {
  enable = true;            # the AionUi WebUI itself
  notifications.enable = true;   # wires webhookUrlFile to the sops secret above
};
```

`just deploy kelpy`. On first start the journal shows `webhook URL loaded; delivering
events` (or an idle notice until the URL is set).

## Options (`services.aionui-notifier`)

`enable`, `aionuiUrl`, `webhookUrlFile` (webhook mode), `matrixUrl`, `room`
(matrix-direct, alias `#…` or id `!…`), `botUser`, `passwordFile`,
`registrationTokenFile` (optional self-register), `inviteUser`, `pollInterval`
(default 10s), `stateDir`, `user`/`group`.

State (cached token, room id, per-conversation status) lives in `stateDir`
(`/var/lib/aionui-notifier`, persisted under impermanence). On first ever run the
notifier seeds state silently so you don't get a backlog of notifications.

## Troubleshooting

- `journalctl -u aionui-notifier -f`.
- `register: bot user exists but login failed — check the password`: the bot was
  created with a different password; reset it or change `aionui_matrix_bot_password`.
- No messages: confirm the bot accepted into the room (it auto-creates+invites when
  it owns the alias; for a pre-existing room, make sure the bot is a member).
- Token rotated/invalid: the notifier re-logs-in on a 401 automatically.
