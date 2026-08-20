# Adding x-pointer support to Stump

**Date:** 2026-08-20 · **Status:** feasibility research for a HITL decision — nothing built,
nothing patched. Follows the gap documented in `docs/runbooks/supernote-koreader-opds.md`
§"The web reader will not resume where the device left off" (#116).

## The question

The Nomad pushes a position, Stump keeps the percentage and throws the position away, so the
web reader opens at page one. Upstream's own comment says it would like to translate the
x-pointer and declines. **How hard is it actually?**

## Verdict

**Tractable, and smaller than the code comment implies.** The conversion that gets the web
reader to the right *paragraph* is roughly 200 lines of Rust in a crate that already has both
dependencies it needs. Chasing the exact *character* is a different and much worse problem, and
is not worth buying.

The cost is not the algorithm. It is that this belongs upstream (a fork of a Rust workspace with
no binary cache is a standing tax — see the header of `pkgs/stump/default.nix`), and upstream's
review latency is not ours to schedule.

## What blocks it today

`apps/server/src/routers/koreader/sync.rs`:

- `parse_progress` (line 208) accepts `epubcfi(…)` or an integer and returns `None` for anything
  else. `put_progress` (line 292) logs at `debug` and stores percentage only.
- The raw string is *not* lost: `koreader_progress` is written verbatim (line 310), it is a real
  column (`crates/models/src/entity/reading_session.rs:51`), and — because the entity derives
  `SimpleObject` — it is already exposed to the client as `koreaderProgress`
  (`packages/graphql/src/client/graphql.ts:3730`). Nothing needs to be captured that isn't
  already captured.
- The web reader restores from `readProgress.epubcfi` and nothing else
  (`packages/browser/src/components/readers/epub/EpubJsReader.tsx:532`).

Unchanged on upstream `main` as of today, and 0.1.6 is still the latest release.

## The grammar, from the source that writes it

crengine `ldomXPointer::toStringV2()` (`crengine/src/lvtinydom.cpp:11616`) emits an XPath subset:

```
/body/DocFragment[11]/body/div[2]/p[3]/text()[2].14
└ crengine root      └ per spine item        └ text step  └ char offset
```

Element steps are `name` or `name[k]`, where `k` is 1-based **among same-named siblings**.
Three facts from the same file's version log (lines 40–96) do most of the work for us:

1. **`DocFragment[N]` → spine index `N-1`.** Since DOM version 20240114 crengine creates a
   fragment for *every* `<spine>` item, not just `application/xhtml+xml` ones. KOReader
   v2026.07.1 is well past that.
1. **V2 pointers are normalized**: they survive "the insertion or removal of autoBoxing,
   floatBox and inlineBox", i.e. crengine's synthetic layout nodes are *not* in the path. The
   path describes the source XHTML, which is the document Stump can open.
1. Serialization emits `[1]` explicitly only for DOM version ≥ 20260812; older pointers omit the
   index when a name is unique. A parser must accept both. (Our one hardware-observed sample,
   `/body/DocFragment[17]/body/div.0`, is the older shape.)

## What epub.js will accept on the other side

From `epub.js/src/epubcfi.js` and `spine.js`:

- Spine lookup is `cfi.spinePos = cfi.base.steps[1].index` (line 140) — the **second** step of
  the base. The leading `/6` (the `<spine>` element's own step in the package document) is not
  consulted by `Spine.get`, so getting it exactly right is correctness hygiene, not a
  requirement.
- Element steps resolve as `container.children[step.index]` (`walkToNode`, line 856) or
  `*[position()=n]` (`stepsToXpath`, line 782). Both count **elements only**. So an
  element-granularity CFI — no text step, no `:offset` — is fully resolvable, and whitespace
  text nodes cannot shift it.

That last point is the one that collapses the difficulty. The hard part of CFI generation is the
text-node numbering rules; declining to emit a text step deletes that entire problem, and costs
only sub-paragraph precision — which is below what a page-turn on e-ink means anyway.

## The one thing that still requires opening the book

`p[3]` (3rd `p` among siblings) is not CFI step `6`. CFI counts *all* element children, so the
3rd `p` may be the 6th element → step `12`. That mapping cannot be computed from the pointer
alone: the spine item's XHTML has to be read.

Prototyped against a real EPUB (`research/prototypes/xpointer-to-epubcfi.py`, run over Stump's
own `core/integration-tests/data/leaves.epub`):

```
x-pointer : /body/DocFragment[3]/body/p[3].0
epubcfi   : epubcfi(/6/6[item41]!/4/12)

x-pointer : /body/DocFragment[3]/body/blockquote/div/p[153].0     <- what the script prints
epubcfi   : epubcfi(/6/6[item41]!/4/14/2/306)
text      : 'To The States [To Identify the 16th, 17th, or 18th Presidentiad]'
```

`/4` is `<body>` (2nd element child of `<html>`); in the first case `/12` is the 6th element
child of body — the 3rd `p`. The whole converter is ~40 lines of substance.

## Where the Rust would go

`core/` already depends on both things needed: `quick-xml` (`core/Cargo.toml:63`) and the `epub`
crate, with `EpubProcessor::get_resource_by_id` / `spine` in
`core/src/filesystem/media/format/epub.rs`. The sync handler already has the file: `put_progress`
loads the `media` row, which carries `path`.

**No new dependency means no `Cargo.lock` change, which means no `cargoHash` churn in
`pkgs/stump/default.nix`** if this is ever carried as a patch here rather than upstreamed. Worth
protecting deliberately.

Shape:

1. Parse the pointer (tolerating both index forms; skipping `autoBoxing`/`floatBox`/`inlineBox`/
   `tabularBox` should a legacy-DOM book produce a V1 pointer).
1. `DocFragment[N]` → `spine[N-1]` → idref + href.
1. Stream the spine item's XHTML with `quick-xml`, following the named path and counting element
   children, emitting `2*(position)` per step.
1. Emit `epubcfi(/6/{2N}[idref]!/4/…)`.
1. **Fail soft, always**: an unresolvable step keeps the deepest ancestor resolved so far; total
   failure keeps today's percentage-only behaviour. A device push must never 500 because a book
   has surprising markup.

One extra file open per sync push (one per device per ~minute) — not a concern.

## Options, cheapest first

| | What it buys | Cost | Where it lives |
|---|---|---|---|
| **A. Percentage fallback in the reader** | Opens within a screen or two, for *any* book | ~10 lines: `book.locations.cfiFromPercentage(pct)` when `epubcfi` is null. Locations are already generated and cached client-side (`EpubJsReader.tsx:467`) | Stump web client |
| **B. Client-side x-pointer conversion** | Correct paragraph, web reader only | ~100–150 lines. `koreaderProgress` is already in the schema; strip `/body/DocFragment[N]`, `doc.evaluate` the rest against the loaded section (rewriting steps to `*[local-name()='p'][3]` for the XHTML namespace), then `new EpubCFI(node, section.cfiBase)` — epub.js does the CFI maths | Stump web client |
| **C. Server-side conversion (the real fix)** | Correct paragraph, stored in `epubcfi`, so it also reaches the mobile app, the "continue reading" cards, and *stops a device push from blanking the position the web reader wrote* | ~200–300 lines with unit tests, ~1 focused day, plus upstream review | `stump_core` + `parse_progress` |

A and B are patches to a frontend we would have to keep rebasing, and PR #1288 (open, 119 files,
"Support epub streaming and Readium web") replaces that reader wholesale — so effort spent there
has a visible expiry date.

> **CORRECTION 2026-08-20 (later same day):** the sentence that stood here — "C is in a router
> that PR does not touch" — is **wrong**. PR #1288 *does* modify
> `apps/server/src/routers/koreader/sync.rs`: it deletes `enum NativeProgress` and the entire
> `epubcfi` branch of `parse_progress`, and drops the `epubcfi` column from `reading_session`.
> Option C must retarget to `start_locator` (`ReadiumLocator`) — `href` + `locations.css_selector`
>
> - `progression`. That is *less* work, not more: the "one thing that still requires opening the
>   book" below is a CFI-only problem, since `name[k]` → `name:nth-of-type(k)` needs no element
>   renumbering (verified over 1608 elements, `prototypes/xp2css.py`). Note also that #1288 already
>   ships option A's percentage fallback. See `~/code/stump/HANDOFF-xpointer.md` for the full
>   finding.

**Recommendation: C, upstreamed**, with A as the honest stopgap if the position matters before
upstream moves. The maintainer has explicitly invited exactly this change in the code comment,
which is about as good a reception signal as an outside PR gets.

## What would make this harder than estimated

- **Verification needs a device.** Nothing in this repo can produce a genuine x-pointer; crengine
  is the only implementation. The check would have to assert against *recorded* pointers from the
  Nomad (the same bargain the existing check strikes for `partialMD5`), and a wrong assumption
  about crengine's DOM would sail past it.
- **DocFragment drift.** A book whose crengine cache predates DOM version 20240114 can have
  fragment indices shifted against the spine — upstream's own note warns of it. Off-by-one in the
  chapter, which is worse than no position at all. Cheap mitigation: sanity-check the resolved
  spine item, and prefer the percentage when the pointer lands implausibly far from it.
- **Text offsets, if anyone insists.** Emitting `text()[k]:offset` reopens crengine-vs-browser
  text-node numbering (whitespace handling, `<pre>` newline stripping, MOBI marker injection).
  This is where the "hard" reputation comes from, and it buys a fraction of a paragraph.
- **The percentages are not the same quantity.** crengine's is layout-based, epub.js's is
  location-based, so option A's error is book-dependent (bad for image-heavy or footnote-heavy
  books). It is a fallback, not a fix.

## Sources

- Stump v0.1.6 source, read locally: `apps/server/src/routers/koreader/sync.rs`,
  `crates/models/src/entity/reading_session.rs`, `core/src/filesystem/media/format/epub.rs`,
  `packages/browser/src/components/readers/epub/EpubJsReader.tsx`
- Upstream `main` copy of `sync.rs` — unchanged from 0.1.6 (fetched 2026-08-20)
- crengine XPointer serialization — https://github.com/koreader/crengine/blob/master/crengine/src/lvtinydom.cpp
  (`toStringV2`, and the DOM-version log at the head of the file)
- KOReader kosync plugin — https://github.com/koreader/koreader/blob/master/plugins/kosync.koplugin/main.lua
  (`syncToProgress`: `GotoPage` for integers, `GotoXPointer` otherwise)
- epub.js — https://github.com/futurepress/epub.js `src/epubcfi.js` (`stepsToXpath`, `walkToNode`,
  `fromNode`) and `src/spine.js` (`Spine.get`)
- Upstream context — issue #239 (KOReader sync implementation) and open PR #1288
  (Readium web reader)
