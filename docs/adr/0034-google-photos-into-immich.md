# The Google Photos archive moves into Immich with `immich-go`, because Takeout keeps half the metadata outside the files

Google account storage is **15.00 GiB and 100% full**, and the culprit is **Google Photos at
10.84 GB** — not mail. The whole Gmail archive is ~2.9 GiB, so deleting *every email* would
free under 20% of the quota while destroying the only second copy of it. Photos is where the
space is, and Immich on `rk1b` has existed since 2026-09-27 for exactly this
(`hosts/default.nix`: "the personal photo library, **replacing the Google Photos/Drive
archive**"). This ADR records how the archive gets out of Google and into Immich, and why the
obvious first-party tool is the wrong one.

**Decision: use `immich-go upload from-google-photos` over unzipped Google Takeout archives.**
Not the official `immich` CLI, which is first-party, already proven on this fleet, and
*cannot read Takeout's `.json` sidecars at all*.

## Revision — 2026-10-02: the import is DONE, and three of this ADR's predictions were wrong

The full Takeout (`takeout-20261002T163314Z-1-001.zip`, 13.44 GB, 4451 media + 4768 sidecars)
was imported with `immich-go upload from-google-photos` 0.32.0. Immich went from 782 to **4451
assets**, 4448 of them with real dates, 0 errors. The decision above held — but three specific
claims in it did not, and they are corrected here rather than left to mislead.

**1. immich-go DOES update metadata on assets the server already has.** The text below says it
does not, reasoning from `UpdateAsset` being gated on `ar.Status != immich.StatusDuplicate`
(`run.go:467`) in v0.30.0. The actual run reports `metadata updated: 4450` out of 4451, against
1696 assets the server already held. So either 0.32.0 changed this or the gate is narrower than
the code reading implied. Either way the practical consequence is the good one: pre-existing
assets DID receive their Takeout dates, locations and album membership. Do not plan around the
pessimistic claim.

**2. The `0001-01-01` date hazard did not materialise.** The text below flags, as an unverified
code-reading inference, that a `photoTakenTime` of `"0"` might be sent as `0001-01-01T00:00:00Z`.
Measured after the import: **zero** assets with a year below 100. The 3 epoch-dated (1970) assets
are the same 3 that predated the import. Treat the hazard as not-observed on real Takeout data.

**3. The real metadata risk was Google's, not immich-go's.** The export placed the `17 Nov 2011`
album's **sidecars in the album folder and its media in `Photos from 2011`** — 121 entries in that
album folder, every one a `.json`, zero media. immich-go behaved correctly and created no album,
because it had no assets to attach. 7 of 8 albums came through; that one did not. All 120 photos
were present and imported via the year folder, so nothing was lost — only the grouping. Repaired
by matching the album's sidecar basenames to assets **by SHA-1** (filename matching was unsafe:
120 names resolved to 131 assets with 11 ambiguous) and creating the album through Immich's API.
9 albums now exist. If a future Takeout is imported, check album count against the export's album
folders rather than trusting the summary counters.

Also observed, for whoever runs this next: 2 × `createStack 400 Bad Request` (26 stacks did
succeed), 1 video in Takeout's `Failed videos` folder that Google could not export, and the
export being 13.44 GB against 10.84 GB of reported Google Photos usage — Takeout ships originals
plus edited renditions plus sidecars, so larger is the expected direction.

______________________________________________________________________

## Why the first-party tool loses

Takeout emits a per-file `.json` sidecar beside each original, and that sidecar is not
redundant with the file's EXIF — it is the **only** home of a whole class of metadata. Google's
own wording is narrow and worth quoting, because it is the single primary statement on the
subject: "The photo or video metadata still has the original timestamp preserved in the
metadata embedded within the files"
([support.google.com/photos/answer/3024190](https://support.google.com/photos/answer/3024190)).
Read carefully, that says Takeout returns the file with **its original** embedded metadata —
not Google's current view of it. So:

| Metadata | In the file | Only in the sidecar |
| --- | --- | --- |
| `DateTimeOriginal` as the camera wrote it | ✅ | |
| A date **corrected inside Google Photos** | ❌ | ✅ `photoTakenTime` |
| GPS the camera recorded | ✅ | |
| A location **added by hand**, or estimated by Google | ❌ | ✅ `geoData` |
| Album membership | ❌ | ✅ (structurally — see below) |

The official CLI looks for a `.xmp` sidecar and nothing else
(`packages/cli/src/commands/asset.ts:444`); a `.json` never enters its walk. Immich's own docs
send you to `immich-go` for this job. So every corrected date, every hand-placed pin and every
album would be dropped on the floor — silently, with the import otherwise appearing to succeed.

A second, subtler point: album membership in Takeout has **no `albums` field** in the per-file
JSON. It is *structural* — the album directory plus a localised album JSON keyed `albumData`
(e.g. `métadonnées.json`). A tool that only reads per-file sidecars still gets no albums.

## What we accept by taking it

`immich-go` is a third-party Go binary whose Takeout matcher is **a heuristic pile, not a
spec** — it has to undo Google's filename mangling: truncation at 46 UTF-16 units, a `(1)`
duplicate index that lands *after* the extension on the JSON side
(`IMG.HEIC.supplemental-metadata(1).json`), and a `-edited` suffix that is **localised**
(`-modifié`, `-editat`). Its known-open failure modes — the video half of a live-photo pair
(#1321/#1432) and indexed `-edited` files (#1419) — are exactly the shapes a phone library is
full of. We take that over guaranteed total metadata loss, which is the alternative.

**What would reverse this decision:** a dry run showing the sidecars add nothing this account
needs — no albums worth keeping, no dates corrected in Google Photos, no Google-estimated
locations. Then `immich upload --album --recursive` over an unzipped Takeout is the cheaper
first-party answer, because Takeout's album *directories* are the album names. Decide that from
the dry-run counters, not from this document.

## Consequences worth knowing before the run

**Nothing from Google Photos is in Immich yet.** The 782 assets on the server as of
2026-09-28 (album `gphotos-keep`) are **not** from Google Photos — confirmed by the operator.
The directory and album names are misleading and an earlier draft of this ADR drew the wrong
conclusion from them. So this is a full import, not a top-up.

**Do NOT import `~/gphotos-archive`.** That tree — and the
`Google Photos-20260927T090126Z-1-001.zip` it came from — is a **Google Drive "download folder
as zip"**, not a Takeout: 1175 files, **zero `.json` sidecars**, and only ~1.33 GB of the
10.84 GB library. Importing it before the Takeout arrives would be actively harmful, because
immich-go cannot repair an asset it later sees as a duplicate: albums get backfilled
(`app/upload/run.go:393,399`) but `UpdateAsset` is gated on
`ar.Status != immich.StatusDuplicate` (`run.go:467`, same gate at `:567` for tags), so dates,
GPS and descriptions would be **permanently** stuck at whatever the sidecar-less file carried.
The cheap path is to import the Takeout first and let it be authoritative.

**The sidecar wins over EXIF unconditionally**, for date, description and coordinates —
`UseMetadata` (`internal/assets/asset.go:106`) assigns, it does not merge. One mitigation is
real and verified: a zero `geoData` does **not** clobber good EXIF GPS, because
`UpdAssetField.MarshalJSON` (`immich/asset.go:244`) omits the coordinates entirely when both
are zero. There is **no equivalent guard on `dateTimeOriginal`** — Go's `omitempty` does not
suppress a zero `time.Time` — so an asset whose `photoTakenTime` is `"0"` looks like it would
be sent `0001-01-01T00:00:00Z`. That is a code-reading inference, not a confirmed behaviour:
watch for 1-1-0001 dates in the dry run.

**Takeout is the only viable route out.** No API or `rclone` path preserves location: Google's
own wording, identical on the Library API and Picker pages, is that `=d` retains "all the Exif
metadata **except the location metadata**". rclone's own docs additionally self-report no
original resolution and a shared `client_id` expiring "during 2026".

**The version pairing is already satisfied, so nothing needs bumping first.** `immich-go`
gained Immich V3 support only in 0.32.0, and this fleet has `immich-go` **0.32.0** against an
Immich **3.2.2** server (verified by evaluating `nixosConfigurations.rk1b.pkgs` and
`curl /api/server/version`, not by reading a `package.nix` at an input rev — that route gives a
different, older answer and misled an earlier pass of the research).

**Operationally**, the run is the full ~10.84 GB and long-running work on this fleet gets reaped
at roughly two hours, so it must be detached with `setsid nohup`. `/var/cache` on `rk1b` has 214G free, so
space is not a constraint. Full working notes, with every claim traced to a primary source, are
in `research/google-photos-to-immich-import.md`.

## Open, and deliberately not decided here

Personal photos exist in **two unrelated collections** — the `pictures` git-annex tree
(`~/Pictures` on `sawtoothShark`, replicated to a passive repo on `kelpy`) and the Immich
library on `rk1b` — plus the Drive-download staging trees on the workstation. They are different
data classes with different lifecycles, not two copies of one thing; see the **Pictures annex**
and **Photo library** entries in `CONTEXT.md`. Whether they should converge, and in which
direction, is a real decision with real cost and is **not** settled by this ADR.
