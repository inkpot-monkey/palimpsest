# Getting the rest of a Google Photos account into Immich

**Date:** 2026-10-02 · **Status:** research for a HITL decision, feeding `docs/adr/0034-*`.
Nothing imported, nothing packaged, no module touched. Follows the first slice already in
Immich: 782 assets uploaded from flat directories with **no** `.json` sidecars, of which
779 kept a real date, 479 kept GPS, and all 782 carried `dateTimeOriginal` in EXIF.

## The question

~8.5 GB of a Google Photos account is still outside Immich. Dates, geotags and album
membership have to survive the move. **Which importer, and what does the Takeout sidecar
actually add over the embedded EXIF that already worked for the first 782?**

## Verdict

**Use `immich-go upload from-google-photos` on the Takeout archives.** The official
`immich` CLI cannot read Takeout `.json` sidecars at all — it looks for `.xmp` and nothing
else (`packages/cli/src/commands/asset.ts:444`), so every field that Google holds *outside*
the file would be dropped on the floor. Immich's own docs send you to immich-go for exactly
this job ([command-line-interface.md:12](https://github.com/immich-app/immich/blob/main/docs/docs/features/command-line-interface.md)).

The tradeoff is honest and worth writing into the ADR: immich-go is a third-party Go binary
whose Takeout matcher is a **heuristic pile, not a spec**, and its known-open failure modes
(the video half of a live-photo pair, indexed `-edited` files) are exactly the shapes a phone
library is full of. The official CLI is simpler, first-party and already proven on this
fleet — it just answers a smaller question.

**What would change the recommendation:** if a dry run shows the sidecars add nothing this
account actually needs — no albums worth keeping, no dates corrected inside Google Photos,
no Google-estimated locations — then `immich upload --album --recursive` over the unzipped
Takeout is the cheaper, first-party answer, because Takeout's album folders *are* the album
names (§2). Decide that from the dry-run counters, not from this document.

## Version ground truth

Verified by evaluating **this repo's own host configuration**, then cross-checking against the
running server — not by reading a `package.nix` at an input rev, which is what an earlier pass
of this note did and got wrong:

| Thing | Version | How established |
|---|---|---|
| `immich` rk1b builds | **3.2.2** | `nix eval .#nixosConfigurations.rk1b.config.services.immich.package.version` |
| `immich` rk1b is RUNNING | **3.2.2** | `curl /api/server/version` → `{"major":3,"minor":2,"patch":2}` |
| `immich-go` available to rk1b | **0.32.0** | `nix eval --apply 'c: c.immich-go.version' .#nixosConfigurations.rk1b.pkgs` |
| `immich-go` available on sawtoothShark | **0.32.0** | same, for `sawtoothShark` — this is where an upload would run |
| immich-go latest release | 0.32.0, 2026-06-25 | GitHub releases API |

⚠ **Do not read versions off `flake.lock`'s `nixpkgs` node for this.** That rev (`535f3e69`,
2026-06-03) is not what resolves here, and querying
`github:NixOS/nixpkgs/535f3e69#immich.version` directly returns a different (older) answer than
the host actually builds. The host's package set is the only thing that settles it; ask it.

Three consequences, and they are better news than the first pass of this note concluded:

1. **immich-go is already in nixpkgs** at a version available to both relevant hosts — no fork,
   no vendoring, no overlay to carry.
1. **The version pairing immich-go requires is already satisfied.** immich-go gained Immich V3
   support in 0.32.0 ("full compatibility with Immich V3.0.0 … while maintaining backward
   compatibility with Immich V2",
   [docs/releases/release-notes-v0.32.0.md](https://github.com/simulot/immich-go/blob/main/docs/releases/release-notes-v0.32.0.md)).
   Server is 3.2.2 and immich-go is 0.32.0, so **no flake bump is needed before importing** —
   which was the one prerequisite this note originally thought it had found.
1. The matcher analysis below still applies: the Takeout **matcher set is byte-identical between
   v0.30.0 and `main`** (`diff` of `adapters/googlePhotos/matchers.go` at both refs; its last
   commit is 2025-02-14), so it is unchanged in 0.32.0 too.

Where the source below is read from `main` rather than a release tag I say so.

______________________________________________________________________

## 1. What a Takeout per-file `.json` actually carries

**Google publishes no schema for these files.** Its own help page says only that "any
additional metadata that isn't from the original file, like comments within Google Photos,
are downloaded to a secondary JSON file"
([support.google.com/photos/answer/3024190](https://support.google.com/photos/answer/3024190)).
That is the whole of the primary documentation. The authoritative field list is therefore the
parser that consumes them; I take it from immich-go's struct, which is primary for *what the
tool reads* and strong secondary evidence for what Google writes
([`adapters/googlePhotos/json.go`](https://github.com/simulot/immich-go/blob/main/adapters/googlePhotos/json.go)).

| Field | Semantics | Used by immich-go as |
|---|---|---|
| `title` | The **original** filename, before Takeout truncated it | `OriginalFileName`, after stripping `\r\n\\/:*?"<>\|` (`sanitizedTitle`) |
| `description` | Caption typed in Google Photos | asset description |
| `photoTakenTime.timestamp` | Capture time, **Google's view of it**, Unix epoch seconds as a *string* | `DateTaken`; ignored when `""` or `"0"` |
| `creationTime` | When the item was *uploaded* to Google Photos | **nothing** — not in the struct at all. Correctly so; it is not a capture date |
| `geoDataExif` | Coordinates **as read out of the file's own EXIF** | first choice for lat/long |
| `geoData` | Coordinates **as Google holds them** — includes locations you set by hand and ones Google estimated | fallback when `geoDataExif` is absent or 0,0 |
| `people[].name` | Face-recognition names | tag `People/<name>`, only with `--people-tag` |
| `favorited`, `archived`, `trashed` | Google Photos state flags | favourite / `visibility=archive` / skip-unless-asked |
| `googlePhotosOrigin.fromPartnerSharing` | Presence (not value) marks a partner's asset | `FromPartner`; routable to one album via `--partner-shared-album` |
| `url`, `imageViews`, `category` | Share URL, view count, category | read, then ignored |

Two things on that list deserve emphasis because they shape the whole decision:

1. **There is no `albums` field.** Album membership is *structural*, not a field. The same
   photo is written into `Google Photos/<Album name>/` **and** into
   `Google Photos/Photos from <year>/`, and an album directory additionally carries its own
   album-level JSON — keyed `albumData`, with `title`, `description` and `enrichments`, and
   with **no `photoTakenTime`**, which is precisely how immich-go tells an album JSON from an
   asset JSON (`isAlbum()` vs `isAsset()` in `json.go`). That album JSON's **filename is
   localised** — immich-go's own fixtures use `métadonnées.json`
   (`app/upload/TEST_DATA/Takeout1/.../métadonnées.json`), so anything matching on
   `metadata.json` literally will miss non-English accounts.
1. **`geoDataExif` vs `geoData` is the interesting pair.** The naming is self-describing and
   the fallback order in `AsMetadata()` treats them as "what the file said" vs "what Google
   knows". Google does not document the distinction, so read that as inference from field
   naming plus tool behaviour — but it is the mechanism by which a photo with no EXIF GPS can
   still arrive geotagged.

`enrichments` on an album JSON carries narrative text and a `locationEnrichment` whose
coordinates are `latitudeE7`/`longitudeE7` fixed-point integers; immich-go folds the text
into the album description and the location onto the album, and will apply an album's
location to a member photo that has none (`docs/upload-commands-overview.md`, §Metadata
Mapping).

### How a sidecar is matched to its original

Four matchers, tried in order most-common-first, per directory
([`matchers.go`](https://github.com/simulot/immich-go/blob/main/adapters/googlePhotos/matchers.go),
driven by `solvePuzzle` in `googlephotos.go:291`). The design comment above them
(`googlephotos.go:262-276`) is the clearest statement of the problem that exists anywhere,
including anything Google has written — it lists the rules and then says "of course those
rules are likely to collide. They have to be applied from the most common to the least one."

| Hard case | What Takeout writes | How it is handled |
|---|---|---|
| **Plain case** | `IMG_0001.JPG` + `IMG_0001.JPG.json` | `matchFastTrack`: strip `.json`, compare |
| **Filename truncation** | Names over **46 UTF-16 code units** are cut; the JSON name and the media name are cut at different points | `matchNormal` retries after truncating the media name to 46 runes, and again after dropping its extension and one trailing rune ("the file name can be 1 UTF-16 char shorter (🤯) than the JSON name") |
| **`(1)` duplicate suffix** | The suffix lands in **different places**: media `IMG_0001(1).JPG`, JSON `IMG_0001.JPG(1).json` — i.e. *after the extension* on the JSON side | `getFileIndex` pulls the last parenthesised integer out of **either** name and requires the two indices to be equal |
| **`supplemental-metadata`** | `IMG_0001.JPG.supplemental-metadata.json`, and truncated forms of that word | `matchNormal`/`matchEditedName` test `strings.HasPrefix("supplemental-metadata", <segment>)` — arguments deliberately that way round, so **any prefix** of the word matches, because Google truncates the word itself |
| **`-edited` variants** | `IMG_0001-edited.JPG` with no JSON of its own — **and the suffix is localised** (immich-go's cases include `-modifié`; issue #1419 reports `-editat`) | `matchEditedName`: prefix-match the media name against the JSON's reduced base, explicitly refusing any media name that carries an index |
| **Motion / live photos** | A still plus a video, with a JSON for **the still only** | **Not handled.** Open issue [#1321](https://github.com/simulot/immich-go/issues/1321) (2026-03-10) / [#1432](https://github.com/simulot/immich-go/issues/1432) (2026-08-25): "Google Takeout writes a supplemental-metadata JSON only for the still image half … the video half gets no sidecar of its own; none of the existing matchers account for that" |
| **Pixel `.MP`** | A `.MP` file that is really MP4 | Renamed to `.MP4` at upload (`immich/upload.go`, "#405") |
| **Copies in the wrong folder** | "sometimes the file isn't in the same folder than the json… It can be found in Year's photos folder" (`googlephotos.go:271`) | Matching is per-directory; a file whose JSON sits elsewhere falls to `--include-unmatched` |

On **when the `supplemental-metadata` rename happened**: Google announced nothing I can find.
The first report against immich-go is
[#652, 2025-01-25](https://github.com/simulot/immich-go/issues/652) ("add support for
supplemental-metadata.json files"), with #673/#674 following on 2025-02-04 and the fix landing
2025-02-08. So: **rolled out around January 2025, undocumented, dated from the tooling's
reaction.** A related variant from #674 — "sometimes missing media extension in
`supplemental-metadata.json`" — means the media extension is not reliably present in the JSON
name either.

Known-open matcher gaps as of today, all in immich-go's tracker and all unfixed as of 0.30.0 (and
unchanged in the 0.32.0 this fleet has, since `matchers.go` has not moved since 2025-02-14):
[#1419](https://github.com/simulot/immich-go/issues/1419) (indexed `-edited` against
`...jpg.supplemental-metadata(1).json`), [#877](https://github.com/simulot/immich-go/issues/877)
and [#1422](https://github.com/simulot/immich-go/issues/1422) (`-edited` vs original ordering),
[#1011](https://github.com/simulot/immich-go/issues/1011) (same basename, different extension →
wrong sidecar), [#1014](https://github.com/simulot/immich-go/issues/1014) (missing photos in
albums), plus the live-photo pair above. These are the reason §"What would make this harder"
exists.

______________________________________________________________________

## 2. The official `immich` CLI

**It does not read Takeout JSON. Only `.xmp`, and only from two exact paths.**

From the uploader itself
([`packages/cli/src/commands/asset.ts:444`](https://github.com/immich-app/immich/blob/main/packages/cli/src/commands/asset.ts)):

```ts
export const findSidecar = (filepath: string): string | undefined => {
  // Prefer photo.ext.xmp over photo.xmp, matching the server's sidecar precedence.
  for (const sidecarPath of [`${filepath}.xmp`, `${noExtension}.xmp`]) {
```

Found files are attached to the upload as `sidecarData`. A `.json` next to a photo is not
merely ignored as a sidecar — it never enters the walk at all, because the CLI filters
candidates against the server's supported image/video extensions (`asset.ts:90,110`).

The server side matches: `getSidecarCandidates` offers `${originalPath}.xmp` and
`${dir}/${name}.xmp` and nothing else
([`server/src/services/metadata.service.ts:536`](https://github.com/immich-app/immich/blob/main/server/src/services/metadata.service.ts)),
which is also what the docs say — "`filename.ext.xmp`" preferred over "`filename.xmp`"
([docs.immich.app/features/xmp-sidecars](https://docs.immich.app/features/xmp-sidecars)).
Worth knowing for either route: when a sidecar carries a date, the server **deletes** the
media file's own date tags before merging, with the comment "prefer dates from sidecar tags"
(`metadata.service.ts:582`).

**Albums: yes, two ways.** `-a, --album` — "Automatically create albums based on folder
name" — and `-A, --album-name <name>` for one fixed album
([docs](https://docs.immich.app/features/command-line-interface)). `getAlbumName` is literally
`path.basename(path.dirname(filepath))` (`asset.ts:595`), i.e. the **immediate parent
directory only**, not the path.

That last fact is the viable fallback route, and it is worth stating plainly in the ADR:
because Takeout lays albums out as `Google Photos/<Album name>/…`, an
`immich upload --album --recursive` over an unzipped Takeout *does* reconstruct album names
— along with junk albums called "Photos from 2019" and so on, one per year directory, and
with every asset discovered twice (deduplicated by hash server-side, but with its album
membership coming from whichever directory it was walked in). Dates and GPS would then come
from embedded EXIF only — which, per the 782 already imported, is mostly sufficient. That is
the whole decision in one paragraph.

Immich's position on native Takeout support is explicit: a 2025-08-29 request to read
`{filename}.supplemental-metadata.json` as a sidecar was closed the same day by maintainer
`bo0tzz` as a duplicate of #455 with "We recommend using https://github.com/simulot/immich-go"
([discussion #21392](https://github.com/immich-app/immich/discussions/21392)). The docs carry
the same recommendation in a tip box.

______________________________________________________________________

## 3. immich-go — current syntax

Yes to both: it consumes Takeout archives (`.zip` directly, or an unpacked tree) and
reconstructs album membership.

**The command was restructured into `upload <sub-command>`** — the present-day form is
`immich-go upload from-google-photos`, alongside `from-folder`, `from-icloud`, `from-picasa`
and `from-immich` ([`docs/commands/upload.md`](https://github.com/simulot/immich-go/blob/main/docs/commands/upload.md)).
Older material showing a bare `immich-go upload` with Google flags, or `-google-photos`, is
stale. Verified by reading the flag
registrations in `adapters/googlePhotos/cmdFromGooglePhotos.go` at tag `v0.30.0`; every flag
below is present there with these exact names and defaults.

```
immich-go upload from-google-photos \
  --server=http://127.0.0.1:2283 --api-key=<key> \
  /path/to/takeout-*.zip
```

| Flag | Default | Meaning |
|---|---|---|
| `--sync-albums` | `true` | "Automatically create albums in Immich that match the albums in your Google Photos takeout" |
| `--include-untitled-albums` | `false` | untitled albums otherwise discarded outright |
| `--from-album-name` | – | import one album only |
| `--partner-shared-album` | – | route partner assets into a named album |
| `-u, --include-unmatched` | `false` | import media with **no** matching JSON |
| `-a, --include-archived` | `true` | |
| `-t, --include-trashed` | `false` | |
| `-p, --include-partner` | `true` | |
| `--people-tag` | `true` | `People/<name>` tags from `people[]` |
| `--takeout-tag` | `true` | tags everything `{takeout}/takeout-YYYYMMDDTHHMMSSZ` |

Shared with every `upload` sub-command: `--dry-run`, `--concurrent-tasks` (default = CPU
cores, 1–20), `--client-timeout` (default `20m`), `--on-errors=stop|continue|<n>`,
`--pause-immich-jobs` (default `true`, needs an admin key), `--session-tag`, `--no-ui`,
`--log-file`, `--log-level`. Takeout parts must be passed **together** —
`/path/to/takeout-*.zip` — because an asset and its JSON can land in different parts
(`docs/best-practices.md`).

**How the metadata actually gets applied** matters more than the flag list, and it is not
via a sidecar. immich-go uploads the bytes with `fileCreatedAt` set from the JSON's
`photoTakenTime` (falling back to the file mtime), then issues a second call —
`PUT /api/assets/{id}` with `description`, `latitude`, `longitude`, `rating`,
`dateTimeOriginal` (`app/upload/run.go:467`, `immich/asset.go:268`). The code comment is
"metadata from application (immich or google photos) are **forced**". Three consequences,
all read from the source:

1. **The JSON wins over embedded EXIF**, unconditionally, for date, description and
   coordinates (`UseMetadata` in `internal/assets/asset.go:106` assigns, it does not merge).
1. **A missing `geoData` does not clobber good EXIF GPS.** `UpdAssetField.MarshalJSON`
   (`immich/asset.go:244`) omits `latitude`/`longitude` entirely when both are zero, so
   Immich keeps whatever it extracted from the file. This is the single most reassuring thing
   in the codebase for an account where 479/782 had EXIF GPS.
1. **`dateTimeOriginal` has no such guard.** Go's `omitempty` does not suppress a zero
   `time.Time`, so an asset whose `photoTakenTime` was `"0"` looks like it would be sent
   `0001-01-01T00:00:00Z`. I have not confirmed what Immich does with that; treat it as a
   code-reading inference and watch for 1-1-0001 dates in the dry run.

**For assets already on the server — the 782 — the split is sharp**, and both halves are
confirmed at v0.30.0 in `app/upload/run.go`:

- **Albums are backfilled.** The `SameOnServer` and `BetterOnServer` branches adopt the
  existing asset's ID and still call `manageAssetAlbums` (`run.go:393,399`).
- **Dates, GPS and descriptions are not.** The `UpdateAsset` call lives inside
  `uploadAsset` and is gated on `ar.Status != immich.StatusDuplicate` (`run.go:467`); tags
  are gated the same way in `processUploadedAsset` (`run.go:567`).

So re-running over the overlap is safe and *does* earn the albums, but it will not repair
metadata on anything already imported. If a sidecar turns out to hold a date or location that
the already-imported copy lacks, fixing that is a separate job (Immich's own API, or
`--overwrite`, which replaces the asset — a heavier hammer than this is worth).

______________________________________________________________________

## 4. Where the metadata actually lives — the loss modes

Google's claim is narrow and worth quoting exactly, because it is the only primary statement
on the subject: "Based on the time the photo or video is downloaded, your operating system
can assign a new timestamp to the file itself. **The photo or video metadata still has the
original timestamp preserved in the metadata embedded within the files.**"
([support.google.com/photos/answer/3024190](https://support.google.com/photos/answer/3024190)).

Read carefully, that sentence says Takeout hands back the file with **its original** embedded
metadata — not Google's current view of it. Which is exactly why the sidecar is not
redundant.

| Field | In the file | Only in the JSON |
|---|---|---|
| `DateTimeOriginal` as the camera wrote it | ✅ | |
| A date **you corrected inside Google Photos** | ❌ — the file keeps the original | ✅ `photoTakenTime` |
| GPS the camera recorded | ✅ | (also mirrored as `geoDataExif`) |
| A location **you added by hand**, or that Google estimated | ❌ | ✅ `geoData` |
| Camera make/model, orientation, lens, exposure | ✅ | |
| Caption typed in Google Photos | ❌ | ✅ `description` |
| Favourite / archived / trashed | ❌ | ✅ |
| Face names | ❌ | ✅ `people[]` |
| Album membership, album description, album location | ❌ | ✅ album JSON + directory layout |
| Partner-shared origin | ❌ | ✅ `googlePhotosOrigin` |

Takeout does not *strip* EXIF so much as **fail to update it** — the divergence is created
the moment you edit metadata in the Google Photos UI rather than in the file. Two further
cases where the file itself is already degraded, both upstream of Takeout:

- **Storage saver.** Compression happens at backup, not at export: "Photos are compressed to
  save space. If a photo is larger than 16 MP, it'll be resized to 16 MP", and "Photos that
  you will upload in Storage saver may be compressed into a different image format, like a
  .jpg", with "some information, like closed captions, might be lost"
  ([support.google.com/photos/answer/6220791](https://support.google.com/photos/answer/6220791)).
  Takeout returns the stored item, so a Storage-saver library exports the compressed file and
  the original is gone — it was never uploaded.
- **`-edited` copies.** Takeout ships the original *and* a `-edited` rendition, and the
  rendition has no JSON of its own. **Whether Google's re-encode preserves the original EXIF
  in the edited copy is not settled by any primary source I can find** — not in Google's help
  pages, not in the API docs. immich-go's handling (prefix-match the edited name onto the
  original's JSON) implies the sidecar is treated as authoritative for both, but that is a
  tool's choice, not a documented guarantee. Check it on a sample rather than assuming.

______________________________________________________________________

## 5. Non-Takeout routes

**There is no longer an API route to someone's existing library.** Google removed three
Library API scopes outright: `photoslibrary.readonly`, `photoslibrary.sharing` and
`photoslibrary`. API calls relying only on them "will return a
`403 PERMISSION_DENIED` after March 31, 2025"
([developers.google.com/photos/support/updates](https://developers.google.com/photos/support/updates)).
What survives is app-created-data-only: `photoslibrary.appendonly`,
`photoslibrary.readonly.appcreateddata`, `photoslibrary.edit.appcreateddata`
([authorization](https://developers.google.com/photos/overview/authorization)). `albums.get`,
`mediaItems.list` and `mediaItems.search` now "can only be used with albums and media items
created by your app". An importer cannot enumerate a library it did not upload.

The replacement is the **Picker API** — the user picks items in a Google-hosted picker and the
app gets a session-scoped list, under
`https://www.googleapis.com/auth/photospicker.mediaitems.readonly`, with base URLs that
"remain active for 60 minutes"
([picker/guides/media-items](https://developers.google.com/photos/picker/guides/media-items)).
That is a file-chooser, not a bulk migration path, and it carries the same metadata wound as
the old API:

> "If you want to download the image retaining all the Exif metadata **except the location
> metadata**, concatenate the baseUrl with the `d` parameter."

— stated identically on the Picker page and on
[library/guides/access-media-items](https://developers.google.com/photos/library/guides/access-media-items).
**Any API route loses GPS by design.** For video, `dv` yields "a high quality, transcoded
version of the original video" — a transcode, not the original.

**rclone's backend inherits all of it**, and says so in its own docs
([rclone.org/googlephotos](https://rclone.org/googlephotos/)):

- "The current google API does not allow photos to be downloaded at original resolution."
- "When Images are downloaded this strips EXIF location (according to the docs and my tests)."
- Videos download "significantly compressed" relative to the web UI.
- "Rclone can only upload files to albums it created", and the API cannot delete albums.
- Post-2025-03-31: rclone can only download photos it previously uploaded itself, requiring
  `rclone config reconnect`.
- The shared `client_id` "will stop working during 2026" — own credentials now required.

So rclone is useful for *moving the Takeout archives around*, and useless as a Google Photos
reader. No API or rclone route returns full-resolution originals with EXIF intact. **Takeout
is the only complete-fidelity export Google offers.**

______________________________________________________________________

## Operational notes for the ~8.5 GB run

- **Takeout request:** ZIP, and the largest part size (50 GB) to avoid splitting
  (`docs/best-practices.md`; Google's own page confirms a 50 GB option and that "if the data
  you're downloading is larger than this size, multiple archives will be created"). At
  8.5 GB this should be a single part — which sidesteps the cross-part matching problem
  entirely.
- **Pass every part at once** if there is more than one: `.../takeout-*.zip`.
- **Dry run first**, and read the counters rather than the vibes:
  `--dry-run --log-level=DEBUG --log-file=…`. The number to watch is
  `ProcessedMissingMetadata` (unmatched media, `googlephotos.go:322`) — that is the matcher
  failure rate on *this* archive, and it is the input to the §3 fallback decision. The log
  also records which matcher won per file (`"matcher", matcher.name`, `googlephotos.go:309`),
  so a suspicious match is traceable.
- **Detached run**, per the two-hour reaping constraint, with the server flags set for a
  network link rather than a LAN: `--on-errors=continue`, a generous `--client-timeout`, and
  `--concurrent-tasks` in the 4–8 range (`docs/best-practices.md` §Network Considerations).
  Restart is safe — immich-go indexes the server's assets and skips by checksum.
- **`--pause-immich-jobs` defaults to `true` and needs an admin API key.** The key this fleet
  provisions is minted through Immich's own API by `immich-provision.py`; if it is not an
  admin key, either pass `--pause-immich-jobs=false` or expect that call to fail. Worth
  settling before the detached run rather than during it.
- **`--takeout-tag` and `--session-tag`** make the whole batch selectable afterwards, which
  is what makes a bad import undoable. Leave them on.
- The run is ~8.5 GB in and more than that back out again in thumbnails and transcodes:
  `custom.profiles.immich.mediaLocation` wants headroom, and on an rk1-style host it must
  already be the NVMe subtree, not the tmpfs root.

## What would make this harder than it looks

- **The matcher gaps are in the shapes a phone library is made of.** Live-photo pairs
  (#1321/#1432) and indexed `-edited` files (#1419) are both open, both still unfixed and
  both common. Their failure mode is the *good* one — reported as missing metadata, not
  silently mismatched — but a library with many motion photos will see the video halves land
  without dates unless `--include-unmatched` is on, and then they land with *file* dates.
- **`--include-unmatched` is a real tradeoff, not a safety net.** Off, unmatched media is
  skipped entirely; on, it is imported with only embedded EXIF — which for this account is
  mostly fine (779/782), but silently mixes two provenance classes in one import. A
  two-pass run (matched first, then unmatched with a distinguishing `--tag`) keeps them
  separable.
- **`matchForgottenDuplicates` is loose by construction** — prefix match plus "fewer than 10
  runes of difference" (`matchers.go`). It runs third, after the precise matchers, but it is
  the one that could attach the wrong sidecar, and a wrong sidecar is worse than none because
  the JSON is applied as authoritative.
- **Nothing here is reversible by a flag.** `UpdateAsset` overwrites Immich's extracted EXIF
  with the JSON's view. If the JSON is wrong — and Google's own date for a scanned or
  re-uploaded photo frequently is the upload date — the extracted truth is gone from the
  database. The session tag is the only undo.
- **Album names come from Google and are not vetted.** `--sync-albums` will create an album
  per Takeout album directory, titled from the album JSON or else from the directory
  basename, including auto-generated ones. `--include-untitled-albums` defaults off, which is
  the right default.
- **Version skew is the quiet one.** immich-go talks to Immich's REST API directly, including
  endpoints it reaches by hand (`PUT /api/assets/{id}`, `POST /api/search/metadata`). A
  nixpkgs bump that moves Immich but not immich-go — or the reverse — is a real failure mode,
  and the only reason it is not a risk today is that the pin happens to carry a compatible
  pair.

## Sources

- Immich docs — [command-line-interface](https://docs.immich.app/features/command-line-interface),
  [xmp-sidecars](https://docs.immich.app/features/xmp-sidecars); markdown source
  `docs/docs/features/command-line-interface.md:12` for the immich-go recommendation
- Immich source, `main` as of 2026-10-02 — `packages/cli/src/commands/asset.ts`
  (`findSidecar`, `getAlbumName`, the extension filter),
  `server/src/services/metadata.service.ts` (`getSidecarCandidates`, `getExifTags`)
- Immich [discussion #21392](https://github.com/immich-app/immich/discussions/21392) —
  maintainer closing a native-Takeout-JSON request as a duplicate of #455
- immich-go docs — [commands/upload.md](https://github.com/simulot/immich-go/blob/main/docs/commands/upload.md),
  [upload-commands-overview.md](https://github.com/simulot/immich-go/blob/main/docs/upload-commands-overview.md),
  [technical.md](https://github.com/simulot/immich-go/blob/main/docs/technical.md),
  [best-practices.md](https://github.com/simulot/immich-go/blob/main/docs/best-practices.md),
  [release-notes-v0.32.0.md](https://github.com/simulot/immich-go/blob/main/docs/releases/release-notes-v0.32.0.md)
- immich-go source — `adapters/googlePhotos/{json.go,matchers.go,googlephotos.go,cmdFromGooglePhotos.go}`,
  `app/upload/run.go`, `immich/{upload.go,asset.go}`, `internal/assets/asset.go`; read at
  both `main` and tag `v0.30.0`, with `matchers.go` verified byte-identical across the two
- immich-go issues — [#652](https://github.com/simulot/immich-go/issues/652),
  [#673](https://github.com/simulot/immich-go/issues/673),
  [#674](https://github.com/simulot/immich-go/issues/674) (supplemental-metadata rollout),
  [#877](https://github.com/simulot/immich-go/issues/877),
  [#1011](https://github.com/simulot/immich-go/issues/1011),
  [#1014](https://github.com/simulot/immich-go/issues/1014),
  [#1321](https://github.com/simulot/immich-go/issues/1321),
  [#1419](https://github.com/simulot/immich-go/issues/1419),
  [#1422](https://github.com/simulot/immich-go/issues/1422),
  [#1432](https://github.com/simulot/immich-go/issues/1432)
- Google — [How to download your Google data](https://support.google.com/photos/answer/3024190)
  (embedded-timestamp statement, secondary JSON, archive formats and sizes),
  [Storage saver vs Original quality](https://support.google.com/photos/answer/6220791)
- Google Photos APIs — [scope removal notice](https://developers.google.com/photos/support/updates),
  [authorization scopes](https://developers.google.com/photos/overview/authorization),
  [picker/guides/media-items](https://developers.google.com/photos/picker/guides/media-items),
  [library/guides/access-media-items](https://developers.google.com/photos/library/guides/access-media-items)
- [rclone Google Photos backend docs](https://rclone.org/googlephotos/)
- nixpkgs — `pkgs/by-name/im/immich/package.nix` and `pkgs/by-name/im/immich-go/package.nix`,
  read at this repo's pinned rev `535f3e69` and at `nixos-unstable`
- **No claim here rests on a blog post or forum answer.** Where no primary source settles a
  question — the `.json` schema itself, the `supplemental-metadata` rename date, EXIF
  retention in `-edited` renditions, `geoData` vs `geoDataExif` semantics — that is said in
  place.
