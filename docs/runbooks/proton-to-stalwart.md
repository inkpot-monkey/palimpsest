# Runbook: migrating Proton Mail into Stalwart

Moves the whole Proton Mail archive into the self-hosted Stalwart mailbox on `kelpy`,
recreating Proton's folders under a dedicated **`Proton`** mailbox, carrying its labels as
**`proton/<label>`** keywords, tagging every imported message **`proton:<address>`**,
marking them all **read**, and pointing new Proton arrivals at Stalwart by forwarding.

This is the second import into this mailbox. The first is
[`gmail-to-stalwart.md`](gmail-to-stalwart.md), and it is worth reading: the ordering, the
bridge trap and the cutover shape are all the same, and the Gmail keyword was namespaced
`gmail:tsdkelly` precisely "so a later import from a second account stays
distinguishable". This is that later import.

Mail server: [`modules/nixos/profiles/mail/default.nix`](../../modules/nixos/profiles/mail/default.nix)
(enabled on `kelpy` in [`hosts/kelpy/configuration.nix`](../../hosts/kelpy/configuration.nix)).
Scripts: `.scratch/proton-migration/` (gitignored — one-off, not fleet config).

## The trap: jmap-bridge shares this mailbox

Unchanged from the Gmail import, and still live (`jmap-bridge.enable = true`).
`jmap-bridge` bridges the *same* `thomas` mailbox into Matrix, one room per thread.
`src/sync/backfill.rs` issues an **unfiltered** `Email/query` and live sync polls
`Email/changes` against a saved state token, so an unguarded import mints a Matrix room
per imported thread — and **marking the mail read does not prevent it**: the bridge never
looks at `$seen`.

Stop the bridge for the import window, then fast-forward its `changes` state to the
post-import `Email` state so it resumes *after* the import and never replays it.
`bridge.sh` does all three parts and is a verbatim copy of the Gmail one.

## The second trap: the cgroup brake, and why this import must be chunked

Stalwart on kelpy is fenced at `MemoryHigh = 1G` / `MemoryMax = 1.5G`
(`modules/nixos/profiles/mail/default.nix`), and the host has **no swap**. Those numbers
were measured against a 21,337-message / 3.1 GB mailbox that peaked at 719 MB. This
mailbox is bigger, and the difference is not academic — it broke the first attempt.

**What the brake looks like, because it does not look like a failure.** Pushed past
`MemoryHigh`, the kernel cannot reclaim an anonymous heap and throttles the process
indefinitely. On 2026-11-11 that read:

```
memory.current 1002 MiB   memory.events: high 2629125   max 0   oom_kill 0
```

`systemctl is-active` says `active`, the unit never enters `failed`, and Caddy and
Stalwart both answer on kelpy's loopback in milliseconds. From off-host, though, IMAP
`LOGIN` took 31s, then 53s, then timed out at 90s+ — while `APPEND` on an
already-authenticated connection stayed at **1 ms server-side** throughout. The
asymmetry is the tell: the auth path runs memory-hard Argon2id, so it is the first thing
a memory-throttled Stalwart stops being able to do. The profile's own fence comment names
this outcome: *"a mail server that hangs forever and tells nobody."* Only the cross-host
Gatus probe saw it, as `kelpy_mail` flapping at ~50%.

**The cost of this import, measured rather than guessed** (2026-11-12, sampling the
cgroup once a minute while appending at ~5.4 msg/s from a freshly restarted Stalwart):

| messages ingested | `memory.current` |
| --- | --- |
| 0 (idle, just restarted) | 195 MiB |
| 2,048 | 502 MiB |
| 8,720 | 715 MiB |
| 11,324 | 883 MiB |
| 13,934 | 893 MiB |
| 15,865 | 881 MiB |
| 16,186 | 918 MiB (guard stopped the run) |

**It plateaus, and that is the headline.** The working set climbs steeply for the first
~11,000 messages and then sits at 870–896 MiB while five thousand more go in — it does not
grow with the message count without bound. An early reading of the first 2,000 messages
suggested ~90–157 KB per message and therefore ~5 GB for the whole mailbox; that
extrapolation was wrong, and anyone sampling only the first few minutes will make the same
mistake. Sample past the knee.

**What that means operationally.** The plateau lands just *under* `MemoryHigh` (1 GiB),
which is why the first attempt crossed it and hung: a few hundred MiB of other activity on
top of the plateau is enough. Run the import from a freshly restarted Stalwart and it
fits, 16,000 messages at a time, with the brake never engaging (`memory.events high`
stayed at **0** for the whole run above — compare the 2,629,125 of the failed attempt).
This 57,150-message archive therefore needs **two or three chunks with a Stalwart restart
between them**, not a resized fence.

**So do not raise `MemoryHigh` on this evidence.** The number is not the constraint the
import runs into; an un-restarted Stalwart carrying a previous chunk's plateau is. The
fence comment asks for sizing on data, and the data says the workload fits beneath the
existing number when it starts from a clean heap.

`guard.sh` is what makes this safe to run unattended: it samples `memory.current` and the
`high` counter every minute, stops the import at 900 MiB or on any throttling at all, and
logs every sample so the curve above can be re-derived for the next mailbox. Stopping is
free — the ledger flushes per message.

A restart needs the operator's sudo (kelpy has passwordless sudo disabled), so a full run
of this archive is a handful of supervised chunks rather than one unattended job.

## Decisions baked in

| decision | choice | why |
| --- | --- | --- |
| Transport | Proton's **Export Tool** (`protonmail-export` in nixpkgs, 1.0.6) then **IMAP `APPEND`** | Proton has no IMAP. Bridge would give one, but over Bridge a label *is* a folder, so a 3-label message appears 4× (All Mail + 3) — you either flatten and lose labels, as the Gmail run did, or import each message once per label. The export writes `LabelIDs` into per-message JSON instead. Bridge also wants a keyring and, headless, a passphrase-free GPG key, which `modules/mail.nix` was written to keep out of that home |
| Why not `Email/import` | **Stalwart caps JMAP blob uploads at "1000 files or 50000000 bytes" per account** | measured: the first full run died at 505 messages with `403 Quota exceeded` — ~99 KB average, so the 50 MB ceiling rather than the file count. Blobs expire on a TTL rather than on use, so JMAP throttles a bulk import to roughly 50 MB an hour: days for 3.5 GB. Raising the quota means editing the mail profile and deploying a live mail server for a one-off. `APPEND` has no such quota, is one round trip instead of two, and carries the mailbox, the flags and the internal date itself. `--jmap` still forces the old path |
| Resumability | the script's own `run/imported.tsv` | imapsync gave this for free by matching headers; neither the export (which cannot be paused) nor `Email/import` does. A re-run skips what the ledger holds, and an `alreadyExists` is recorded the same way |
| Source scope | the whole export, with every **numeric** Proton id resolved from the system tables and never from `labels.json` | `All Mail`/`All Sent`/`All Drafts` are views, not folders, and the export declares them as *labels* (Type 1). Measured on the real export: there are **two** entries named "All Mail" — id 5 (55,481 messages) and id 15 (45,771, everything except Spam and Trash; the 9,710 difference is exactly those two). Trusting the file's own `Type` hung a useless `proton/all-mail` keyword on 45,771 messages. Ids 20–26 are Proton's inbox **category** views (Social, Promotions, Newsletters…) and are ignored for the same reason — `--inspect` reports them |
| Destination | a dedicated **`Proton`** mailbox, Proton's folders as children (`Proton/Inbox`, `Proton/Archive`, `Proton/<custom>`) | keeps the live Inbox usable, same as the Gmail run's flat `Gmail` mailbox. A message sits in exactly one Proton folder, so the tree costs no duplication. Unknown-folder messages land in `Proton/Unfiled` |
| Labels | `proton/<label>` keywords | a message can carry several, so mailboxes would reproduce the Bridge route's one-copy-per-label trap. The cost, stated: an IMAP keyword does not reach maildir, so these are invisible to notmuch locally — the same asymmetry `mail.nix` documents for `gmail:tsdkelly` |
| Provenance | one flat keyword, `proton:<address>` | matches `gmail:tsdkelly`. The colon is legal (RFC 8621 excludes only `( ) { ] % * " \`) and was checked against this server for the Gmail import |
| Read state | blanket `$seen` on the import; **never** in the Sieve | history arrives read; forwarded mail is new mail and must arrive unread. The Gmail Sieve clause says the same thing in situ |
| Starred / drafts | `$flagged`, `$draft` | the only two Proton system ids with an exact JMAP equivalent |
| Overlap with the Gmail archive | measured, then decided per run with `--skip-known` | **37% of this export is already in the mailbox.** The Gmail archive the first migration moved in was *also* imported into Proton, so it comes back round: 21,228 of 57,150 exported messages match a Message-Id already in this store, 21,166 of them in the `Gmail` mailbox. 17,058 carry Proton's `gmail.com` label; the other ~4,170 Proton filed elsewhere. Importing everything puts a second copy of those 21k in `Proton/*`; `--skip-known` imports the 35,922 that are new |
| Cutover | Proton forwards and **keeps its copy** | a second copy is cheap and the forwarding path is the part most likely to need a do-over |

## Credentials

- **Stalwart** (`thomas`): `email_password` in `secrets/profiles/mail.yaml`, decrypted by
  `env.sh` with the `&admin` age identity derived from `~/.ssh/id_ed25519` via
  `ssh-to-age` — the same dance as the Gmail run and
  [`parts/apps/dns/default.nix`](../../parts/apps/dns/default.nix), for the reason in
  commit `2df7172`. **Run from the operator workstation**, which holds `&admin` — not from
  a headless host.
- **Proton**: nothing is stored. `proton-mail-export-cli` prompts for the account
  password, the TOTP code, and the mailbox password if the account is in two-password
  mode. Unlike the Gmail app password there is nothing on disk and nothing to revoke
  afterwards — do not "improve" this by adding a credentials file.
- `.scratch/proton-migration/proton.addr`: one line, the Proton address. Not a secret;
  it supplies both `-u` and the `proton:<address>` keyword.

JMAP note, unchanged and still a trap: the session document advertises `apiUrl` and
`uploadUrl` against the *public* name on the *internal* port (`:8081`), which is not in
the firewall and is unreachable off kelpy. `02-import.py` rewrites the origin out of
`uploadUrl` exactly as
[`sieve-provision.sh`](../../modules/nixos/profiles/mail/sieve-provision.sh) does, keeping
the path shape; verified to resolve to `https://mail.palebluebytes.space/jmap/upload/d/`.

## Procedure

```bash
cd ~/code/nixos/.scratch/proton-migration
echo 'you@proton.me' > proton.addr
```

1. **Export** (interactive; one sitting — the tool cannot resume):

   ```bash
   ./01-export.sh
   ```

   It runs under `systemd-inhibit` (an idle suspend halfway through costs the whole run)
   and under `script`, which keeps a pty so the password prompt still works while
   recording everything to `run/export-<timestamp>.log`. At the end it calls
   `./check-export.sh`, which reconciles three numbers out of Proton's own session log
   (whose path it reads back from the run log): the count the server offered, the count
   the write stage reported, and the `.eml` files on disk — plus every `*ErrorCount` at
   zero and the exit code. Run `./check-export.sh` on its own any time to re-check.

   **Do not grep for a success string.** The first version of this check did, and reported
   a complete 57,150-message export as interrupted: the terminal says `Export Finished`
   while the library's `Message download finished` is a debug line that only ever reaches
   the session log. The counts are unambiguous; the marker was a guess.

   **That check is the whole point.** An interrupted export is indistinguishable from a
   complete one by its directory contents, the tool writes no log of its own, and Proton's
   answer to "can I pause and resume" is "No, you can't" — so a run that dies leaves a
   partial archive that looks finished. Re-running does **not** continue it: it writes a
   second timestamped directory and downloads everything again. Delete the partial one
   first; it is several GiB.

1. **Inspect the plan** (reads the export only — no server, no credentials):

   ```bash
   ./02-import.py --inspect
   ```

   Its first lines re-answer "did the export finish?" for a directory whose log is missing
   or predates that logging: the date span, the date of the **last message written**, and
   how much of the export is older than it. The tool walks newest → oldest, so a finished
   run's final writes are its oldest mail — a large share older than the last one written
   means it stopped mid-walk.

   The rest is the step that earns the route. Check three things before going further: the
   label map's folder/keyword split, the destination tally (every count should land
   somewhere you recognise, and `Proton/Unfiled` should be small or zero), and the
   "label ids in NEITHER" warning — ids Proton used that neither `labels.json` nor the
   system tables explain. Messages whose only id is unknown go to `Proton/Unfiled`.
   Also check it found `LabelIDs` and `Time`: Proton does not document this schema, so
   the script discovers it and stops rather than mis-filing.

1. **Stop the bridge** for the import window (prompts for your kelpy sudo password):

   ```bash
   ./bridge.sh state     # record the current `changes` token first
   ./bridge.sh stop
   ```

1. **Smoke-test five messages, then run it**:

   ```bash
   . ./env.sh && export STALWART_PW="$(stalwart_pw)"
   ./02-import.py                       # dry: counts, batch size, resolved upload URL
   ./02-import.py --limit 5 --go        # five real messages
   ./02-import.py --go                  # the rest
   ```

   Verified on the five, and worth re-checking if the transport ever changes: the custom
   keyword survives (`FLAGS (proton:thomassdk@pm.me \Seen)`), and `INTERNALDATE` matches
   each message's own `Date:` header rather than the import time. This server advertises
   `\*` in `PERMANENTFLAGS`, which is what makes an arbitrary keyword legal over IMAP at
   all, and its hierarchy delimiter is `/`, which is why the mailbox names match the tree
   either transport creates.

   To leave out what this store already holds, build the list from the local notmuch
   index and pass it — `notmuch` indexes by Message-Id natively, which is what makes the
   comparison exact:

   ```bash
   notmuch search --output=messages '*' | sed 's/^id://' > run/known-ids.txt
   ./02-import.py --skip-known run/known-ids.txt --go
   ```

   Mind that the index is only as current as the last `mbsync`, so a few very recent
   messages may not be in it and would import as duplicates.

   **This server does not search arbitrary headers, in either protocol.** IMAP
   `SEARCH HEADER X-Pm-Forwarded-From <addr>` returns zero against messages whose header
   was read back by `FETCH` seconds earlier, and the JMAP `header` filter does the same.
   Standard headers work — `SEARCH HEADER Subject` finds things — so the failure looks
   like a clean negative result rather than an unsupported query. Select server-side on
   something it does index (a date, a mailbox) and test the custom header client-side.

   **Do not verify overlap with a JMAP `header` filter.** `{"header": ["Message-Id", …]}`
   returns nothing on this server even for messages known to be present — checked against
   five messages read straight out of the `Gmail` mailbox — so it reports every message as
   absent and looks like a clean result.

   The smoke test is not ceremony: `Email/import` is implemented upstream
   (`crates/jmap/src/email/import.rs`) but has never been exercised against *this*
   deployment, and five messages prove the blob upload, the mailbox creation and the
   keywords in one go — check them in any client before committing to the whole archive.
   Re-run `--go` after any interruption; the ledger makes it continue rather than double.

   On success it prints `EMAIL_STATE=<token>` — that token is the next step's input.

1. **Fast-forward the bridge, then start it**:

   ```bash
   ./bridge.sh ff <token>   # refuses loudly unless exactly 1 row matches
   ./bridge.sh start
   ssh kelpy 'journalctl -u jmap-bridge -f'
   ```

1. **Set up forwarding** — Proton web UI, *Settings → All settings → Proton Mail →
   Auto-reply and forward → Forward emails → Add forwarding rule*, to
   `thomas@palebluebytes.space`. Proton mails a confirmation to the Stalwart mailbox;
   accept it there. Auto-forwarding needs a paid plan (Mail Plus and above), which this
   account has.

   Three consequences, all of them Proton's own and none worked around here:
   end-to-end encryption is **disabled for mail to and from that address**; mail that was
   forwarded *to* you cannot be forwarded on; and forwarded mail keeps its original
   `From:` while arriving from Proton's servers, so SPF/DMARC alignment breaks and
   Stalwart's spam filter may junk some of it. Watch `Junk Mail` for the first few days
   before trusting the path — the Gmail cutover needed the same watch.

1. **File the forwarded mail** by extending the Sieve in
   [`hosts/kelpy/configuration.nix`](../../hosts/kelpy/configuration.nix). **Derive the
   condition from a real message first** — Proton documents no `X-Forwarded-For`
   equivalent, so read one forward's raw headers (`notmuch show --format=raw`, or any
   client's "view source") and match what is actually there:

   ```nix
   if header :contains "<the header you observed>" "you@proton.me" {
       addflag "proton:you@proton.me";
       fileinto "Proton";
   }
   ```

   If no stable header turns up, forward to `thomas+proton@palebluebytes.space` instead
   and match the envelope detail — `require ["envelope","subaddress"]`, then
   `if envelope :detail "to" "proton"`. Sub-addressing is **not** configured explicitly in
   the mail profile, so prove it with one test message before relying on it.

   `fileinto` cancels Sieve's implicit `keep`, so these land only in `Proton` — watch that
   mailbox's unread count, not the Inbox. Do **not** add `$seen`. The module validates the
   script against the live server before activating, so a wrong `require` fails the unit
   rather than delivery, and `restartTriggers` re-converges it on rebuild.

1. **Teach this home's client** — in `palebluebytes/users`,
   `users/inkpotmonkey/modules/mail.nix`:

   - a folder-derived rule in the `postNew` hook, mirroring the Gmail one and minding the
     quoting trap for any folder whose name has a space:
     `notmuch tag +proton -- tag:new and folder:palebluebytes/Proton` (and per-folder
     rules if the children are worth tagging);
   - the Proton address appended to `extraConfig.user.other_email`
     (`"${forwardedAddress};you@proton.me"`), **not** to `aliases`: home-manager's msmtp
     module emits an account per alias with `from <alias>`, which would assert this home
     may send as the Proton address. One principal, one `From:`;
   - with `mail.nix` and the hook both reading it, the address is a candidate for
     `modules/mailbox.nix` — that file exists for facts with more than one reader.

   The `Proton` mailbox and its children sync without any change: `patterns = [ "*" ]`.
   The first poll after the import is **not** incremental — run `mbsync -a` by hand once
   rather than letting the 5-minute timer start a multi-hour sync it will try again.

## Verify

```bash
. ./env.sh && export STALWART_PW="$(stalwart_pw)"
./02-import.py --verify --skip-known run/known-ids.txt
```

**Check for duplicates, and separate yours from Proton's.** A run killed before its
ledger flushed leaves messages on the server that the next run appends again — 70 of them
on 2026-11-12, from the pre-per-message-flush code. `prune-dupes.py` removes exactly those:
the higher uid of each **same-mailbox** pair, verified by Message-Id and by this import's
keyword before each delete, expunged with `UID EXPUNGE` so nothing else carrying
`\Deleted` in that mailbox is caught. Dry by default.

Mind the distinction it is built around: a Message-Id appearing in **two different**
Proton mailboxes is not a duplicate. Five of them were `Proton/Inbox` + `Proton/Sent` —
Proton's own filing of mail the operator sent to themselves — and deleting either copy
would lose a real message.

Prints the `Proton` tree with per-mailbox counts, the number of messages carrying the
provenance keyword, and `ledger N imported / M to import` — those two numbers meeting is
the completion test. **Pass the same `--skip-known` you imported with**, or the target is
the raw export total and a finished import reports as short. Cross-check the per-folder counts against Proton's own web UI before
deleting anything upstream.

## Mail that arrived before the rule existed

Forwarding is switched on at the source before the Sieve clause is written — the clause
cannot be written until a real forward has been read — so a handful of messages always
land in INBOX ahead of it. `retrofile.py` applies the rule retrospectively to exactly
those: it selects on the clause's own condition (`X-Pm-Forwarded-From` carrying the
address), adds the provenance flag and MOVEs into `Proton/Inbox`, and does not touch
`$seen` in either direction — IMAP `MOVE` carries the flags across, so a message already
read stays read and an unread one stays unread.

Proton's own "Confirm forwarding request" notices are addressed directly to the mailbox
and carry no forwarding header, so they correctly stay in INBOX. That is the check that
the selector is the rule's condition and not a guess about which sender is involved.

Afterwards `Proton/Inbox`'s unread count is the cutover metric: every imported message is
`$seen`, so unread there means exactly "arrived since the cutover".

## Rollback

The import only ever *adds*; nothing deletes from Proton.

- **Undo the import**: delete the `Proton` mailbox (and its children) in any IMAP client,
  and delete `run/imported.tsv` so a later re-run does not skip everything. The source is
  untouched.
- **Bridge replaying the archive into Matrix**: stop `jmap-bridge`, re-run
  `./bridge.sh ff <token>` with the post-import token, start it. Rooms already created must
  be cleaned up in Matrix — see the `matrix-reset` wiring in
  [`modules/nixos/profiles/matrix/jmap-bridge.nix`](../../modules/nixos/profiles/matrix/jmap-bridge.nix),
  noting that a reset wipes the bridge DB and *re-triggers* full backfill.
- **Forwarding**: remove the rule in Proton settings. Re-enabling it needs the
  confirmation dance again.
- **The export**: `.scratch/proton-migration/export/` is plaintext mail. Delete it once
  the import verifies, or keep it deliberately as a second copy — but keep it off any
  path that syncs.

## Not a standing caveat any more

The Gmail runbook closes on "`backup.enable = false` fleet-wide, so this archive is
single-copy on kelpy". That is **stale**: `backup.enable = true` on kelpy now, and the
mail store is in its restic paths. The thing to mind instead is the rsync.net **112 GiB
soft quota**, which this host is not currently the one pressuring — a large Proton archive
is the first thing in a while that moves that number.
