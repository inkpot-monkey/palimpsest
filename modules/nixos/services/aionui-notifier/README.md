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
auth. Delivery uses the Matrix client-server API.

> Why a poller and not a native AionUi Matrix *channel*: on the headless WebUI
> backend (`aioncore`), extension channel plugins are **metadata-only** — aioncore
> won't run an extension-provided channel. Only its built-in Rust channels
> (Telegram/Lark/DingTalk/WeChat) actually connect. A native Matrix channel would
> need a fork of `aioncore`. The poller delivers the same events with no fork.

## Setup (mostly declarative — one secret)

The notifier **self-bootstraps**: from the bot password and the homeserver's
registration token it registers the bot if needed, logs in, and resolves the room
alias — creating the alerts room (and inviting you) on first run. There is **no
manual access-token or room-id copying**.

The single manual step is adding the bot password to sops:

```console
$ sops secrets/profiles/matrix.yaml      # add one line:
aionui_matrix_bot_password: <a strong password>
```

Then enable it on the host (e.g. `hosts/kelpy/configuration.nix`):

```nix
custom.profiles.aionui = {
  enable = true;            # the AionUi WebUI itself
  notifications.enable = true;
  # notifications.room and notifications.inviteUser default to
  #   #aionui-alerts:matrix.<domain>  /  @inkpotmonkey:matrix.<domain>
};
```

`just deploy kelpy`, then accept the room invite from your phone (Matrix client).
On first start the journal shows `registered bot …` / `created room … -> !…`.

## What the profile wires (see `modules/nixos/profiles/aionui.nix`)

- sops secrets from `profiles/matrix.yaml`: `aionui_matrix_bot_password` (you add)
  and `aionui_registration_token` (re-decrypts the existing `registration_token`
  for the notifier user, so it can self-register the bot).
- `services.aionui-notifier` pointed at the local Conduit + aioncore, with the
  room alias / invite derived from `networking.domain`.

## Options (`services.aionui-notifier`)

`enable`, `aionuiUrl`, `matrixUrl`, `room` (alias `#…` or id `!…`), `botUser`,
`passwordFile`, `registrationTokenFile` (optional self-register), `inviteUser`,
`pollInterval` (default 10s), `stateDir`, `user`/`group`.

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
