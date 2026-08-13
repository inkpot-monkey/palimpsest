# A self-hosted document library round-trips to the Supernote through the allenporter fork, indexed by Stump

A self-hosted, annotated **document library** — books *and* the user's own
PDFs/papers/notes — that a **Supernote Nomad (A6 X2)** can read on e-ink and write
handwriting back into, with a **web browse + in-browser reading UI**, was the goal.
The hard constraint that shaped everything: transport is **self-hosted only** —
Supernote Cloud, Dropbox, and Google Drive are all banned — and the device is a
locked-down Android tablet that **cannot run a Tailscale client**, so tailnet
reachability has to come from the network, not the device. Handwritten annotations
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
  cause deletions in the backed-up tree.) Tracked as palimpsest#114 (serve), #115 (device),
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

- **The realtime channel is upstream and better.** The fork hand-rolled Engine.IO v3 in
  `server/realtime.py` precisely because modern `python-socketio` rejects `EIO=3`. Upstream now
  serves socket.io with the real library and `allow_eio3=True` (`server/socket.py`), and adds what
  the fork's connect-only prototype never had: handshake **signature** verification, `ratta_ping`,
  and server→client push. This is a superset, not a substitute.
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
  #142 is on the *reconciler's* path and turned the `supernote_ereader` check red. It matters
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
  is deferred out of v1.
- **New secret** — the Supernote account credential (email + password) the fork
  server and the reconciler share; sops, remember the secrets-repo commit + push +
  `nix flake update secrets` before deploy.
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
