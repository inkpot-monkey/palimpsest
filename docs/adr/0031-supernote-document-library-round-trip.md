# A self-hosted document library round-trips to the Supernote — books out by OPDS pull, handwriting back by Private Cloud Sync — indexed by Stump

A self-hosted, annotated **document library** — books *and* the user's own
PDFs/papers/notes — that a **Supernote Nomad (A6 X2)** can read on e-ink and write
handwriting back into, with a **web browse + in-browser reading UI**, was the goal.
The hard constraint that shaped everything: transport is **self-hosted only** —
Supernote Cloud, Dropbox, and Google Drive are all banned — and the device is a
locked-down Android tablet that — *on the firmware the spike ran* — **could not run a
Tailscale client**, so tailnet reachability had to come from the network, not the device.
(That constraint shaped everything below and is kept here as the reason the design looks the
way it does. It was **falsified on 2026-08-17** once Ratta shipped sideloading — see the first
revision.) Handwritten annotations
must come back as the **raw `.note`/`.mark` preserved *and* converted** to a viewable
artifact (not flattened-only, not OCR). The round-trip is **bidirectional** — push
books out *and* pull annotations back.

Three surveys (self-hosted transports, `.note` conversion tooling, catalog
platforms) plus a **real spike on the actual device** (Nomad `SN078D10010247`,
firmware Chauvet **3.29.42**) settled the architecture. The spike is what forced the
final shape: the off-the-shelf `allenporter/supernote` Private Cloud server proved
annotations-BACK automatically but **could not push books OUT** (it is a
receiver/processor, and its socket.io realtime channel 500s), so the first design
fell back to a manual native-WebDAV leg. That was then superseded once a **fork**
fixed both blockers, restoring the original dream of a fully-automatic two-way sync
at the cost of two reconcilers bridging the fork's blob store to Stump.

That shape is **no longer the decision**. Everything from "## Decision" down, and the two
revisions dated 2026-07-24 and 2026-07-25, describe it as it stood and are kept as the record of
how the design got here — read them as history. The 2026-08-13, 2026-08-16, 2026-08-17 and the
six 2026-08-18 revisions below govern: the transport is pinned to a fork rev carrying the device
realtime channel, books are no longer pushed at all, `library/supernote/` is a strictly derived
mirror of the whole device, the device authenticates with Basic
auth rather than an API key, and the device runs a Tailscale client of its own. Where the older text and the newer
text disagree, the newer text wins — including between the dated revisions themselves, which are
ordered newest first.

## Revision — 2026-08-18: the store stays un-backed-up, but the REASON changes — the mirror carries it, not an offsite backup (palimpsest#148)

palimpsest#148 asked whether the server store deserves a backup, having found it a single copy
whose only two snapshots predate the 0.21.0 migration. Triaged by measuring rk1b rather than
re-reading the config. **The decision does not change: no kelpy replica, no offsite backup, and the
build assertion that keeps restic off the store stays.** What changes is the justification, which
was false in a load-bearing way.

**The old reason was that the store is "a strict subset of the offsite-backed `library/`".** Half
of that is not true. `library/` is *intended* to be offsite-backed — ADR-0031 asks for it and the
2026-08-13 text below repeats it — but no restic path lists it, `backup.enable = false` on every
host that sets it, and rk1b runs no restic unit at all (palimpsest#147). The store was being left
un-backed-up on the strength of a backup that does not run. The header of `hosts/rk1/library.nix`
asserted the backup as fact and now marks it as intent; the `group = "backup"` line in the same
file is a git-annex repository group, not a backup, and now says so.

**The new reason is the mirror, which does run.** Since the palimpsest#117 revision below widened
it to the whole device, every live file in the store is materialised into `library/supernote/` on
the NVMe and git-annex-replicated to kelpy. That is what makes the store rebuildable, and it is
different physical media from the store, which shares rk1b's eMMC with the rest of `/persistent`.

- **This corrects the governing text above.** The palimpsest#117 revision's
  recovery note says the handwriting "is backed up"; it is *replicated*, not backed up. Read every
  "offsite-backed `library/`" in this ADR — including in the historical Decision body — as
  "intended to be offsite-backed, pending palimpsest#150".

- **What is genuinely store-only is the database**, not documents: the account, the device pairing
  and the recycle bin. Losing the eMMC therefore costs a re-pair of the Nomad, which is already the
  documented recovery, and not content. That is why a periodic `sqlite3 .backup` was declined —
  it would protect a re-pair, at the price of a package, a timer and a monitored unit.

- **`NIXOS_SD` is a label, not a removable card.** palimpsest#148 framed the risk as "the SD card";
  the media is soldered eMMC (`hosts/rk1/common.nix`). The risk is real but smaller than filed.

- **The two existing snapshots keep their one job.** Both predate `d1e2f3a4b5c6`, so they remain
  exactly what a revert *below* 0.21.0 needs — the restore-from-backup path the palimpsest#112
  revision below describes. They are schema artefacts, not state backups, and nothing here changes
  that. Note `sqlite3` is not installed on rk1b, so taking a fresh one means the runbook's `cp -a`
  fallback.

## Revision — 2026-08-18: the transport is pinned to the fork rev that carries the device realtime channel (palimpsest#145)

The 2026-08-13 revision made the transport a **pin on upstream at a revision** rather than a
maintained branch, and the palimpsest#145 revision below reaffirmed it in terms: *"The decision
does not change. The fork stays retired and the pin on upstream stands."* The input now moves back
to `inkpot-monkey/supernote`, at `rev=79d1003d6dabd191e00f83fe96ee6a3262cbf5b8`.

**This does not re-adopt a vendored fork, and it does not overturn the 2026-08-13 reasoning.**
That revision retired the fork because its price — "a maintained fork to carry" — stopped buying
anything once upstream implemented the planner surface itself. That price is not being paid again.
The pinned rev **is** upstream 0.21.0 plus four commits, all of them the device channel and the
removal of the phantom `allow_eio3`; fork `main` is byte-identical to `upstream/main` and
deliberately stays so; and the input is a **rev**, not a branch, so it cannot drift under an
unattended update. The exit condition is explicit: when upstream merges the channel, the input
returns to `github:allenporter/supernote` and the 2026-08-13 position is restored unedited.

**What changes in the palimpsest#145 revision is the reach of one claim, not its truth.** "The
channel carries **nothing**" remains correct about its *payload* — `send_message()` is still
unreachable dead code, nothing pushes to the device, and the channel is connect-and-keepalive
only. But that claim was supporting a conclusion it cannot bear: that the pin therefore need not
move. The device requires the channel to **exist and connect**, independently of whether anything
is ever sent over it, and a server that refuses `EIO=3` at version negotiation cannot give it
that. Established on hardware on 2026-08-18: with this rev deployed to rk1b, a Nomad A6 X2
completes its app-data sync and reports "App Data Sync Completed" with no failure banners.

The device's own traffic was captured for the first time in the same session, which settles two
things that had been inferred from the spec. The device reopens its channel on a 30/60/120/240s
ladder and **that is normal** — each rung ends with the device sending `41` (Socket.IO DISCONNECT)
and closing with code 1000, a deliberate hang-up, then immediately opening a fresh channel for its
next sync, with the full REST cascade following every reconnect. The same ladder is present in the
archived known-good traces from before upstream was adopted, so it is not a symptom. And
`42["ratta_ping"]` is **not** liveness: the device emits one alongside every Engine.IO ping and
held a channel open across nine consecutive unanswered ones.

**Two operational consequences.** First, rk1b's database was migrated to `d1e2f3a4b5c6` by a 0.21.0
build on 2026-08-18 and is now **ahead of the retired 0.17.0 pin**, so reverting the transport
*below* 0.21.0 needs a database restore rather than a redeploy. This pin move is also what returns
the host to a state reproducible from the flake, which it was not while running on
`--override-input`. Second, `~/code/nixos` **main**'s supernote input still names the deleted
branch `fix/device-schedule-group-all`; it evaluates only because it is locked to `3d08092`, and
`nix flake update supernote` on main cannot resolve the ref. Merging this branch **replaces** that
input rather than repairing it, so the hazard disappears for the wrong reason — recorded here so a
later reader does not conclude main was sound all along.

## Revision — 2026-08-18: the mirror covers the whole device, is strictly derived, and needs no state (palimpsest#117)

The 2026-08-13 revision decided that the outbox, the last-synced baseline and the store-loss guard
all go, and parenthesised the one thing that had to survive them: *"an empty or unreachable store
must never cause deletions in the backed-up tree."* Building it (palimpsest#117) settled how, and
the how has consequences worth recording rather than leaving to the code.

**Decision: `library/supernote/` mirrors the WHOLE device, is strictly derived from the store, and
keeps no state at all.**

- **Scope is the whole device, not a chosen folder — and the narrow version mirrored nothing.**
  The mirror was scoped to `/DOCUMENT/Document/ereader`, inherited from the retired push. Measured
  on rk1b: the device held **two `.note` notebooks and the mirror held zero**, because neither
  lives in that folder. (The store's blob directory held six files at the time, which is what was
  counted first and reported as six; four were orphans — two `.epub` from the retired outbox era, a
  `.pdf` from the acceptance runbook, and a superseded revision of a note, since editing one writes
  a new blob and orphans the old. Blobs on disk are not live entries, and the store never prunes
  them.) That folder existed only because the
  outbox created it; books now arrive by OPDS into a folder Private Cloud never syncs, and the
  handwriting this server is *kept for* lives in `NOTE/Note` and `DOCUMENT/Document`. The narrowing
  decided above — "the Private Cloud server stays, narrowed to the handwriting round-trip" — was
  implemented pointing at the one place handwriting is not. Listing from the **VFS root** covers
  every folder the firmware seeds (Note, Document, MyStyle, Export, Inbox, Screenshot) at the
  device's own relative paths, and needs no folder list to keep in step with the firmware.

- **Deletes need no baseline, because local adds no longer exist.** The baseline's only job was
  telling a fresh local add from a device-side delete. With no upload path the mirror contains
  exactly what the reconciler put there, so absence from the store is unambiguous. The cost is
  that the mirror is now strictly derived: a file dropped into `library/supernote/` by hand is
  **deleted on the next sync**, not adopted. That is the honest reading of "downward mirror", and
  it is why the folder is no longer described as somewhere to put things.

- **One guard, no state: an empty store deletes nothing.** *Unreachable* is free — login happens
  before any library mutation, so a store that is not answering fails the unit having touched
  nothing. *Lost* is an empty listing: if the store lists no files **at all** while the mirror
  holds some, deletes are skipped wholesale.

  **The scope decision is what makes that rule correct, and the wrong turn is worth recording.**
  While the mirror was folder-scoped, this rule was untenable: the device deleting its **last**
  document in that one folder left a live store with an empty listing, so the guard swallowed
  exactly the delete the mirror exists to propagate — permanently, since nothing afterwards
  distinguishes it from a wipe. The VM check caught it. The fix at the time was to key on the
  *folder's absence* instead, which worked but was a workaround for the wrong scope, and it needed
  a fact about upstream's internals to hold up (`delete_item` → `vfs.delete_node` never prunes
  parents, so an emptied folder survives).

  At whole-device scope the workaround is unnecessary and the plain reading is right: an empty
  listing means the device's **entire** virtual filesystem is empty, which is store loss, not
  housekeeping. Deleting one document among others leaves a non-empty store and propagates
  immediately. The two acceptance criteria that conflicted — "a device-side delete propagates" and
  "an empty store deletes nothing" — are both satisfied literally, and the conflict is revealed as
  an artefact of the narrow scope rather than a genuine tension.

  It also removes code rather than adding it: the root cannot 404 (`list_folder` falls back to the
  root directory id when the path strips to nothing), so the missing-folder branch, the
  `folder_exists` flag and the `NotFoundException` handling all go, along with the remote-path
  option. The reconciler ends **smaller than the version that did less**.

- **Known and accepted: a PARTIALLY re-seeded store is not guarded.** The rule above fires only on
  a completely empty listing. While a wiped store is being re-seeded by the device, the listing is
  non-empty, so anything not yet re-uploaded is absent — and is therefore deleted from the mirror in
  that run. It self-corrects once the device finishes (the mirror re-downloads), and nothing is
  truly lost, because the tree is a git-annex repository with full history and a kelpy replica and
  nothing in the module runs `dropunused`. A stateless ratio guard — refuse a run that would delete
  most of the tree — was considered and **declined**: it buys protection against a rare, recoverable
  case at the cost of tripping on a legitimate bulk delete and needing manual intervention on the
  one path that is supposed to be automatic. Recorded rather than fixed, so the next person meets a
  decision instead of a hole.

- **The store's sandbox now agrees with the architecture.** The baseline was persisted *inside*
  the server store, which is why the reconcile unit carried a `StateDirectory`. Removing it makes
  "the store is reached only over the client API, never its filesystem" a property of the sandbox
  rather than a claim about the code.

- **Recovery loses a leg, knowingly.** The store's recovery note used to end "device gone → re-send
  the books from `library/ereader/` via the one-shot outbox". There is no such path now. The
  handwriting is not lost — `library/supernote/` holds it and is backed up — but it stays in the
  library rather than returning to a replacement device. Books are unaffected: a new device pulls
  them from the catalog.

- **The retired paths are swept, not just abandoned.** `library/ereader-outbox/` and the old
  `library/ereader/` both sat inside the git-annex tree, so an orphan would have replicated to
  kelpy and been carried offsite forever; the baseline sat in persisted server state. The deploy
  deletes all three and logs what it removed. Renaming the mirror root cost no migration precisely
  because the old one was empty — there was never anything in it.

## Revision — 2026-08-18: the `supernote-db-stamp` startup guard is removed (palimpsest#112)

The `supernote-db-stamp` ExecStartPre guard, added after the 2026-08-17 rk1b outage, is being
removed (see the commit that deletes it). Recorded here because deleting the script deletes the
only written record of why it existed.

It existed to translate a single alembic stamp: a database created by the vendored fork carries
`9d2f7b3c1a08`, a revision upstream has never heard of, and upstream's alembic aborts at startup
rather than warning — which, because `supernote-account-bootstrap` has `Requires=` on the server
with no start timeout, turned into a deploy that **hung rather than failed**, and cost 35 minutes
of downtime. The translation was safe because fork and upstream had converged on the same schema
by independent routes: upstream implemented the device planner surface itself rather than
cherry-picking the fork, and on the real rk1b database all thirteen of upstream's tables and all
nine columns of its head migration were already present.

**Decision: the guard is removed.** That translation has happened and cannot be needed again —
rk1b is the only host running the profile, its database was translated on 2026-08-17, and the fork
is retired, so no new fork-stamped database can be created. What remained was a hand-maintained
duplicate of the pinned build's alembic history sitting in the startup path.

- **Its defect is not that it failed loudly — it is that a legitimate pin move and a corrupt
  database were indistinguishable to it.** On 2026-08-18 a 0.21.0 build migrated the database to
  `d1e2f3a4b5c6`, a revision the hardcoded allowlist did not know, and the unit refused every
  subsequent start. That is the guard working exactly as designed; the problem is that the design
  had no way to fail *quietly and correctly* when the pin moved on purpose. Loud failure was the
  best available outcome of the shape, not evidence the shape was right.

- **And what it guarded against is something alembic already refuses by itself.** An unknown
  revision aborts startup with or without the guard. The script was therefore carrying the
  staleness risk — a second copy of the migration history, maintained by hand — without adding
  protection over the behaviour underneath it.

**Consequence — a pin revert now needs a database restore.** rk1b's database is at
`d1e2f3a4b5c6`, ahead of the 0.17.0 fleet pin. Starting 0.17.0 against it aborts inside alembic
with "Can't locate revision", so reverting the pin is a restore-from-backup operation rather than a
redeploy. Until the pin moves forward, `just deploy rk1b` is not a safe rollback — including for
anyone who reaches for it for reasons unrelated to this server.

## Revision — 2026-08-18: the pen assumption, measured — the digitiser is fully available to sideloaded apps (palimpsest#115)

The 2026-08-13 revision below justified keeping the Private Cloud server on this reasoning:

> A sideloaded reader gets ordinary Android stylus input, **not the Supernote pen layer**, and
> there is no path off the device for `.note`/`.mark` except Private Cloud sync.

It was flagged there as "reasoned rather than measured", with palimpsest#115 to settle it
hands-on. It has now been measured on the device, and **the conclusion stands while the reason
needs correcting**.

**The pen is not degraded outside the stock apps — it is fully exposed.** It is a dedicated
Wacom EMR digitiser on its own input device (`/dev/input/event7 "Wacom-pen"`), separate from the
two touchscreens, advertising `ABS_PRESSURE` 0–4095 (the touchscreens manage 0–255), `ABS_TILT_X/Y`
±9000, both barrel buttons, and the eraser end. Android classifies it `Sources: 0x5002` =
`SOURCE_STYLUS | SOURCE_TOUCHSCREEN`, so a sideloaded app receives full `TOOL_TYPE_STYLUS`
MotionEvents. Nothing is withheld.

Observed in KOReader, the pen behaves **exactly** like a finger — but that is KOReader's doing,
not the platform's. It is a reader with no ink surface, so it consumes position and ignores the
stylus axes (`["highlights"] = 0` in its `.sdr` sidecars).

- **The decision does not change.** Handwriting still stays with the stock Note and Document
  apps, and the Private Cloud server is still kept for the handwriting round-trip. But the
  binding constraint is a **format and engine** boundary — only the stock apps write
  `.note`/`.mark`, and only they run Ratta's handwriting engine — **not** an input-availability
  one. The original phrasing implied the digitiser was out of reach for sideloaded apps. It
  is not.

- **What this opens.** A future sideloaded app could offer genuine pressure- and tilt-sensitive
  ink; what it could never do is produce a Supernote-native notebook that the stock apps and
  Private Cloud sync understand. Do not rule out a sideloaded pen feature on the belief that the
  pen is unavailable — that belief is now falsified. The device-side detail is recorded in
  `docs/runbooks/supernote-koreader-opds.md` §6.

- **Second confirmation of the same lesson.** This is the second assumption in the 2026-08-13
  revision that a single hour with the device corrected, the other being the realtime channel
  (see the revision below). Both were reasoned from source and both were wrong in ways no VM
  check could surface. Where a device observation is available, prefer it.

## Revision — 2026-08-18: upstream's realtime channel was never a superset — the fork's `realtime.py` was load-bearing (palimpsest#145)

The 2026-08-13 revision below retired the vendored fork partly on the claim that **"the realtime
channel is upstream and better"** — that upstream's `server/socket.py`, passing `allow_eio3=True`
to the real `python-socketio`, was a superset of the fork's hand-rolled
`server/realtime.py`. **That claim is false**, and the palimpsest#112 hardware acceptance pass is
what falsified it. It is the one bullet in that revision that was never measured.

`allow_eio3` is an option of the **JavaScript** socket.io server. It does not exist in
`python-socketio` or `python-engineio` at any version — `grep -r` over the full source trees of
python-socketio v5.0.0/v5.11.0/v5.16.3 and python-engineio v3.14.1/v4.0.0/v4.13.3 returns zero
matches, docs included. Both libraries end `__init__` in `**kwargs`, so the argument is forwarded
socketio → engineio and **silently discarded**. Upstream therefore has no Engine.IO v3 support and
never has had, at any pin. The Nomad connects with `EIO=3` and is refused at version negotiation,
before its signature is ever checked:

```
GET /socket.io/?…&EIO=3&transport=websocket&… HTTP/1.1" 400
"The client is using an unsupported version of the Socket.IO or Engine.IO protocols"
```

Note what this means for the opening section's spike finding, "its socket.io realtime channel
500s" (upstream v0.16.0). **That channel has never worked with this device.** The fork fixed it;
#112 retired the fix on the belief that upstream had. The bullet's own first sentence — "the fork
hand-rolled Engine.IO v3 precisely because modern `python-socketio` rejects `EIO=3`" — was
correct, and then concluded that a keyword argument answered it.

- **The decision does not change.** The fork stays retired and the pin on upstream stands. What
  is lost is a channel that carries **nothing**: upstream's `send_message()` — the only method
  that emits a payload to a user room — has no callers anywhere in the server, and
  `server/app.py:398` discards `setup_socketio()`'s return value, so the push path is unreachable
  dead code. Connected, the channel only answers a `STATUS` heartbeat, echoes `ratta_ping`, and
  logs ACKs. The books-out and handwriting-back legs are plain REST and are unaffected — both
  were proven green on hardware in the same session.

- **Do not re-derive the shim.** Patching python-engineio to accept `EIO=3` (and to answer a
  client-sent `PING`, since v3 reverses the heartbeat) was built and tested on the real device:
  it moves the handshake from 400 to a successful **101** upgrade and then stalls one layer up,
  where `python-socketio` 5.x's Socket.IO v5 meets the device's Socket.IO v2 and the CONNECT
  packet is never parsed. Full device support needs the socketio 4.x + engineio 3.x pairing —
  two EOL majors — or a hand-rolled implementation, which is the fork all over again. Reverted;
  recorded in the header of `pkgs/supernote/default.nix`.

- **The methodological lesson, which is the durable part.** The 2026-08-13 revision states that
  what changed upstream was "established by **reading both trees** rather than by diffing
  patches". Reading is how this error was produced: upstream *appears* to configure v3 support,
  and nothing at import, startup, or in either VM check contradicts it. Every remaining
  fork-capability disposition in that revision — palimpsest#136–#140, #142 — rests on the same
  method and none has been exercised against the device. They are plausible; they are not
  measured. **Prefer a device observation to a source reading wherever one is available.**

## Revision — 2026-08-17: the device *can* run a Tailscale client (retires the framing constraint above)

The opening paragraph's hard constraint — a locked-down tablet that **cannot run a Tailscale
client**, so "tailnet reachability has to come from the network, not the device" — is false, and
was measured false on the actual Nomad (`SN078D10010247`, Chauvet `E103.2606141001.2389`,
Android 11, arm64-v8a). It was true of the firmware the original spike ran on; Ratta has since
added app sideloading, and nobody re-tested the premise afterwards.

**Decision: the device is a first-class tailnet node. Designs downstream of this ADR may assume
the Nomad reaches tailnet services directly.** The node is `supernote-nomad`.

- **Chauvet's AOSP VPN stack is intact, not stripped.** `/dev/tun` (char 10,200, `system:vpn`),
  `com.android.vpndialogs` installed and enabled, `BIND_VPN_SERVICE` / `CONTROL_VPN` /
  `CONTROL_ALWAYS_ON_VPN` all defined, and `Settings$VpnSettingsActivity` resolves. Ratta removed
  the launcher and the store, not the networking. Tailscale 1.102.2 (the **universal** APK from
  `pkgs.tailscale.com` — the device has no Play services) installs and authenticates; the login
  redirect survives despite no Custom Tabs service being registered, which was the predicted
  failure and did not occur.

- **Verified from the device, not inferred:** ping to rk1b 0% loss ~20 ms; TCP to Stump's OPDS
  port **10001** open; MagicDNS resolves `library.<domain>` to the kelpy edge. The delivery path
  the revision below designed is reachable from the Nomad end to end.

- **Sideloading is what unlocked this, and it is the same switch that exposes ADB.**
  Settings → Security & Privacy → Sideloading. With it off the device enumerates USB as `mtp`
  with only MTP and HID interfaces, so `adb` sees nothing — worth knowing before diagnosing a
  cable.

- **Two operational conditions, or it regresses silently.** The package must be held out of doze
  (`dumpsys deviceidle whitelist +com.tailscale.ipn`, persisted) or the tunnel comes up and then
  drops on sleep, which presents as an intermittent catalog rather than a VPN fault. Always-on
  VPN is deliberately **off**: arming it with lockdown before the tunnel is trusted can leave the
  device with no network at all, recoverable only over ADB.

- **What this does *not* change.** The architecture is unaffected — OPDS pull over the tailnet
  edge is what `parts/settings.nix` already assumed (its `library` entry describes the Supernote
  as a tailnet OPDS client), so this removes a contradiction rather than introducing a change.
  Private Cloud sync still targets rk1b over the home LAN, and an Android Tailscale client does
  not capture LAN routes, so that leg is untouched. `VpnService` is system-wide, so routing the
  native sync over the tailnet is now *possible* — it is explicitly **not adopted here**, and
  would need its own decision.

- **What it retires.** The away-from-home note under "Consequences" — reach beyond the house
  needing a GL.iNet travel router running Tailscale — is obsolete; the device carries its own
  client now.

- **Adjacent, still open:** this proves the *device* can hold a tailnet address, not that its
  reader speaks Basic auth. KOReader v2026.07.1 is installed and configured against the catalog
  with a username/password, which is supporting evidence, but palimpsest#115 is settled by a
  successful authenticated fetch, not by the presence of the fields.

## Revision — 2026-08-16: the device authenticates with Basic auth, not an API key (supersedes the API-key URL)

The revision below chose the **API-key-in-URL** route on the reasoning that a constrained reader
cannot send an `Authorization` header. The route exists and that reasoning still holds for clients
that genuinely cannot — but it was never checked whether Stump offers anything else, and it does:
**HTTP Basic auth, accepted on OPDS 1.2 and nowhere else**
(`apps/server/src/middleware/auth.rs` gates the `Basic ` branch on `is_opds`). OPDS 1.2 is the
version this design already targets, and the server answers an unauthenticated OPDS request with
`WWW-Authenticate: Basic realm="stump OPDS v1.2"` — the challenge that tells a reader app to
prompt.

**Decision: the device authenticates as the dedicated non-owner account over Basic auth at
`https://library.<domain>/opds/v1.2/catalog`. The API-key URL is retired.** The diagram in the
revision below is otherwise unchanged; only the credential on the BOOKS OUT arrow differs:

```
  BOOKS OUT    DEVICE (sideloaded reader) ──OPDS 1.2 pull, Basic auth──▶ STUMP ──indexes──▶ library/
```

- **Because the API key cannot be declared.** Keys are generated server-side
  (`create_prefixed_key` → `generate_key_and_hash`) and `ApikeyInput` has no field to supply one,
  so the value can only be learned *after* the first deploy and hand-carried into sops. That makes
  every fresh database a two-phase deploy with a manual step in the middle. Basic auth needs no
  round trip: both halves of the credential — username as a module option, password as a sops
  secret — are determined before the server starts. This supersedes the sentence below that the
  **API-key URL** "belongs in the secret store": there is no such URL. The rule it expresses is
  unchanged and still honoured — the credential lives in sops (`stump/opds_password`), and the
  URL, now carrying nothing secret, does not.

- **The scope gets tighter, not looser.** The account previously needed `ACCESS_API_KEYS` purely so
  it could hold a key; with no key that permission authorises nothing, so the account is
  `DOWNLOAD_FILE` alone — the only permission any OPDS 1.2 route enforces. The non-owner
  requirement is untouched and is still the load-bearing part: `enforce_permissions`
  short-circuits on `is_server_owner`, so an owner credential cannot be scoped at all.

- **A password is safe here in a way a bearer token would not be.** Because Basic auth is confined
  to the OPDS routes, the credential typed into a reader app cannot be replayed against the
  GraphQL API. The acceptance test asserts that confinement rather than trusting it.

- **This rests on the device's reader supporting Basic auth**, which is reasoned rather than
  measured — the same standing as the pen-layer assumption below, and it is palimpsest#115 that
  settles it. If the reader cannot, the API-key path was implemented and tested before this
  revision retired it — recover it with
  `git log --all --grep='bank the OPDS key'` (`d5a3499` at the time of writing, but a rebase
  will move it; the subject is the durable handle). Tracked as palimpsest#114.

## Revision — 2026-08-13: the device pulls books over OPDS; Private Cloud narrows to handwriting (supersedes the push, and the fork)

The revision below fixed the delete tug-of-war by flipping the mirror's direction. It did not
question the premise underneath both it and the amendment before it: that **the server has to
put books on the device**. A device capability re-reads the whole problem. The Nomad supports
**sideloading** — an official feature (*Settings → Security and Privacy → Sideloading*), not a
jailbreak — so it can run a real **OPDS client**. Stump already speaks **OPDS 1.2** and ships a
second catalog route that takes an **API key in the URL path**, provided precisely for clients
that cannot send credentials in headers, which is exactly the situation a constrained e-ink
reader is in. Delivery can therefore be **device-initiated pull**, and the conflict dissolves at
its root rather than being managed:

```
  BOOKS OUT    DEVICE (sideloaded KOReader) ──OPDS 1.2 pull, API-key URL──▶ STUMP ──indexes──▶ library/
               reading position  ◀────────── KOReader sync (Stump's own) ─────────────────────▶ Stump DB

  HANDWRITING  DEVICE (stock Note/Document apps) ◀─Private Cloud sync (2-way)─▶ STORE ──mirror down──▶ library/
               .note / .mark — the only path that can carry the pen layer
```

Nothing continuously re-applies a mirror *into* a store that a 2-way sync also writes, because
nothing is injected into the store at all. **Decision: books are delivered by pull; the Private
Cloud server is kept only for the handwriting round-trip.**

- **Books out becomes an OPDS pull, and the push mechanisms go.** Superseded outright: the
  **enforced outbound push** of the 2026-07-24 amendment (palimpsest#94) and the **one-shot
  outbox send** of the 2026-07-25 revision (`library/ereader-outbox/`). With them go the two
  pieces of state that only existed to serve them — the **last-synced baseline** and the
  **store-loss guard** — because the baseline's whole job was telling a fresh local add from a
  device-side delete, and with no server-side injection an absence from the store is
  unambiguous. (The guard's *rule* stands on its own: an empty or unreachable store must never
  cause deletions in the backed-up tree — see the 2026-08-18 revision above for how #117
  re-expressed it without state.) Tracked as palimpsest#114 (serve), #115 (device),
  #117 (reduce the sync).

- **What pull does *not* deliver — and why the Private Cloud server survives.** Native
  handwriting is produced only by the device's **stock Note and Document apps**: `.note`
  notebooks and the `.mark` sidecars written over a PDF. A sideloaded reader gets ordinary
  Android stylus input, **not the Supernote pen layer**, and there is no path off the device for
  `.note`/`.mark` except Private Cloud sync. So **annotations-back and notebooks cannot ride the
  OPDS path** and are not being asked to. The Private Cloud server stays — **narrowed** to the
  handwriting round-trip and the downward materialisation of the store into `library/` — and the
  reading/delivery path moves to Stump + OPDS. This split rests on the pen assumption, which is
  reasoned rather than measured; palimpsest#115 verifies it hands-on and records the finding
  either way.

- **The vendored fork is retired.** `inkpot-monkey/supernote` exists for the device
  schedule/planner sync routes upstream lacked; upstream has since implemented that surface
  itself (independently, not cherry-picked). The transport becomes a **pin on upstream at a
  revision** rather than a maintained branch, which retires the "a maintained fork to carry"
  consequence below. Verify-then-pin, not a blind input swap — the branch is 13 commits ahead but
  151 behind, and upstream has restructured. Tracked as palimpsest#112.

**Consequence — the user stories split across two paths.** Of #87: OPDS pull satisfies
**books-out** (1, 2, 16 — folder structure survives as catalog series), **browse + read** (8, 9)
and the self-hosted-transport constraint (10); Private Cloud keeps **annotations-back** (3, 4)
and **notebooks** (5, 6). Story 12 — "fully automatic in both directions, never touch the
device" — is **knowingly weakened for books**: fetching one is now a deliberate act on the
device. That is the trade. A push that cannot distinguish "the user deleted this" from "the
device is missing this" was buying automation with resurrection; a pull buys correctness with one
tap.

**Consequence — reading progress now round-trips.** "Reading-progress / position sync (no device
API)" is listed under *Out of scope for v1* below; the OPDS path retires that line. Stump ships
its own implementation of **KOReader's sync protocol**, so position syncs with no bridging code —
matched by **content hash only** (the libraries must generate KOReader-compatible hashes and be
rescanned), with the sync routes **off by default**. The original architecture had no answer here
because it was reasoning about the *device*; the answer arrives with the *reader*. Tracked as
palimpsest#116.

**Consequence — Stump moves onto the critical path, and the device gains hand-configured state.**
The catalog was a browse/read convenience; it is now how books reach the device, so its
availability is a delivery dependency. The API-key URL is a **credential** — it grants library
access to whoever holds it — and belongs in the secret store, not in a config file in git. And
the sideloaded reader is device-side state this repo cannot declare: it must be written up as a
repeatable procedure to survive a device reset or replacement (palimpsest#115).

## Revision — 2026-08-13: the transport is upstream again; the vendored fork is retired (palimpsest#112)

The decision below adopted `inkpot-monkey/supernote` — a fork of `allenporter/supernote` — because
upstream lacked the device planner/realtime surface, and it accepted "a maintained fork to carry"
as the price. **That price no longer buys anything: upstream has implemented the surface itself.**
The transport input is now `github:allenporter/supernote` pinned at an explicit revision, and the
fork branch is no longer an input.

What changed upstream, established by reading both trees rather than by diffing patches (the two
implementations are independent, so a patch comparison shows no overlap):

- **The realtime channel is upstream and better.** ⚠️ **THIS BULLET IS FALSE — see the
  2026-08-18 revision above (palimpsest#145).** It is kept unedited because it is the claim that
  authorised retiring `server/realtime.py`, and the failure is more instructive than a silent
  correction. It read: the fork hand-rolled Engine.IO v3 in `server/realtime.py` precisely
  because modern `python-socketio` rejects `EIO=3`; upstream now serves socket.io with the real
  library and `allow_eio3=True` (`server/socket.py`), and adds what the fork's connect-only
  prototype never had: handshake **signature** verification, `ratta_ping`, and server→client
  push — a superset, not a substitute.
- **The device schedule routes are upstream** (`schedule/group/all`, `schedule/task/all`,
  `task/list`) — and the flatten-aware path resolution the fork added to the VFS is there too, with
  the *opposite* precedence (upstream prefers a real root folder over the category container, so it
  does not self-heal a rogue root folder left by the old bug; ours has none).
- **Six gaps remain**, filed rather than re-vendored: palimpsest#136 (`delete/summary` is
  POST-only, the device sends `DELETE`), #137 (planner writes are insert-only and numeric-id-only,
  and cannot represent an ungrouped task), #138 (planner deletes are hard deletes, so off-device
  deletes resurrect), #139 (`PUT task/list` is update-only and drops `isDeleted`), #140 (the
  device upload response echoes the requested path, and the precedence above does not self-heal),
  and **#142 (concurrent logins for one account race a single-slot login challenge and the loser
  gets a misleading 401 "Invalid credentials")**.
- **#142 is the one that reaches us.** The first five are on the device's own sync or dormant;
  #142 is on the *reconciler's* path and turned the mirror check (then `supernote_ereader`, now `supernote_mirror`) red. It matters
  because this ADR deliberately gives the device and the reconciler **one shared account**, and
  fires the reconciler *from* the device's sync — so the two authenticating clients are aimed at
  the same account at the same moment by construction. The reconciler now retries a 401, and the
  check's driver caches its token rather than re-authenticating on every poll.

Consequences that supersede the "a maintained fork to carry" consequence below:

- **No fork to rebase.** The cost moves from carrying a branch to carrying six upstream issues,
  which is the cheaper and more honest position — and it is what makes future upstream fixes free.
- **The input is pinned to a bare rev, not a branch.** This is the device sync endpoint, and a rev
  bump can alembic-migrate the live store, so moving it must be a deliberate reviewed edit
  (`sqlite3 .backup` first). An unattended `nix flake update` cannot move it.
- **The dependency set grew.** Upstream needs `python-socketio` and `ical`; both are in nixpkgs. It
  also needs `mcp>=2.0.0`, which the fleet nixpkgs pin does not have — so `pkgs/supernote/mcp2.nix`
  builds the MCP 2.x wheel chain locally, to be deleted when nixpkgs catches up. Pinning upstream
  *before* the mcp bump is not an option: the device routes landed five minutes after it.
- **Reading upstream was not enough to find every gap.** Five gaps came from comparing the two
  trees; #142 came from a red CI check, and no amount of reading would have surfaced it — it is a
  *concurrency* property, invisible in any single code path. That is the honest lesson of this
  cutover: a behavioural equivalence review catches missing behaviour, not emergent behaviour.
  Hardware acceptance (`docs/runbooks/supernote-upstream-acceptance.md`) is still outstanding and
  is the only thing that will exercise the device's own sync at all.

Nothing about the *shape* of the round-trip changes here — only the provenance of the server
binary. The shape is changed instead by the revision **above**, landed the same day: that one
retires the outbox and the enforced push in favour of an OPDS pull, and narrows this server to the
handwriting round-trip. Read the two together — this revision says *whose* server binary; that one
says *what it is still for*.

## Revision — 2026-07-25: lean into the fork's 2-way sync; `library/ereader/` mirrors the store (supersedes the outbound-only stance)

Deploying the outbound-only push (below) surfaced a design fault the amendment glossed:
**it fights the fork's own bidirectional sync instead of leaning on it.** Observed on the real
Nomad — delete a book on the device and it comes straight back. The mechanism is a tug-of-war
between two syncs over three planes:

```
  DEVICE  ◀── fork Private Cloud sync (2-way, works) ──▶  FORK STORE  ◀── ereader push (1-way, up) ──  library/ereader/
  read/delete here                                        blobs+VFS, rebuildable, NOT backed up          real files, backed up, Stump-indexable
```

The fork sync only spans **device ⟷ store**; the device delete *did* propagate to the store.
But the ereader push re-runs every sync and re-uploads anything in `library/ereader/` the device
lacks — with no memory of what it already sent and no awareness of intent, it cannot tell "user
deleted this" from "device is missing this," so `library/ereader/` (still holding the file) wins
and the delete is undone. A continuously-enforced one-way mirror *into* a store that a 2-way sync
also writes is structurally a conflict.

**Decision: flip the authority.** The device + fork store are authoritative for what is on the
device; **`library/ereader/` becomes a downward mirror of the store, not a source that pushes up.**

- **Store → `library/ereader/` (new inbound mirror).** On each device-initiated sync, reconcile
  the store's `ereader/` folder *down* into the git-annex tree: download files the tree lacks, and
  **remove files the device deleted** — so a device delete propagates device → store → `library/`
  and *stays gone*. This materialisation is also exactly what Stump (#93) needs (real files, not
  blobs), so it does double duty.
- **Sending is one-shot, not enforced.** Publishing a new book becomes a deliberate one-shot inject
  into the store (an outbox folder that uploads-once-then-clears, or a `supernote-send` command),
  replacing the continuously-re-applied push. After it lands, the fork owns its device lifecycle and
  the downward mirror reflects it back into `library/ereader/` for backup + browse.
- **The one required sliver of state: a last-synced baseline.** The delete direction hinges on one
  ambiguity — a file present in `library/` but absent from the store is *either* a fresh local add
  *or* a device-side delete. The reconciler distinguishes them by remembering the previous sync's
  store snapshot (md5 set): "was in the baseline, now gone" = a real delete → remove from `library/`;
  otherwise leave it. A **store-loss guard** (never delete from the backed-up tree when the store is
  empty/unreachable and no device sync has completed) keeps a wiped, rebuildable store from nuking the
  backup. This is the minimal state the original "no state DB" goal traded away, and it is the honest
  price of durable deletes.

**Consequence for scope:** this **un-defers the inbound half** the 2026-07-24 amendment shelved — but
narrowed to the `ereader/` round-trip (mirror-down + one-shot send + durable deletes), *not* yet the
full-corpus reconciler (`.note` → PDF conversion, `_originals/`, `library/{books,papers,notebooks}`
classification, annotations materialisation), which remains future work built on this same
store → `library/` mirror. The shipped outbound push (#94) is superseded by the one-shot send + mirror;
its sync-coupled journal trigger carries over. Tracked as **palimpsest#107**.

## Amendment — 2026-07-24: v1 ships outbound-only (palimpsest#94)

The bidirectional reconciler below is the decided *architecture*; the first shipped
increment is deliberately **narrower**. The two-way reconciler's complexity lives almost
entirely in the **inbound** half (blob-store → tree materialisation, `.note` → PDF
conversion, `_originals/` ledger, classification into `library/{books,papers,notebooks}`).
Dropping that removes ~80% of the code and risk for ~80% of the value — "put books on my
Supernote, browse in Stump, keep them backed up" — so v1 builds just the **outbound** half:

- A dedicated **`library/ereader/`** folder whose contents are pushed onto the device
  (`upload_content` to `/DOCUMENT/Document/ereader/<rel>`), md5-idempotent, never deleting or
  pulling. Same fork client, same shared credential, same never-touch-the-FS-store rule.
- The trigger is **sync-coupled, not a timer**: a unit follows the fork server's journal and
  fires the push on the device's `synchronous/start` (a device-initiated sync). The book
  appears on the device on the **next** sync (the fork's realtime channel is connect-only).

**Deferred, not cancelled:** annotations-back (device → `library/`), server-side `.note` → PDF
conversion, `_originals/`, and the timer-driven bidirectional reconciler are a future ticket
(ADR-0031 v2). The device still uploads its annotations to the raw fork store (Private Cloud
is 2-way) — they are simply not materialised into the backed-up `library/` yet. Everything
below this amendment describes that eventual full round-trip; read it as the target, with the
outbound `ereader` push as the shipped first slice.

## Decision

**Adopt the `inkpot-monkey/supernote` fork as the transport, let the device's native
Private Cloud Sync move content automatically in both directions, and bridge the
fork's blob store to a Stump catalog with a single stateless bidirectional
reconciler — all on rk1b, fronted by kelpy's Caddy, with git-annex owning the corpus
tree.**

- **Transport — the fork's native Private Cloud Sync.** `inkpot-monkey/supernote`
  (branch `fix/device-schedule-group-all`), consumed as a flake input, runs the
  Private Cloud endpoint the Nomad binds via *Settings → Sync → Private Cloud* over
  plain HTTP on the home LAN. The fork fixed the two spike blockers: **books-OUT**
  (a case-sensitive VFS rogue-root, fixed `63e8f97`, `.note`+`.pdf` proven pulling
  onto the real Nomad live) and **socket.io realtime** (productionized `realtime.py`,
  zero-banner sync). Sync is automatic both ways; no per-file long-press, no WebDAV.

- **Catalog — Stump.** `services.stump` (now upstream nixpkgs) serves the web browse
  and in-browser reader plus OPDS. **Three libraries — Books / Papers / Notebooks,
  each series-priority** — rooted at `library/{books,papers,notebooks}`, because
  Stump's library pattern is fixed at creation and immutable, and one-library-per-type
  is the only arrangement giving both type grouping and clean subject-series under
  folder-only curation.

- **The bridge — one stateless bidirectional reconciler.** The fork stores files in a
  **content-addressed UUID blob store + SQLite VFS** that Stump cannot watch, so a
  reconciler materialises a real tree Stump *can* watch and pushes new books back.
  It is **one** systemd-timer poll: a single `list_folder("/", recursive=True)`
  snapshot, then an **inbound** pass (device → `library/`) and an **outbound** pass
  (`library/` → device), sharing one fork client and one cached credential. There is
  **no state DB** — `_originals/` *is* the ledger, and the md5 `content_hash` that
  `list_folder` returns is the coordination key. Inbound classifies by device folder
  (`/NOTE/Note` → Notebooks, `/DOCUMENT/Document/{Books,Papers}` → Books/Papers),
  renders `.note` to PDF **server-side** via `get_note_pdf`, and preserves the raw
  `.note`/`.mark` in an `_originals/` sibling **outside** the Stump roots. Outbound
  mirrors `library/{books,papers}/**` (minus `*.annotated.pdf`, never `notebooks/`)
  onto the device via `upload_content`, which auto-mkdirs and upserts.

- **Corpus layout.** Annotated copies land **beside the original**
  (`x.pdf` + `x.annotated.pdf`) in the same series folder; the pristine original is
  never touched. Raw `.note`/`.mark` live in `_originals/`, a sibling of `library/`
  outside all three Stump roots — excluded by **physical placement, not ignore
  globs** (Stump's globs are DB-stored and would need re-adding after a rebuild).

- **Storage, placement, backup.** **git-annex on rk1b owns the `library/` tree**
  (`unlock` + `thin`, 1× disk), replicated to kelpy and — unlike the music library —
  **backed up offsite**, because this is personal documents, not re-acquirable media.
  Stump and the reconciler run on rk1b (which already shares the Nomad's home LAN,
  `192.168.1.0/24`, so no subnet router is needed at home); kelpy's Caddy is the
  tailnet edge (`internal_only`). The fork's own blob store is a **separate,
  rebuildable** directory (see below).

- **The fork's store is rebuildable, not precious.** One directory,
  `/var/lib/supernote` (DB + blobs + cache), owned by a **private `supernote` user
  0700, *not* in the `library` group** — the reconciler reaches content over the fork
  **client HTTP API only**, never the filesystem. Persist it whole via impermanence +
  `StateDirectory=supernote`; **no kelpy replica, no offsite backup**. Its content is
  a strict subset of the offsite-backed `library/`, so recovery is **re-pair** (device
  intact → re-sync) or **importer re-push** (device gone → from `library/`).

- **Packaging.** Plain nixpkgs `buildPythonApplication` on **python313** plus a
  ~15-line overlay for the only two-of-71 deps missing from nixpkgs (`potracer`,
  `aiohttp-asgi`, both pure-Python). uv2nix / poetry2nix / FHS-nix-ld are all
  rejected — 69/71 deps are already packaged and the compiled ones (numpy, Pillow,
  reportlab) are aarch64-**cached**, so rk1b pulls substitutes and never hits the
  spike's manylinux/`LD_LIBRARY_PATH` pain.

## Why this shape, and the explicit no-s

- **No Supernote Cloud / Dropbox / Google Drive.** The founding constraint. All
  transport terminates on our own infra.
- **No off-the-shelf `allenporter/supernote`.** Upstream v0.16.0 ingests device
  uploads but **cannot push books down** (proven in the spike — server-origin files
  register with a `-WEB` storage key and are never indexed for the device) and its
  socket.io channel 500s. The fork is the *same* codebase with those two defects
  fixed and live-proven; it is not a hack (TDD, 388 tests green, ruff+ty clean,
  migrations drift-free, code-reviewed).
- **No WebDAV.** The interim design used one native-WebDAV server for a manual
  books-OUT leg. The fork's automatic sync makes WebDAV's per-file long-press UX
  pointless; it was dropped entirely.
- **No state DB in the reconciler.** The md5 `content_hash` is exact — `upload_content`
  finishes with the same md5 `list_folder` reads back — so absent→upload,
  differ→re-upload, match→skip needs no baseline. `_originals/` is the ledger. A DB
  would be a second source of truth to keep consistent for no gain.
- **No delete/move/rename propagation.** Content round-trips; a general file
  reconciler does not. Consequence knowingly accepted: with no tombstones, a file
  deleted on *either* side is resurrected from the other on the next poll. Correct
  delete-propagation needs a full sync engine, which reintroduces the state we
  deliberately killed — and matches the fork's own out-of-scope line.
- **No filesystem coupling to the blob store.** The reconciler uses the fork's
  first-class client API (`supernote.client` → `list_folder` + `download_content` +
  `upload_content`), never the UUID blobs or the VFS DB directly. This is what lets
  the store stay a private, rebuildable, un-backed-up subset.
- **No `services.*` module in this decision.** This ADR records the *architecture*;
  a separate build session writes the Nix. The map's only build-phase exceptions were
  choosing the packaging approach and pushing the fork branch.
- **No `.mark`-over-PDF overlay in v1.** v1 preserves the raw `.mark` sidecar beside
  the PDF; rendering the handwriting *onto* the book as `x.annotated.pdf` is the one
  net-new chunk, phased to **v1.1**.
- **No LLM features.** The fork ships Gemini transcription, semantic search, and an
  MCP server; it is adopted for its **sync transport + `.note` parsing** only. Their
  hard deps (`google-genai`, `mcp`) are accepted in the closure rather than patched
  out (patching = a fork-delta to rebase forever).

## Consequences

- **Complexity re-added on purpose.** The interim WebDAV design was *simpler* — one
  server, manual return, no reconcilers. Adopting the fork buys fully-automatic
  two-way sync at the cost of **two reconciler passes, bespoke Python packaging, a
  maintained fork pinned as a flake input, and a second durable store**. The trade is
  deliberate: hands-off sync is the original goal the spike had disproven.
- **A maintained fork to carry.** *(Superseded by the 2026-08-13 revision above: the input is now
  upstream `github:allenporter/supernote` at a bare pinned rev, and there is no fork.)* The flake
  input tracks
  `github:inkpot-monkey/supernote/fix/device-schedule-group-all`; `flake.lock` pins
  the rev and `nix flake update supernote` bumps it deliberately (fleet norm). The
  hand-written Nix `dependencies` list won't auto-follow a bump — a missing dep fails
  loudly at rebuild (`pythonImportsCheck`), caught then, not in prod. Take a local
  `sqlite3 .backup` of the alembic-migrated VFS DB before each `flake update`.
- **A microSD is a build prerequisite.** The full outbound mirror pushes all of
  `library/{books,papers}` onto the device, so the Nomad needs a **microSD** (32 GB
  internal → up to 2 TB, exFAT/NTFS/FAT32). A hardware step the build must call out.
- **Firmware floor.** The self-hosted transport needs Supernote firmware **≥ 3.25.39**
  (Chauvet, Nov 2025); the device runs **3.29.42**, confirmed in hand. A downgrade or
  a factory device below that floor breaks the transport.
- **At-home only in v1.** rk1b shares the Nomad's LAN, so no subnet router is needed
  at home; extending reach away-from-home (a GL.iNet travel router running Tailscale)
  is deferred out of v1. *(Superseded 2026-08-17: the device runs its own Tailscale
  client, so no travel router is needed for the OPDS leg. Private Cloud sync still
  wants the LAN.)*
- **New secret** — the Supernote account credential (email + password) the fork
  server and the reconciler share; sops, remember the secrets-repo commit + push +
  `nix flake update secrets` before deploy.
- **A second new secret, and two Stump facts that only bite later** (built by
  palimpsest#113). The catalog needs its own owner credential — a `stump: {user, password}`
  sub-map alongside `supernote:` in the same `profiles/library.yaml` bundle — because the
  three libraries have to be *created* by a provisioner rather than clicked into the admin
  UI: Stump's **scan pattern is immutable after creation**, so a hand-made library with the
  wrong pattern can only be fixed by deleting it and its reading progress. And since 0.1.2
  Stump **ignores reverse-proxy headers by default**, which behind kelpy's Caddy makes it
  generate self-referencing links from the direct connection (wrong scheme, and its own
  listen port appended) — the links an OPDS client traverses by, so the delivery path breaks
  before it starts. `STUMP_TRUST_PROXY_HEADERS` is the switch; it is safe only because the
  port is open on `tailscale0` alone, so nothing but the edge can set those headers.
  Finally: **take a `sqlite3 .backup` of `/var/cache/stump/stump.db` before every version
  bump** — the reading-session consolidation shipped with an explicit data-loss warning,
  and the next migration is a coin flip. The step is written out in
  `modules/nixos/profiles/stump.nix`'s header.
- **Reuses established patterns.** git-annex owning the tree so the authoritative node
  can push follows **[ADR-0028](0028-git-annex-owns-the-shared-music-library.md)**
  (music); the rk1b-authoritative / kelpy-Caddy-edge / tailnet-only shape follows
  **[ADR-0027](0027-navidrome-friends-music-platform.md)** (Navidrome); the
  persist-whole-via-impermanence store follows
  **[ADR-0004](0004-impermanence-ephemeral-root.md)**. The one deliberate divergence
  from the music library: this corpus **is** offsite-backed, because documents are
  personal and not re-acquirable.
- **Out of scope for v1** (each ruled deliberately, not forgotten): reading-progress /
  position sync (no device API); automated book acquisition; multi-user / friends
  sharing; the fork's AI/semantic features; a full two-way *file* mirror (deletes /
  moves / conflict convergence); tag-curated outbound selection (a real Stump
  Smart-List capability, deferred because reading it would couple the stateless FS
  reconciler to Stump's DB).
- **The build plan lives beside this ADR** — `.scratch/supernote-library.md`
  (component list, host placement, modules to write, secret shape, wiring order,
  round-trip verification), the executable handoff a separate build session runs.
