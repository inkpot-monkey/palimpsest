# Runbook: accept the upstream Supernote server with a real Nomad (palimpsest#112)

palimpsest#112 retired the vendored `inkpot-monkey/supernote` fork and pinned **upstream**
`allenporter/supernote` at an explicit revision. Everything that CI can prove is proven: the
package builds, and both Private Cloud VM checks (`supernote`, `supernote_ereader`) pass.

**The last acceptance criterion cannot be run by CI or by an agent** — it needs the physical
device. This runbook is that step. Until it is done and this file's checklist is ticked, the
upstream cutover is *unverified on hardware*.

Design: ADR-0031. Profile:
[`modules/nixos/profiles/supernote.nix`](../../modules/nixos/profiles/supernote.nix).

## Why the device step is not a formality

The fork existed to add a device planner/realtime surface upstream lacked. Upstream has since
implemented that surface **independently** — same routes, different code. The VM checks cover
the *file* surface (bind, bootstrap, login, MCP-port firewalling, the ereader round-trip),
because that is what this deployment drives. They do **not** drive the planner, summary-digest,
or realtime paths — only a real Nomad does.

Five upstream gaps are already known and filed. Expect to meet some of them:

| Issue | What breaks | Banner you would see |
| --- | --- | --- |
| #136 | `delete/summary` is POST-only; the device sends `DELETE` | "digest sync failed" |
| #137 | Planner writes are insert-only and numeric-id-only | planner sync error / duplicate tasks |
| #138 | Planner deletes are hard deletes, no tombstone | deleted tasks reappear |
| #139 | `PUT task/list` batch is update-only, drops `isDeleted` | planner batch sync error |
| #140 | Upload response echoes the requested path; no rogue-root self-heal | none expected — dormant on this store |

The **realtime socket** surface is expected to be fine (upstream serves socket.io with the real
library and `allow_eio3=True`), but note upstream now *verifies the handshake `sign`* where the
fork accepted any — see step 5.

## Before you start

1. **Back up the store DB.** The upstream pin crosses alembic migrations. On `rk1b`:

   ```bash
   sudo -u supernote sqlite3 /var/lib/supernote/system/supernote.db \
     ".backup '/var/lib/supernote/pre-112-backup.db'"
   ```

   If `sqlite3` is not on the host, stop the unit and copy the file instead:

   ```bash
   sudo systemctl stop supernote-server
   sudo cp -a /var/lib/supernote/system/supernote.db /var/lib/supernote/pre-112-backup.db
   ```

1. **Note the current JWT key** so you can tell a token invalidation from a real auth failure:

   ```bash
   sudo cat /var/lib/supernote/jwt-secret | head -c 8
   ```

   It must be unchanged after the deploy — the ExecStart wrapper only mints one when absent.

## Deploy

```bash
nixos-rebuild --target-host rk1b --sudo --ask-sudo-password switch --flake .#rk1b
```

Then confirm the server came back on the upstream build and the account still authenticates:

```bash
ssh rk1b systemctl status supernote-server supernote-account-bootstrap
ssh rk1b 'readlink -f $(systemctl show -p ExecStart --value supernote-server | grep -o "/nix/store/[^ ]*")'
# → …-supernote-0.17.0 (not the old fork build)
ssh rk1b 'sudo cat /var/lib/supernote/jwt-secret | head -c 8'   # unchanged
```

`supernote-account-bootstrap` must reach `active` and log `account present, login OK` — the
idempotent path. If it logs `account bootstrapped` instead, the DB was reset; stop and
investigate before touching the device.

## The device pass

Do these in order, on the Nomad, on the home LAN (the device cannot use Tailscale).

### 1. Sync completes at all

*Settings → Sync → Private Cloud*, then sync. **Expected:** it completes with no banner.

Watch the server side while it runs:

```bash
ssh rk1b journalctl -u supernote-server -f
```

Look for `POST /api/file/2/files/synchronous/start` (the sync opening) and any non-2xx.

### 2. A document lands on the device

```bash
ssh rk1b 'sudo install -o git-annex -g library -m 664 /path/to/book.pdf /var/cache/library/ereader-outbox/'
```

Sync again. **Expected:** `book.pdf` appears on the device under `Document/ereader`, the outbox
is empty, and the file is mirrored into `/var/cache/library/ereader/`.

```bash
ssh rk1b journalctl -u supernote-ereader-reconcile -n 20 --no-pager
# → ereader reconcile: sent=1 downloaded=1 deleted=0
```

### 3. A device-side delete is durable

Delete `book.pdf` on the device. Sync. Sync **once more**.

**Expected:** it is gone from `/var/cache/library/ereader/` and does **not** come back.

```bash
ssh rk1b journalctl -u supernote-ereader-reconcile -n 20 --no-pager
# → deleted=1, then sent=0 downloaded=0 deleted=0
```

### 4. Annotate a note and sync back

Open a `.note` on the device, add a stroke, sync. **Expected:** no banner; the updated file is
visible in the store.

### 5. The realtime channel connects

This is the surface most likely to behave differently from the fork, because upstream verifies
the handshake signature and the fork did not.

```bash
ssh rk1b journalctl -u supernote-server | grep -i "socket"
```

**Expected:** `Socket.IO connection established for user=…`.

**If you instead see** `sign verification failed`, the device's signature does not match
upstream's `compute_handshake_signature` (`supernote/server/socket_auth.py`, pre-shared key
`SOCKET_IO_KEY`). That is a new gap — file it, with the failing log line and the handshake query
string, and reference #112.

### 6. Planner and summary

Create a task on the device, complete one, delete one. Delete a summary. Sync after each.

**Expected:** this is where #136–#139 bite. Record precisely which banner appears after which
action and add it to the matching issue — that observation is the main thing this pass buys,
beyond the file round-trip.

## If it goes wrong

Roll back by reverting the `supernote` input rev in `flake.nix` to the fork commit
`3d0809226ab6d94b055fc880ee306023b8e4bf59` (`github:inkpot-monkey/supernote/fix/device-schedule-group-all`),
`nix flake update supernote`, redeploy, and restore the DB backup taken above. The fork branch
still exists; #112 only stopped tracking it.

## Checklist

- [ ] DB backed up, JWT key noted
- [ ] Deployed; server on `supernote-0.17.0`; bootstrap took the idempotent path; JWT unchanged
- [ ] 1. Sync completes with no banner
- [ ] 2. Outbox document reaches the device and mirrors down
- [ ] 3. Device-side delete propagates and stays deleted
- [ ] 4. Annotated note syncs back
- [ ] 5. Realtime channel connects (`Socket.IO connection established`)
- [ ] 6. Planner/summary behaviour recorded against #136–#139

When 1–5 pass, #112's final criterion is met. Note the date and the device firmware version here:

> Accepted on: _(date)_ — firmware _(version)_ — by _(who)_
