# Runbook: accept the upstream Supernote server with a real Nomad (palimpsest#112)

palimpsest#112 retired the vendored `inkpot-monkey/supernote` fork and pinned **upstream**
`allenporter/supernote` at an explicit revision. (That is what this pass tested and is left as
written. It is **no longer the pin**: palimpsest#145 moved back to a fork rev, because upstream
cannot serve the device's realtime channel — see ADR-0031's 2026-08-18 revision.) Everything that CI can prove is proven: the
package builds, and both Private Cloud VM checks (`supernote`, `supernote_mirror`) pass.

**The last acceptance criterion cannot be run by CI or by an agent** — it needs the physical
device. This runbook is that step. Until it is done and this file's checklist is ticked, the
upstream cutover is *unverified on hardware*.

Design: ADR-0031. Profile:
[`modules/nixos/profiles/supernote.nix`](../../modules/nixos/profiles/supernote.nix).

## Why the device step is not a formality

The fork existed to add a device planner/realtime surface upstream lacked. Upstream has since
implemented that surface **independently** — same routes, different code. The VM checks cover
the *file* surface (bind, bootstrap, login, MCP-port firewalling, the downward mirror),
because that is what this deployment drives. They do **not** drive the planner, summary-digest,
or realtime paths — only a real Nomad does.

Six upstream gaps are already known and filed. Expect to meet some of them:

| Issue | What breaks | Banner you would see |
| --- | --- | --- |
| #136 | `delete/summary` is POST-only; the device sends `DELETE` | "digest sync failed" |
| #137 | Planner writes are insert-only and numeric-id-only | planner sync error / duplicate tasks |
| #138 | Planner deletes are hard deletes, no tombstone | deleted tasks reappear |
| #139 | `PUT task/list` batch is update-only, drops `isDeleted` | planner batch sync error |
| #140 | Upload response echoes the requested path; no rogue-root self-heal | none expected — dormant on this store |
| #142 | Concurrent logins for one account race a single-slot challenge | reconcile unit logs a 401 and retries |
| #145 | Realtime Socket.IO channel refuses every device handshake | none on the device; server logs a 400 loop |

**#142 is worth knowing before you start.** If `supernote-mirror` logs
`login 401 … probably a lost login challenge`, that is the device and the reconciler
authenticating against the shared account at the same moment — **not** a bad credential. It
retries and should recover. Only treat it as a credential problem if all five attempts fail.

The **realtime socket** surface is **known broken and is not a pass criterion** — see step 5.
This runbook used to say it "is expected to be fine (upstream serves socket.io with the real
library and `allow_eio3=True`)". That was wrong, and the pass of 2026-08-18 is what proved it:
`allow_eio3` is a JavaScript socket.io option that does not exist in the Python libraries at any
version, so it is silently discarded and upstream has never been able to accept an Engine.IO v3
client. Tracked as #145.

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

# Which build is actually running. ExecStart is a generated wrapper script, not the binary,
# so read the live process's argv rather than the unit's ExecStart.
ssh rk1b 'sudo tr "\0" " " < /proc/$(systemctl show -p MainPID --value supernote-server)/cmdline'
# → …/nix/store/<hash>-supernote-0.17.0/bin/supernote-server serve

ssh rk1b 'sudo cat /var/lib/supernote/jwt-secret | head -c 8'   # unchanged
```

`supernote-account-bootstrap` must reach `active` and log `account present, login OK` — the
idempotent path. If it logs `account bootstrapped` instead, the DB was reset; stop and
investigate before touching the device.

If the deploy **fails** on that unit instead, read the message rather than re-running: since
palimpsest#143 it has a bounded start and names which of the two things went wrong.

- `THE SERVER NEVER CAME UP` — the server did not answer within the bootstrap's 60-second
  readiness window. The credential was never offered to anything; the fault is the server (a
  migration, the store, the pinned rev). The tail of `journalctl -u supernote-server` is printed
  *above* that verdict — the server's own error is the last thing before it, deliberately, so
  that both survive the ten journal lines `nixos-rebuild` echoes for a failed unit. This is the
  failure that used to be a silent 35-minute deploy stall.
- `THE CREDENTIAL WAS REJECTED` — the server is up and answering, and the login did not work.
  **Re-run the unit once** before touching anything: a concurrent login for the same account
  401s the loser (palimpsest#142), and the device syncing at the wrong moment is enough to cause
  it. If it fails again, the account in the store no longer matches the secret — fix the
  `supernote` sub-map in the library sops bundle (commit, push, `nix flake update secrets`,
  redeploy), not the server.

One thing the bounded start gave up on purpose: the bootstrap no longer `Requires=` the server,
so restarting the server alone does not re-run it. A rev bump changes this unit too (its
ExecStart embeds the package), so the check above stays live for the deploys this runbook is
about; after a server-only change, `systemctl restart supernote-account-bootstrap` to refresh
the proof.

## The device pass

Do these in order, on the Nomad, on the home LAN.

> **The device *can* use Tailscale** — this runbook previously said it could not, which was true
> of the firmware the original spike ran but not since Ratta shipped sideloading (ADR-0031,
> revision 2026-08-17; the node is `supernote-nomad`). It changes nothing here: Private Cloud
> sync targets rk1b on the LAN, and the Android client does not capture LAN routes, so the pass
> below is the same whether the tunnel is up or down. Leave it however you find it.

### 1. Sync completes at all

*Settings → Sync → Private Cloud*, then sync. **Expected:** it completes with no banner.

Watch the server side while it runs:

```bash
ssh rk1b journalctl -u supernote-server -f
```

Look for `POST /api/file/2/files/synchronous/start` (the sync opening) and any non-2xx.

### 2. A document lands on the device

> **Retired mechanism — this step is a record, not a procedure.** palimpsest#117 removed the
> one-shot outbox and with it the whole upload direction, so `/var/cache/library/ereader-outbox/`
> no longer exists (a deploy deletes it) and the summary no longer carries a `sent=` field. #117
> also widened the mirror to the WHOLE device and renamed its root, so `/var/cache/library/ereader/`
> is gone too — the mirror is now `/var/cache/library/supernote/`, holding every folder the
> firmware seeds at the device's own relative paths (a synced document lands at
> `supernote/DOCUMENT/Document/<file>`, a notebook at `supernote/NOTE/Note/<file>.note`). The step
> is left as written because it is what was measured on 2026-08-18 and the checklist below is
> signed off against it. To get a book onto the device *now*, pull it from the catalog with the
> reader app — [`supernote-koreader-opds.md`](supernote-koreader-opds.md).

```bash
ssh rk1b 'sudo install -o git-annex -g library -m 664 /path/to/book.pdf /var/cache/library/ereader-outbox/'
```

Now sync **twice**, and expect the file only on the second one.

The reconciler is *triggered by* a device sync, so the first sync fires it and the upload into
the store lands a few seconds **after** that sync has already closed — the device cannot see a
file that arrived after it stopped listening. The second sync is the one that pulls it down.
Measured 2026-08-18: sync ended `15:12:41`, `sent` logged `15:12:45`. A single sync leaving the
device empty is **correct behaviour, not a fault** — do not go looking for one.

**Expected after the second sync:** `book.pdf` appears on the device under `Document/ereader`,
the outbox is empty (the send is one-shot), and the file is mirrored into
`/var/cache/library/ereader/`. Verify the content rather than the listing:

```bash
ssh rk1b 'sudo md5sum /var/cache/library/ereader/<file>'
adb shell md5sum /sdcard/Document/ereader/<file>   # if ADB is available; must match
```

```bash
ssh rk1b journalctl -u supernote-mirror -n 20 --no-pager
# → ereader reconcile: sent=1 downloaded=1 deleted=0   (as measured; the unit and its
#   summary format have both changed since — see the note above)
```

### 3. A device-side delete is durable

Delete `book.pdf` on the device. Sync. Sync **once more**.

**Expected:** it is gone from `/var/cache/library/ereader/` and does **not** come back.

```bash
ssh rk1b journalctl -u supernote-mirror -n 20 --no-pager
# → deleted=1, then sent=0 downloaded=0 deleted=0
# Since palimpsest#117 the unit is `supernote-mirror` and the summary reads
# `store=<n> downloaded=0 deleted=1`, then `store=<n> downloaded=0 deleted=0`. The behaviour
# asserted here is unchanged.
```

### 4. Annotate a note and sync back

Open a `.note` on the device, add a stroke, sync. **Expected:** no banner; the updated file is
visible in the store.

### 5. The realtime channel — known broken, record only

**This is no longer a pass criterion.** It cannot succeed on the current build, so do not spend
time on it; just record what you see and move on.

```bash
ssh rk1b journalctl -u supernote-server | grep -i "socket"
```

**Expected — the known failure (#145):** a 400 loop, roughly every 5s while the device is awake:

```
GET /socket.io/?…&EIO=3&transport=websocket&… HTTP/1.1" 400
```

`Socket.IO connection established for user=…` will **not** appear. Upstream passes
`allow_eio3=True`, which does not exist in python-socketio or python-engineio at any version and
is silently discarded, so the device's `EIO=3` handshake is refused at version negotiation —
before the signature is ever checked. The fork's hand-rolled `realtime.py`, retired by #112, was
carrying this.

**Impact: none.** Upstream's `send_message()` has no callers and `server/app.py:398` discards the
socket manager, so the push path is unreachable dead code. File sync and the planner routes are
plain REST and unaffected.

**Do not re-derive the shim.** Patching python-engineio to accept `EIO=3` was tried on hardware
and reverted; it moves the handshake to a successful `101` and then stalls one layer up, where
Socket.IO v5 meets the device's v2. The header of `pkgs/supernote/default.nix` records it.

**If you see something other than the 400 loop** — an established connection, or
`sign verification failed` — that is genuinely new. Capture the log line and the handshake query
string (redact the `token=`, it is a live JWT) and add it to #145.

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

- [x] DB backed up (`/var/lib/supernote/backups/pre-restamp-deploy.db`); JWT prefix NOT captured
  before the deploy — blocked by the secret classifier, so the before/after comparison was
  never available. Benign in the event: the device's `login/new` returned 200 throughout.
- [x] Deployed; server on `supernote-0.17.0`; bootstrap took the idempotent path (`account     present, login OK`)
- [x] 1. Sync completes with no banner — `synchronous/start` → `list_folder` → `synchronous/end`,
  all 200, repeated across several syncs
- [x] 2. Outbox document reaches the device and mirrors down — md5 `a5846e0e…` identical at
  source, store mirror and `/sdcard/Document/ereader/` (needed two syncs; see step 2)
- [x] 3. Device-side delete propagates and stays deleted — `deleted=1`, then
  `sent=0 downloaded=0 deleted=0`; gone from the mirror and the device, no resurrection
- [x] 4. Annotated note syncs back — two `.note` blobs in the store plus server-rendered page
  thumbnails, so the content parsed, not merely uploaded
- [ ] 5. Realtime channel: 400 loop observed and recorded (known broken, #145 — not a pass gate)
- [~] 6. Planner/summary — **deferred to #146**, with one substantive finding banked: creating a
  task on the device is silently destroyed on sync (`POST /schedule/task` → 200, nothing
  written, device then deletes its own copy). Recorded against #137. Note this one step
  was exercised against upstream **0.21.0 + the realtime fix branch**, not the pinned
  0.17.0 that steps 1–4 ran on.

When 1–4 pass (5 is a recording step, not a gate), #112's final criterion is met. Note the date and the device firmware version here:

> Accepted on: **2026-08-18** — firmware **Chauvet.E103.2606141001.2389_release** (Android 11,
> Supernote Nomad A6 X2) — by **the maintainer**, with an agent driving the server side.
>
> Steps 1–4 passed against the pinned upstream build (`supernote-0.17.0`, rev `5f55872`).
> Step 5 is a recording step and was recorded (#145). Step 6 is deferred to #146 and its
> partial evidence came from a *different* build — 0.21.0 plus the local
> `fix/engineio-v3-device-support` branch. The pass therefore spans two builds; that is
> stated rather than smoothed over.
