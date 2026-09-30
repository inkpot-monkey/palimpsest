# Runbook: migrating Gmail into Stalwart

Moves the whole Gmail archive into the self-hosted Stalwart mailbox on `kelpy`, tags
every imported message with the flat keyword **`gmail`**, marks them all **read**, and
points new Gmail arrivals at Stalwart by forwarding.

Mail server: [`modules/nixos/profiles/mail/default.nix`](../../modules/nixos/profiles/mail/default.nix)
(enabled on `kelpy` in [`hosts/kelpy/configuration.nix`](../../hosts/kelpy/configuration.nix)).
Scripts: `.scratch/gmail-migration/` (gitignored — one-off, not fleet config).

## The trap: jmap-bridge shares this mailbox

`jmap-bridge` is **active on kelpy** and bridges the *same* `thomas` mailbox into
Matrix, one room per thread. `src/sync/backfill.rs` issues an **unfiltered**
`Email/query` — no mailbox, keyword or `$seen` condition — and live sync polls
`Email/changes` against a saved state token.

So an unguarded import mints a Matrix room per imported thread, and **marking the mail
read does not prevent it**: the bridge never looks at `$seen`.

Historical backfill is already finished on kelpy and self-terminates on every start
(`"Initial sync complete and no backfill position found. Terminating backfill task."`),
so the live-sync path is the only exposure. The fix is to stop the bridge for the
import window and then fast-forward its `changes` state to the post-import `Email`
state, so it resumes *after* the import and never replays it.

## Decisions baked in

| decision | choice | why |
| --- | --- | --- |
| Transport | `imapsync` for the copy, then one JMAP pass | imapsync is resumable and Gmail-aware; JMAP sets arbitrary keywords and `$seen` natively |
| Source scope | **`[Gmail]/All Mail` only** | exactly one copy of everything. Gmail shows each labelled message in its label folder too, so syncing folders as well double-imports. Excludes Spam/Trash by Gmail's design |
| Destination | a dedicated **`Gmail`** mailbox | keeps the live 632-message Inbox usable. Change `IMPORT_MAILBOX` in `env.sh` to merge into Inbox instead |
| Labels | flat `gmail` keyword only | what was asked for. Gmail labels are *not* recoverable over All Mail IMAP — only a Takeout export carries `X-Gmail-Labels`. Decide before importing if you ever want them |
| Cutover | Gmail forwards **and keeps its copy** | `backup.enable = false` fleet-wide, so a populated Gmail is currently the only second copy of this mail |

## Credentials

- **Stalwart** (`thomas`): `email_password` in `secrets/profiles/mail.yaml`. The scripts
  decrypt it with the `&admin` age identity derived from `~/.ssh/id_ed25519` via
  `ssh-to-age` — the same dance as [`parts/apps/dns/default.nix`](../../parts/apps/dns/default.nix)
  and for the same reason (commit `2df7172`): sops 3.13 does not look at
  `~/.ssh/id_ed25519`, and `SOPS_AGE_SSH_PRIVATE_KEY_FILE` cannot open the native
  `age1…` recipients this fleet encrypts to. Run from the operator workstation, which
  holds `&admin` — not from a headless host.
- **Gmail**: a Google **app password** (needs 2FA on the account), in
  `.scratch/gmail-migration/gmail.creds`, mode 600 — address on line 1, password on
  line 2. **Revoke it at <https://myaccount.google.com/apppasswords> once verified**
  rather than leaving it on disk.

JMAP note: the session document advertises `apiUrl` as `http://mail.palebluebytes.space:8081/jmap/`
— the *internal* listener, which is not in the firewall and is unreachable off-kelpy.
From a workstation, go through Caddy at `https://mail.palebluebytes.space/jmap/`.
`/.well-known/jmap` answers `307` to `/jmap/session`.

## Procedure

```bash
cd ~/code/nixos/.scratch/gmail-migration
```

1. **Size the job** (read-only, touches nothing):

   ```bash
   ./01-probe.sh
   ```

   Note the `[Gmail]/All Mail` message count — it sizes everything below, and it is the
   number to check the single-copy-backup concern against.

1. **Stop the bridge** for the import window (prompts for your kelpy sudo password):

   ```bash
   ./bridge.sh state     # record the current `changes` token first
   ./bridge.sh stop
   ```

1. **Dry-run the copy**, then run it:

   ```bash
   ./02-sync.sh          # dry
   ./02-sync.sh --go
   ```

   Idempotent and resumable — imapsync matches on headers and skips what is already
   there, so re-run after any interruption rather than starting over. Logs land in
   `run/imapsync-log/`.

1. **Tag and mark read**:

   ```bash
   . ./env.sh && export STALWART_PW="$(stalwart_pw)"
   ./03-tag-read.py         # dry: prints how many lack `gmail` / `$seen`
   ./03-tag-read.py --go
   ```

   Batches are sized to the server's advertised `maxObjectsInSet` (500 here). On success
   it prints `EMAIL_STATE=<token>` — that token is the next step's input.

1. **Fast-forward the bridge, then start it**:

   ```bash
   ./bridge.sh ff <token>   # refuses loudly unless exactly 1 row matches
   ./bridge.sh start
   ```

   Then watch that no room storm begins:

   ```bash
   ssh kelpy 'journalctl -u jmap-bridge -f'
   ```

1. **Set up forwarding** — Gmail web UI, *Settings → Forwarding and POP/IMAP → Add a
   forwarding address*. Gmail emails a confirmation code to the Stalwart mailbox; read
   it there and confirm. Choose **"keep Gmail's copy in the Inbox"**.

   Forwarded mail keeps its original `From:` while arriving from Google's servers, so
   SPF/DMARC alignment breaks and Stalwart's spam filter may junk some of it. Watch
   `Junk Mail` for the first few days before trusting the path.

## Verify

```bash
. ./env.sh && export STALWART_PW="$(stalwart_pw)"
./03-tag-read.py --verify     # expect: missing keyword 0, not $seen 0
```

Baseline before the migration, for comparison (2026-09-29): Inbox 632 / 263 unread,
Sent Items 56, Deleted Items 17, Junk 0, Drafts 0.

## Rollback

The import only ever *adds*; nothing deletes from Gmail, and `--delete2` is never passed.

- **Undo the import**: delete the `Gmail` mailbox in any IMAP client. The source is
  untouched in Gmail.
- **Bridge replaying the archive into Matrix**: stop `jmap-bridge`, re-run
  `./bridge.sh ff <token>` with the post-import token, start it. Rooms already created
  must be cleaned up in Matrix — see the `matrix-reset` wiring in
  [`modules/nixos/profiles/matrix/jmap-bridge.nix`](../../modules/nixos/profiles/matrix/jmap-bridge.nix),
  but note a reset wipes the bridge DB and *re-triggers* full backfill.
- **Forwarding**: remove the address in Gmail settings.

## Standing caveat

`backup.enable = false` fleet-wide, so this archive is **single-copy on kelpy** once
imported. That is the reason the cutover keeps Gmail's copy. Revisit if backups land.
