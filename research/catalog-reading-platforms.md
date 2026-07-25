# Self-Hosted Catalog / Reading Platform Evaluation

**Date:** 2026-07-22 · **Status:** research input for a HITL decision ticket — not a verdict.

## The requirement

A self-hosted catalog + reading platform for a mixed corpus of **published books
(EPUB) plus the user's own PDFs, papers, and notes** (mostly ISBN-less). It must
offer a **web browse + in-browser reading UI**, an **OPDS** feed, and a clean
**NixOS** deployment (ideally a real `services.*` module, not a hand-rolled
container). Target host is likely **rk1b** (aarch64 SBC) sharing resources with
other services, so runtime footprint matters.

The decision-critical constraint is that **a file-sync transport (to a Supernote
e-ink device) will sit underneath this catalog**. That makes one axis dominate all
others: does the app **own/rewrite its own managed file tree** (Calibre-style
library DB, where the app is the sole authority over the files) or does it
**index a plain folder in place** (watched-folder media-server pattern, where a
sync daemon can safely also read/write the tree)? A managed-library app and a
sync daemon fighting over the same directory is a data-loss trap; a watched-folder
indexer composes cleanly with sync.

**The lean is Stump.** This document evaluates it honestly against the field.

______________________________________________________________________

## Feature matrix

| Candidate | EPUB | PDF | In-browser reader | OPDS | Non-book metadata | Owns vs watches files | Auth / multi-user | Runtime / footprint | nixpkgs + module? | Health (as of 2026-07) |
|---|---|---|---|---|---|---|---|---|---|---|
| **Stump** | Yes | Yes | EPUB + PDF + comic readers (PDF quality unconfirmed) | **v1.2 (+PSE) and v2.0** | Weak — folder/filename/embedded only | **Watches** (media-server indexer) | OIDC + multi-user, granular perms | **Rust/Axum — very low RAM** | **Yes — `pkgs.stump` 0.1.5 + `services.stump`** | Active; **pre-1.0 beta**, solo maintainer, no timeline guarantees |
| **Komga** | Yes | Yes | EPUB + PDF/image readers | **v1.2 and v2.0** | Moderate — ComicInfo.xml/EPUB fields; PDFs minimal | **Watches** (read-only index) | Multi-user, per-library access | Kotlin/**JVM — ~300–600 MB** | **Yes — `pkgs.komga` 1.25.0 + `services.komga`** | Very healthy; 6.5k★, **only ~20 open issues** |
| **Kavita** | Yes | Yes | **Dedicated hand-crafted EPUB + PDF readers** | OPDS + OPDS-PS (1.2-class) | Moderate — filename/ComicInfo/EPUB | **Watches** (folder-based index) | Multi-user, age restrictions | C#/**.NET — ~100–300 MB** | **Yes — `pkgs.kavita` 0.9.0.2 + `services.kavita`** | Very healthy; 11.3k★, active |
| **Calibre-Web-Automated** | Yes | Yes (+27-format convert) | Basic browser reader | OPDS 1.x | **Best — full editable metadata, tags, custom cols, fetch** | **OWNS** managed Calibre `metadata.db`; ingest folder **deletes** files after import | Multi-user, strong perms | Python + calibre bins | **No — OCI-only** (would need `oci-containers`) | Active; 5.95k★ but **474 open issues** |
| base **Calibre-Web** | Yes | Yes | Basic browser reader | OPDS 1.x | Best (reads Calibre library) | **OWNS** (reads Calibre-managed DB) | Multi-user | Python | **Yes — `services.calibre-web`** (0.6.26-unstable) | Slow upstream; nixpkgs build has had breakage (issue #441911) |
| **Audiobookshelf** | Yes (2nd-class) | Yes (2nd-class) | Basic EPUB/PDF reader | **None** (open request #1953) | Weak | Watches | Multi-user | Node | Yes — `services.audiobookshelf` 2.35.1 | Very healthy but **ebooks are a side feature** |
| **Ubooquity** | Yes | Yes | Web reader | OPDS 1.x | Weak (Calibre/ComicRack import) | Watches | Basic | Java 17 | **No** (closed-source freeware) | Sporadic; **proprietary**, low community signal |

______________________________________________________________________

## Per-candidate detail

### Stump — the lean

- **Formats / OPDS:** EPUB, PDF, CBZ/ZIP, CBR/RAR with built-in readers for all
  supported formats; **OPDS v1.2 including OPDS-PSE, and OPDS v2.0** — the strongest
  OPDS story in the field (README, github.com/stumpapp/stump).
- **File model:** Stump is a **scanning media server** in the Komga/Kavita mould —
  it points at library folders and indexes them into its own database; metadata,
  reading progress and thumbnails live in Stump's DB, not by rewriting your files.
  This is the property the sync-underneath design needs. **Caveat:** I could not
  reach a primary Stump doc that says in-so-many-words "Stump never moves/renames
  your files" (several `stumpapp.dev/docs/...` guide URLs 404'd during this
  research). The read-only-indexer claim is inferred from the architecture and the
  README's framing, not a quoted guarantee — **confirm in the Stump docs/Discord or
  by observing a scan before wiring sync under it.**
- **Auth:** OIDC + multi-user with permissions, age restrictions, access control.
- **Runtime:** Rust (Axum + SeaORM + React). Explicit design goals are low memory /
  low CPU; realistically tens of MB idle — **the best fit for rk1b** and multi-arch
  images exist.
- **NixOS:** **First-class.** `pkgs.stump` (0.1.5) and a `services.stump` module now
  ship in nixpkgs (`nixos/modules/services/web-apps/stump.nix`). This repo already
  dropped its custom package/module in favour of upstream (commit 6461886).
- **Health:** latest release **v0.1.5 (2026-06-20)**, repo pushed **2026-07-21**,
  ~2.6k★, 127 open issues.

**Where Stump falls short (honest):**

1. **Pre-1.0 beta, explicitly.** README: "should be treated as beta software until
   it reaches a stable 1.0 release," and the maintainer notes work happens in
   personal time with "no guarantee of any timeline for features or bug fixes."
   Release notes have carried **data-loss warnings around DB migrations**. It is a
   small-maintainer project.
1. **Weak non-book metadata.** Like the other media servers, metadata comes from
   folder structure, filenames, and embedded EPUB/comic fields — there is **no rich,
   hand-editable per-document metadata model** for ISBN-less papers/notes. A folder
   of arbitrary PDFs becomes a series of filename-titled entries with first-page
   covers; you cannot curate author/tags/abstract per document the way Calibre lets
   you.
1. **PDF reader quality is unconfirmed.** The README asserts a built-in PDF reader
   but gives no detail; for text papers (vs. comic-style page images) reflow/quality
   is unknown. **Confirm by opening a real paper PDF in the web reader.**

### Komga — the mature watched-folder alternative

- EPUB, PDF, CBZ, CBR(non-solid); **OPDS v1.2 and v2.0** (komga.org, DeepWiki).
- **Read-only indexer:** docs confirm Komga watches folders and pulls
  new/removed books into its library **without modifying source files** — metadata
  operations happen in Komga's DB (komga.org/docs/guides/scan-analysis-refresh).
  Same clean composition with sync as Stump.
- Metadata from ComicInfo.xml / EPUB fields; PDFs get minimal metadata.
- **Runtime:** Kotlin on the JVM — heaviest of the shortlist (~300–600 MB typical),
  but runs fine on aarch64.
- **NixOS:** `pkgs.komga` 1.25.0 + `services.komga`.
- **Health: excellent** — 1.25.0 (2026-06-30), 6.5k★, and a standout **~20 open
  issues**, signalling a well-managed project. This is the **low-risk** pick.

### Kavita — dedicated readers, .NET

- EPUB, PDF, CBZ/CBR/CB7 etc.; **dedicated hand-crafted EPUB and PDF readers**
  (kavitareader.com) — the most explicit claim of a purpose-built in-browser PDF
  reader in the field. **OPDS + OPDS-PS**, on by default.
- **Folder-based indexer:** drop files in a directory; Kavita extracts metadata,
  generates covers, organises — an index, not a rewrite.
- **Runtime:** C#/.NET, ~100–300 MB.
- **NixOS:** `pkgs.kavita` 0.9.0.2 + `services.kavita`.
- **Health: very healthy** — 11.3k★, pushed 2026-07-21. More manga/comic-leaning in
  UX than book-leaning.

### Calibre-Web-Automated (and base Calibre-Web) — best metadata, wrong file model

- Richest metadata & conversion story: 27-format ingest, convert to
  EPUB/MOBI/AZW3/KEPUB/PDF, metadata fetch, KOReader sync, send-to-ereader, OPDS 1.x
  (github.com/crocodilestick/Calibre-Web-Automated). For **ISBN-less papers this is
  the only candidate with a genuinely editable per-document metadata model.**
- **But it OWNS the tree.** CWA manages a Calibre `metadata.db` library at
  `/calibre-library`; its watched `/cwa-book-ingest` folder analyses, converts, and
  imports files, then **removes them after processing**. Calibre is the sole
  authority over the managed files. **This directly conflicts with a sync daemon
  owning the same tree** — the decisive strike against it for this use case.
- **NixOS:** CWA is **OCI-only** — no nixpkgs package/module; on NixOS it means a
  hand-maintained `oci-containers` unit. Base Calibre-Web has `services.calibre-web`
  but the nixpkgs build has had recent breakage (issue #441911) and it still sits on
  top of a Calibre-managed (owned) library.
- Health: CWA active (v4.0.6, 2026-02-04; 5.95k★) but **474 open issues**.

### Audiobookshelf — ebooks are a side feature

- Reads EPUB/PDF/CBR/CBZ with progress saving, but **no OPDS** (open request #1953),
  which fails a hard requirement. Primarily an audiobook/podcast server.
  `services.audiobookshelf` exists. Not a serious contender here.

### Ubooquity — deprioritise

- Java, OPDS 1.x, supports EPUB/PDF/CBZ/CBR. **Closed-source freeware**, sporadic
  updates, **not in nixpkgs**, weak metadata. No reason to pick it over the OSS field.

______________________________________________________________________

## Ranked shortlist (feeds the HITL ticket)

**1. Stump** — best fit on the axes that actually matter here: watched-folder model
(composes with sync), the strongest OPDS (1.2 + PSE + 2.0), a Rust footprint ideal
for rk1b, and — decisively for the NixOS story — it is now **first-class in nixpkgs
with `services.stump`**. Tradeoff: **pre-1.0 beta risk** (data-loss migration
warnings, solo maintainer) and **weak non-book metadata**. Best when the corpus is
mostly browse-and-download-to-device and you accept beta risk.

**2. Komga** — the **low-risk** twin of Stump: same read-only watched-folder model,
same dual OPDS (1.2 + 2.0), `services.komga`, and a strikingly healthy project
(~20 open issues). Tradeoff: **JVM footprint** (~300–600 MB) is the heaviest on
rk1b, and non-book metadata is only moderate. Pick this if project maturity/stability
outweighs footprint and you want to de-risk the beta gamble.

**3. Kavita** — strongest **dedicated in-browser PDF reader** claim, OPDS on by
default, moderate .NET footprint, `services.kavita`, very active. Tradeoff: more
comic/manga-oriented UX and metadata still filename/embedded-driven. Pick this if the
in-browser reading experience (esp. PDF) is weighted heavily.

**Honorable mention — Calibre-Web-Automated:** unbeatable metadata/curation for
ISBN-less papers and the best send-to-ereader/KOReader tooling, but it **owns the
file tree** (conflicts with sync-underneath) and is **OCI-only on NixOS**. It would
be the answer to a *different* requirement (curate-a-managed-library, no external
sync). Keep it in view only if the file-ownership constraint is relaxed.

### Does the evidence support the Stump lean?

**On balance, yes — for this specific requirement.** Stump uniquely combines the
correct file-ownership model, best-in-class OPDS, the lightest runtime for rk1b, and
(now) a real nixpkgs module. **The lean is supported, conditional on accepting pre-1.0
risk.** If the human weights stability over footprint, the evidence points equally at
**Komga** as the safe substitute with identical file-model and OPDS properties. The
evidence argues **against** Calibre-Web-Automated for this use case, purely on
file-ownership + NixOS packaging — despite it having the best metadata.

### The single biggest differentiator

**File-tree ownership.** Because a sync daemon sits underneath, the watched-folder
indexers (Stump / Komga / Kavita) are structurally compatible while the
managed-library apps (Calibre-Web / CWA) are structurally in conflict. This split
does more to eliminate candidates than PDF-reader quality or metadata richness. The
secondary differentiator is **NixOS packaging** (real `services.*` module vs.
OCI-only), which is where Stump/Komga/Kavita pull ahead of CWA/Ubooquity.

### Open items to confirm before committing (uncertainty)

- **Stump read-only guarantee** — confirm from primary docs/Discord that a scan never
  moves/renames source files, before wiring sync under the same tree.
- **Stump & Kavita PDF reader quality on text papers** — open a real ISBN-less paper
  PDF in each web reader; "dedicated PDF reader" (Kavita) and "built-in PDF reader"
  (Stump) are claims, not observed reflow quality.
- **Kavita OPDS exact version** — docs say "OPDS + OPDS-PS"; the precise 1.2 version
  string was not stated in a primary source.

______________________________________________________________________

## Sources

- Stump repo / README — https://github.com/stumpapp/stump
- Stump releases — https://github.com/stumpapp/stump/releases (v0.1.5, 2026-06-20; repo pushed 2026-07-21 per GitHub API)
- Stump write-up (features/OPDS/Rust) — https://noted.lol/stump/ and https://www.linuxlinks.com/stump-self-hosted-media-server/
- nixpkgs `services.stump` module — https://github.com/NixOS/nixpkgs (nixos/modules/services/web-apps/stump.nix); versions via `nix eval nixpkgs#stump.version` → 0.1.5
- Komga — https://komga.org/ and https://komga.org/docs/guides/scan-analysis-refresh/
- Komga OPDS (1.2 + 2.0) — https://deepwiki.com/gotson/komga/6.1-opds-support
- Komga repo — https://github.com/gotson/komga (1.25.0, 2026-06-30; ~20 open issues per GitHub API)
- Kavita — https://www.kavitareader.com/ and https://wiki.kavitareader.com/guides/features/opds/
- Kavita repo — https://github.com/Kareadita/Kavita (0.9.0.2, 2026-05-14 per GitHub API)
- Calibre-Web-Automated README — https://github.com/crocodilestick/Calibre-Web-Automated/blob/main/README.md (managed library, ingest deletes after processing; OCI-only; v4.0.6)
- base Calibre-Web nixpkgs module / build issue — https://mynixos.com/nixpkgs/options/services.calibre-web and https://github.com/NixOS/nixpkgs/issues/441911
- Audiobookshelf ebooks + OPDS gap — https://www.audiobookshelf.org/docs/ and https://github.com/advplyr/audiobookshelf/issues/1953
- Ubooquity (Java, OPDS, closed-source) — https://vaemendis.net/ubooquity/ and https://docs.ultra.cc/applications/ubooquity
- nixpkgs versions confirmed locally: `nix eval nixpkgs#{stump,komga,kavita,calibre-web,audiobookshelf}.version` → 0.1.5 / 1.25.0 / 0.9.0.2 / 0.6.26-unstable-2026-03-01 / 2.35.1; ubooquity & calibre-web-automated absent
