# Supernote `.note` conversion tooling (server-side, self-hosted library)

## The question

For a self-hosted document library we want to ingest Supernote `.note` files and,
on a **server** (headless, scriptable), produce:

1. **Preserve the raw `.note`** unchanged, so it stays editable on-device later.
1. **Generate a viewable artifact** — PDF (preferred, multi-page) and/or PNG.
1. **Optionally** emit a **text / markdown sidecar** for search and indexing.

The device is a **Supernote Nomad (A6 X2)** on current-generation **Chauvet**
firmware. The device model code matters: the **Nomad is the `A6X2`** and the
**Manta is the `A5X2`** — these are the second-generation ("X2") devices, and
their `.note` files use a newer format revision than the first-generation A5X/A6X.
The key project risk is therefore **format-version support**: does the tool parse
files produced by *current* Nomad firmware, not just older A5X/A6X files?

As of 2026-07-22 the newest Nomad/Manta firmware is **Chauvet 3.29.42**
(2026-06-15), preceded by **3.28.42** (2026-05-22).
[Manta & Nomad changelog](https://support.supernote.com/change-log/changelog-for-manta-and-nomad)

## Comparison table

| Tool | Outputs | `.note` version support (incl. current Nomad) | Headless CLI? | Language / deps | nixpkgs / Nix-packageable? | Maturity | Text sidecar? |
|---|---|---|---|---|---|---|---|
| **supernotelib** (`supernote-tool` CLI, jya-dev) | PNG, SVG, PDF (raster + vector), TXT, JSON metadata dump | **Confirmed for A6X2/A5X2 at Chauvet 3.28.42** (README tested-devices table); current firmware 3.29.42 is one release newer — see risk note | **Yes** (`supernote-tool convert …`, `-a` all pages, `-j` threads) | Python ≥3.6; pure-Python deps: numpy, pillow, reportlab, svglib, svgwrite, pypng, colour, potracer, fusepy | **Not in nixpkgs**; trivially packageable — all deps pure-Python and already in nixpkgs | 434★, v0.7.1 released 2026-05-23, actively maintained, Apache-2.0 | **Yes — reads embedded realtime-recognition text** (`-t txt`), no OCR |
| **sn2md** (dsummersl) | Markdown (default), Org, HTML, via templates | Inherits supernotelib's support (wraps it); no independent format handling | **Yes** (CLI) | Python; wraps supernotelib + `llm` library; **requires external LLM API key** | Not in nixpkgs; packageable but pulls the `llm` LLM-client stack | 84★, v2.7.0 released 2026-06-18, AGPL-3.0 | **Yes — but via its own LLM OCR**, not embedded text |
| **supernote-tool = supernotelib** | — same project — | The GitHub repo `jya-dev/supernote-tool` *is* the source of the PyPI `supernotelib` package; `supernote-tool` is its console entry point | — | — | — | — | — |
| Other alternatives (SupernoteSharp, RohanGautam/supernote_pdf, PySN-dev, SupernoteExport, allenporter/supernote) | PDF/PNG/etc. | Mostly derive from / lag behind supernotelib's format work; none show a clearer current-firmware claim | varies | C# / Rust / Python | none in nixpkgs | smaller / niche | mostly no |

## Per-tool detail

### supernotelib / `supernote-tool` (jya-dev) — the canonical choice

- **Same project, two names.** The GitHub repo is
  [`jya-dev/supernote-tool`](https://github.com/jya-dev/supernote-tool); the PyPI
  distribution is [`supernotelib`](https://pypi.org/project/supernotelib/)
  (author `jya`, Apache-2.0). Installing `supernotelib` gives you the
  `supernote-tool` CLI. sn2md and most other tools depend on it.

- **Outputs.** Converts `.note` to **PNG, SVG, PDF, and TXT**, plus a JSON
  metadata dump. PDF supports both raster and **vector** handwriting
  (`--pdf-type vector`), all-pages (`-a`) and multithreaded (`-j N`, default 8).
  Colour remapping is supported. Example:
  `supernote-tool convert -t pdf -a -j 15 your.note out.pdf`.
  [README](https://github.com/jya-dev/supernote-tool/blob/master/README.md)

- **Format-version support (the critical row).** The README's tested-devices
  table explicitly lists:

  - Supernote A5 — `SN100.B000.432_release`
  - A6X / A5X — Chauvet **2.25.39**
  - **A6X2 / A5X2 — Chauvet 3.28.42**

  Since the **Nomad is the A6X2**, this is a *primary-source confirmation that the
  second-generation Nomad format at Chauvet 3.28.42 is a tested target.* Current
  firmware is 3.29.42 — one minor release newer (see Risk).

- **Text sidecar — reads embedded recognized text, does not OCR.** `-t txt`
  extracts the on-device **realtime handwriting-recognition** text embedded in the
  file, a capability the README ties to "real-time recognition note introduced
  from Chauvet 2.7.21." So the text is only present if the user enabled realtime
  recognition on-device when writing; the tool does not run its own OCR.

- **Fidelity.** Renders layers and pen strokes; vector PDF preserves strokes as
  paths (via `potracer`). Known community gaps historically involve new pen types
  / brush effects and template/PDF-overlay backgrounds tracking new firmware; the
  maintainer has repeatedly patched these (see issue history).

- **Headless.** Pure CLI, no GUI, no network. Ideal for a server pipeline.

- **Nix.** **Not currently in nixpkgs** (`nix eval nixpkgs#python3Packages.supernotelib`
  fails; no `supernote-tool` attr either). But every dependency
  (`numpy pillow reportlab svglib svgwrite pypng colour potracer fusepy`) is
  pure-Python and already in nixpkgs, so a `buildPythonApplication` /
  `buildPythonPackage` derivation is straightforward. `fusepy` only matters for the
  optional FUSE-mount feature, not for conversion.

### sn2md (dsummersl) — optional markdown/OCR layer

- [`dsummersl/sn2md`](https://github.com/dsummersl/sn2md), v2.7.0 (2026-06-18),
  84★, AGPL-3.0. Converts `.note` (also `.spd`, PDF, PNG) to **Markdown / Org /
  HTML**.
- **How it makes text:** it renders pages to PNG **using supernotelib**, then
  **sends the images to an LLM** (default OpenAI `gpt-4o-mini`, also Gemini,
  Ollama, etc. via the `llm` library) to transcribe. This is **its own OCR via an
  external model**, *not* the embedded recognition text. It therefore requires an
  API key (or a local Ollama model) and network/compute.
- **Implication for a self-hosted library:** sn2md adds a cloud-LLM (or local-LLM)
  dependency and cost/privacy surface. Its format support is exactly
  supernotelib's, because it delegates parsing to it. Best treated as an
  *optional* enrichment stage layered on top of supernotelib, not the base
  converter.

### Other tools surveyed

- **SupernoteSharp** (nelinory) — C#/.NET unofficial library; niche, Windows-centric.
- **RohanGautam/supernote_pdf** — "lightning fast `.note` → PDF"; performance-focused
  but narrower and less clearly tracking current firmware.
- **mmujynya/PySN-dev**, **AxisCode-Release/SupernoteExport** — Python workflow /
  Windows-app wrappers that lean on supernotelib-style parsing.
- **allenporter/supernote** — a self-host "knowledge hub" that again builds on the
  same parsing ecosystem.
- **philips/supernote-obsidian-plugin** — Obsidian client integration, not a
  headless server tool.

None of these presents a stronger or more current-firmware format claim than
supernotelib, and none is in nixpkgs.
[Search context](https://github.com/dsummersl/sn2md) ·
[awesome-supernote list](https://github.com/fharper/awesome-supernote)

## The `.note` format itself

- **No official public specification exists.** Ratta's `.note` is proprietary and
  undocumented; it cannot be read by non-Supernote software directly.
- **The de-facto reference is the supernotelib source itself** — its parser is the
  best reverse-engineered spec (header/footer keyword tables, per-page layer
  structure, and the `RATTA_RLE` run-length bitmap encoding). `supernote-tool analyze` / the JSON metadata dump expose the parsed structure, which is the
  practical way to inspect a file's format revision.
  [jya-dev/supernote-tool](https://github.com/jya-dev/supernote-tool)
- **Stability:** the format is **versioned and changes across firmware
  generations.** The repo's own issue history documents the pattern — e.g.
  "Library doesn't work after recent .note file format change in beta" (#10),
  "unsupported file format" (#33), "manta file doesn't open" (#46), "Errors after
  device version update" (#52) — **all now closed/fixed.** This is the signature
  break-on-new-firmware-then-patch cycle you should expect to continue.

## Recommendation

**Use `supernotelib` (`supernote-tool` CLI) as the base converter**, packaged as a
small Nix derivation, producing this output set per ingested note:

- **Keep the raw `.note`** verbatim (the source of truth; still on-device editable).
- **`supernote-tool convert -t pdf -a` → multi-page PDF** as the primary viewable
  artifact. Consider `--pdf-type vector` for crisp, scalable strokes / smaller
  files (fall back to raster if any page fails).
- **`supernote-tool convert -t png -a` → per-page PNG** if the library wants image
  thumbnails/previews.
- **`supernote-tool convert -t txt -a` → text sidecar** for search/indexing —
  cheap, offline, no external services. Note it only yields text for pages the user
  wrote with **realtime recognition** enabled; expect empty output otherwise.

**Treat sn2md as an optional, later enrichment stage** only if you want markdown
transcription of *non-recognized* handwriting and are willing to run an LLM
(local Ollama to keep it self-hosted). It sits *on top of* supernotelib, so it
adds nothing to base format support and everything to operational complexity.

Rationale: supernotelib is the canonical, actively maintained, pure-Python,
network-free, Apache-2.0 tool; it is what the rest of the ecosystem is built on;
it emits every artifact we need from one CLI; and it is the *only* surveyed tool
whose primary-source docs explicitly name the **A6X2 (Nomad) at a near-current
Chauvet firmware** as tested. It is not yet in nixpkgs but is trivially
packageable.

## RISK callout — format-version support (MODERATE, not fully cleared)

> The "preserve raw `.note` + convert" decision depends on the converter parsing
> **current Nomad firmware** files. Here is the honest state:
>
> - **Confirmed:** supernotelib's README tested-devices table explicitly lists
>   **A6X2 / A5X2 (Nomad / Manta) at Chauvet 3.28.42** — a primary-source claim of
>   second-generation support at a very recent firmware.
> - **Not confirmed:** the *exact current* Nomad build is **Chauvet 3.29.42**
>   (2026-06-15), **one minor release newer** than the 3.28.42 the library was
>   tested against. The repo's issue history proves new firmware has repeatedly
>   broken parsing before a fix landed (#10, #33, #46, #52). So a 3.29.42 file is
>   *very likely* fine but is **not yet a documented tested target.**
>
> **What would confirm it:** export or sync one real `.note` file off *this* Nomad
> on its *actual* installed firmware and run
> `supernote-tool convert -t pdf -a sample.note out.pdf` (and `-t txt`) on the
> server. A clean multi-page PDF (and, for a recognition-enabled page, non-empty
> txt) confirms end-to-end support for the real format revision. Do this **before**
> committing the pipeline design. If it fails with an unsupported-version error,
> the mitigation is to pin/track supernotelib upstream and file/await the
> customary fix — the same cycle every prior firmware bump has followed.
>
> The callout is **partially raised, not dismissed**: device-class support is
> confirmed, but the one-firmware-version gap plus the historical break-then-fix
> pattern means you should verify against a real sample rather than assume.

## Sources

- supernote-tool README (outputs, tested devices, txt/realtime-recognition, Chauvet versions): https://github.com/jya-dev/supernote-tool/blob/master/README.md
- supernote-tool repo (434★, v0.7.1 2026-05-23, issues): https://github.com/jya-dev/supernote-tool
- supernotelib on PyPI (v0.7.1 2026-05-23, deps, Python ≥3.6, Apache-2.0): https://pypi.org/project/supernotelib/
- supernote-tool issues (firmware/format breakage, all closed): https://github.com/jya-dev/supernote-tool/issues (#10, #33, #46, #52)
- sn2md repo (LLM-OCR to markdown, wraps supernotelib, 84★, v2.7.0 2026-06-18, AGPL-3.0): https://github.com/dsummersl/sn2md
- Manta & Nomad firmware changelog (Chauvet 3.29.42 2026-06-15, 3.28.42 2026-05-22): https://support.supernote.com/change-log/changelog-for-manta-and-nomad
- awesome-supernote (ecosystem survey): https://github.com/fharper/awesome-supernote
- nixpkgs absence verified locally: `nix eval nixpkgs#python3Packages.supernotelib` / `nixpkgs#supernote-tool` → attribute not found (2026-07-22)
