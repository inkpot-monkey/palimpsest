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
- **A maintained fork to carry.** The flake input tracks
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
