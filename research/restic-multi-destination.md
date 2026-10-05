# A second off-site restic destination, and a pattern that generalises across the fleet

**Date:** 2026-10-05 · **Status:** research for a HITL decision. Nothing provisioned, no module
touched, no secret created. Follows `hosts/rk1/backup.nix`, the fleet's first live off-site job
(rsync.net over sftp, 25.67 GB used of a 112 GB soft quota).

## The question

One off-site destination is not 3-2-1. **How do we add a second, and what shape does the
NixOS config take so it generalises to all four hosts?** Two sub-questions turn out to carry
the whole decision: fan-out (N independent `restic backup` runs) versus replication
(`restic copy` primary→secondary), and whether the second destination can be made
*append-only* so a compromised host cannot destroy both copies at once.

## Verdict

**Fan out. Do not replicate. Second destination: Backblaze B2 via its S3-compatible API,
EU Central (Amsterdam), behind an application key with no delete capability and a bucket
lifecycle rule that keeps prior versions for 30 days.**

Three reasons, each resting on a primary source rather than a preference:

1. **`restic copy` downloads the entire payload from the primary before re-uploading it**,
   because the two repositories use different encryption keys. restic's own docs mark this
   `.. important::` — "This process will have to both download (read) and upload (write) the
   entire snapshot(s) due to the different encryption keys used in the source and destination
   repository"
   ([045_working_with_repos.rst:238](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)).
   For a delta of `d` bytes, fan-out to two destinations costs `2d` of upload from the host;
   copy costs `d` up + `d` down + `d` up, and the download leg lands on the *host's* downlink,
   not on a link between the two providers. Copy only wins when the copying machine sits
   closer to both repos than the data source does — which describes a VPS-mediated topology we
   do not have.
1. **Copy makes the secondary a derivative of the primary.** rsync.net is the only copy of the
   fleet's history today; replicating *from* it means a damaged primary produces a damaged
   secondary, and the second copy inherits the first copy's blind spots. Fan-out gives two
   independently-written repositories whose only shared component is the source filesystem.
1. **B2 is the only candidate in the field that is simultaneously cheap at our size, has no
   minimum retention period to punish `forget`, charges nothing per API call, offers a
   genuine no-delete credential that restic explicitly supports, and has an EU region.**
   $0.14/month at 30 GB, $0.63/month at 100 GB (§2.1). Wasabi's 1 TB minimum charge makes it
   $7.99 regardless (§2.2); Hetzner's floor is €3.20 (§2.5); and restic's docs name B2's
   S3-compatible path as the recommended one
   ([030_preparing_a_new_repo.rst:456](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst)).

**The shape in NixOS is a destination × job cross product you write yourself.** There is **no
established community pattern, no wrapper module and no flake to adopt** — nix-community
publishes nothing restic-related, and what exists in the wild is the same idiom reinvented
across dozens of personal configs (§3.4). Every option in `services.restic.backups` is
per-job, the module's `initialize` can only run a bare `restic init`, and `restic copy` support
has never even been proposed upstream (§3.5). So this is a dozen lines of `lib.mapAttrs'` over
a `destinations` attrset in `modules/nixos/profiles/backup.nix` (§3.6) — and the existing
`reportJobs`/`resticStamp` plumbing already keys on job name with the label `restic_job`, so it
extends rather than fights the current design. Note that the one active upstream rewrite,
[PR #492460](https://github.com/NixOS/nixpkgs/pull/492460), restructures the schema on the
*opposite* axis (many jobs → one repository) and would make a destinations × jobs product more
verbose, not less; do not wait for it.

**What would change the recommendation:**

- **If Hetzner Storage Box's flat €3.20/TB is worth more than B2's immutability**, take
  Hetzner instead and accept that the fleet then has two sftp-over-SSH destinations with no
  append-only story anywhere. That is a defensible choice for a fleet whose threat model is
  "a disk dies", not "a host is compromised". It is the wrong choice if the Immich library
  matters; see the risk callout.
- **If a dry run shows `forget` fails against a no-delete B2 key**, the append-only half of
  the recommendation collapses and B2 becomes just a cheap second bucket. This is the one
  load-bearing claim here that no primary source settles (§5.4) — test it before committing.
- **If a cheap EU VPS with disk is acceptable**, `services.restic.server.appendOnly = true` beats
  B2 outright: it is restic's own first-party append-only mode, denied server-side on every
  write, and nixpkgs ships the module (§5.4). That is a different decision — it buys a machine
  — but it is the only option here that gives real immutability *and* keeps `prune` workable
  (from a separate trusted client). B2 wins today on cost and on having nothing to operate.
- **If the plan is ever to run `restic copy` between the two repos**, the second repository
  **must** be created once by hand with
  `restic init --from-repo <rsync.net> --copy-chunker-params` *before* the module's
  `initialize` gets a chance to run a plain `init`. That decision is irreversible: "it is not
  possible to change the chunker parameters of an existing repository"
  ([045_working_with_repos.rst:308](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)).
  Doing it costs nothing now and cannot be done later, so do it even though the verdict is
  fan-out.

## Version ground truth

Verified by evaluating **this repo's own host configuration**, not by reading a `package.nix`
at an input rev:

| Thing | Version | How established |
|---|---|---|
| `restic` rk1b builds | **0.19.1** | `nix eval .#nixosConfigurations.rk1b.config.services.restic.backups.daily.package.version` |
| restic 0.19.1 release date | 2026-07-05 | [CHANGELOG.md](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md) table of contents |
| nixpkgs rev this flake pins | `7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f` (2026-11-26) | `flake.lock`, node `nixpkgs_7` |
| nixpkgs restic module read at | that rev | `nixos/modules/services/backup/restic.nix`, 541 lines |

All restic doc quotations below are from the **`v0.19.1` tag of restic's own repo**, not from
`restic.readthedocs.io/en/stable`, so they match the binary the fleet actually runs. Where a
behaviour changed recently I say in which release.

Prices were read on **2026-10-05** and pricing pages change; every figure carries its
currency and its source URL.

______________________________________________________________________

## 1. Fan-out vs replication

### 1.1 restic has no native fan-out, and will not get one

Two feature requests cover this and both are settled:

- **[#265](https://github.com/restic/restic/issues/265)** "backup to multiple destinations at
  the same time" (2015-08-17) — **closed** 2020-10-04 by maintainer MichaelEischer:
  "Closing this as the new `copy` command can be used to sync snapshots between repositories,
  which also verifies the snapshot integrity while doing so. To clean up snapshots it's e.g.
  possible to just run `forget --keep-something 42 ...` for both repositories."
  ([comment](https://github.com/restic/restic/issues/265#issuecomment-703296687))
- **[#4432](https://github.com/restic/restic/issues/4432)** "Backup to multiple repositories in
  one backup run of restic" (2023-08-03) — **still open**, labelled `state: need direction`,
  with MichaelEischer's 2024-07-06 assessment: "Native support in restic would be rather
  complex to implement as the data in each repository can vary wildly. Restic would also have
  to separately load the index for each destination repository, which would significantly
  increase the memory usage."
- **[#679](https://github.com/restic/restic/issues/679)** (multi-repository endpoints for
  HA, 2016) is closed.

So fan-out means *N invocations*, by construction. There is no flag to add.

### 1.2 What restic's docs say about `copy`

The `copy` command exists and is the maintainer-endorsed replication route. The docs carry
two `.. important::` blocks, and both are the whole story:

> This process will have to both download (read) and upload (write) the entire snapshot(s)
> due to the different encryption keys used in the source and destination repository. This
> *may incur higher bandwidth usage and costs* than expected during normal backup runs.

> The copying process does not re-chunk files, which may break deduplication between the
> files copied and files already stored in the destination repository. This means that copied
> files, which existed in both the source and destination repository, *may occupy up to twice
> their space* in the destination repository.

— [045_working_with_repos.rst:238–247](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)

**Where the data physically moves.** The copying process runs on whichever machine invokes
`restic copy`. It opens *both* repositories (`--from-repo` for the source), reads pack files
out of the source, decrypts them with the source key, re-encrypts with the destination key,
and uploads. Nothing happens provider-to-provider. For this fleet that means a
rsync.net→B2 copy pulls 25.67 GB down to rk1b (or to whichever host runs it) and pushes
25.67 GB back out — rsync.net charges no egress
([pricing.html](https://www.rsync.net/pricing.html)) and B2 charges no ingress, so the money
cost is zero and the cost is entirely time and the host's link. Measured ~40 MB/s upload on
rk1b's residential uplink makes even a full 25.67 GB seed tolerable (~11 min of upload,
downlink unmeasured), so bandwidth is *not* the argument against copy here — derivation is
(verdict §2).

Other `copy` facts worth having:

- **It is resumable but coarsely.** "If `copy` is aborted, `copy` will resume the interrupted
  copying when it is run again. It's possible that up to 10 minutes of progress can be lost
  because the repository index is only updated from time to time."
- **Already-copied snapshots are skipped**, silently unless `--verbose` is passed.
- **Same-backend credential collision.** "In case the source and destination repository use
  the same backend, the configuration options and environment variables used to configure the
  backend may apply to both repositories – for example it might not be possible to specify
  different accounts for the source and destination repository." The documented escape is the
  rclone backend with named remotes. This bites exactly the shape "copy rsync.net → Hetzner",
  both sftp.
- **0.19.0 made `copy` cheaper on per-request-priced backends.**
  [Enh #5453](https://github.com/restic/restic/issues/5453) — "The `copy` command used to copy
  snapshots one at a time, even when doing so produced pack files smaller than the target pack
  size. This led to many small files when copying small incremental snapshots. The `copy`
  command now copies multiple snapshots together so that small pack files are avoided where
  possible." If you benchmarked `copy` on an older restic and found it produced pack-file
  litter, that is fixed as of 0.19.0 (2026-06-09) — and the fleet runs 0.19.1.

### 1.3 `--copy-chunker-params` and `init --from-repo`: what actually breaks

restic splits files with content-defined chunking using a Rabin fingerprint, and the
polynomial is **per-repository and random**:

> An irreducible polynomial is selected at random and saved in the file `config` when a
> repository is initialized, so that watermark attacks are much harder.

— [design.rst:700](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst)

The polynomial is literally a field in the repo config: `"chunker_polynomial": "25b468838dcb75"`
([design.rst:66](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst)). Two
independently-`init`ed repositories therefore cut the *same file* into *different chunks*.

**Does `copy` re-chunk?** No — and that is precisely the problem. "The copying process does
not re-chunk files." Copy moves blobs as they exist in the source. So when chunker params
differ, the blobs arriving from the source cannot match the blobs the destination's own
`backup` runs produced from the same bytes, and both sets are stored: "may occupy up to twice
their space in the destination repository."

**The fix, and its one-shot nature:**

```console
$ restic -r /srv/restic-repo-copy init --from-repo /srv/restic-repo --copy-chunker-params
```

> Note that it is not possible to change the chunker parameters of an existing repository.

— [045_working_with_repos.rst:288–308](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)

So the chunker-param decision is made at `init` time, once, forever. **This is why the verdict
says to create the B2 repo with `--copy-chunker-params` even though the plan is fan-out:**
matched params cost nothing in a fan-out world (dedup is computed *within* a repository, and
the polynomial choice does not affect dedup quality), and they are the only thing that keeps
the copy route available later.

One inference, flagged as such: because the polynomial exists to harden against watermark
attacks, two repos sharing a polynomial share that one secret. The polynomial still lives
inside the encrypted `config` file in both repos, so an attacker without a repo key learns
nothing — but the *blast radius* of a leaked polynomial doubles. **No primary source discusses
this trade-off**; restic's docs present `--copy-chunker-params` as unqualified good practice
for copy destinations. Treat the concern as theoretical.

### 1.4 The third option the docs do not foreground: `rclone sync` of the repository

Both restic's author and a maintainer recommend this, and it is worth stating because it is
materially different from `copy`. fd0 (Alexander Neumann), in #265:

> I'd like to investigate first if this can be achieved with just rclone. Make a backup to one
> backend (e.g. local), then synchronize the changes to all the others. Then you'll end up with
> identical snapshots and data. When you sync file deletions, too, then you can run `forget`
> and `prune` on your local backend and sync the changes back to the other backends. It's a
> two-step process, but it'll keep restic much simpler, and I can't see any downsides...

— [#265#issuecomment-379495889](https://github.com/restic/restic/issues/265#issuecomment-379495889),
and the same approach again from konidev20 in
[#4432](https://github.com/restic/restic/issues/4432#issuecomment-1666565856), noting
"restic has a standard repository structure for all storage backends."

This is byte-level replication of the repository directory. It cannot lose dedup (same repo,
same polynomial), it needs no second repo password, and it transfers only changed files.
Its costs are the mirror image of `copy`'s:

- **It replicates deletions.** A `forget --prune` on the primary propagates to the mirror on
  the next sync — which is exactly the ransomware failure mode §5.5 is about. `copy` never
  deletes anything at the destination.
- **It verifies nothing.** `copy` "also verifies the snapshot integrity while doing so"
  (MichaelEischer, above); `rclone sync` compares sizes and hashes of opaque files.
- **It needs a machine with credentials for both ends**, which is the same credential-blast-radius
  problem as fan-out, without fan-out's independence benefit.

Not recommended here, but it is the right answer for the different problem "mirror an existing
repo verbatim to a second provider, cheaply, without touching restic."

### 1.5 Fan-out, concretely

For N destinations, fan-out is N complete `restic backup` runs over the same paths. The
properties that matter:

| | Fan-out (N × `backup`) | `copy` primary→secondary | `rclone sync` of repo dir |
|---|---|---|---|
| Upload from host per `d` bytes of delta | `N·d` | `d` (then `d` down + `d` up elsewhere) | `d` |
| Reads source filesystem | N times | once | once |
| Secondary independent of primary's integrity | **yes** | no | no |
| Dedup across destinations | n/a (per-repo) | needs `--copy-chunker-params` | identical by construction |
| Deletions propagate | no (each repo forgotten separately) | no | **yes** |
| Needs both credentials on one machine | yes | yes | yes |
| Per-destination retention policy | **yes** | yes | no (mirror) |
| Snapshot integrity verified on write | yes (restic verifies before upload) | yes | no |

That "reads source filesystem N times" row is the real operational cost of fan-out and the
reason §4 is about scheduling. On rk1b it means reading ~1.1 GB of Immich originals twice a
night instead of once; restic's own mitigation for I/O cost is `--no-scan` (skip the progress
estimate's extra I/O,
[047_tuning_parameters.rst](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst)),
not deduplicating the read.

______________________________________________________________________

## 2. Backends, their real cost at our size, and their restic-specific gotchas

All prices read **2026-10-05** from the provider's own pages. 30 GB and 100 GB figures are
derived from the published per-GB rates, which is itself a minor source of error — where the
provider does not state its TB→GB divisor I say so.

### 2.1 Backblaze B2 — recommended

| | |
|---|---|
| Storage | **$6.95 / TB / month**, "billed monthly, based on the amount of data stored per byte-hour"; first 10 GB always free ([pricing](https://www.backblaze.com/cloud-storage/pricing)) |
| **30 GB / 100 GB** | **$0.14 / $0.63 per month** (derived: `(GB − 10) × 0.00695`, assuming 1 TB = 1000 GB — Backblaze does not state the divisor) |
| Egress | free up to 3× average monthly storage, then $0.01/GB |
| Per-request | "**Class A, B, and C API calls are free** for pay-as-you-go customers" ([transaction pricing](https://www.backblaze.com/cloud-storage/transaction-pricing)) |
| Minimum retention | "**No minimum storage duration fees**", no minimum file size fees |
| Object lock | **compliance and governance modes**, plus legal hold ([docs](https://www.backblaze.com/docs/cloud-storage-enable-object-lock-with-the-native-api)) |
| EU residency | **EU Central = Amsterdam, NL**; "your data storage costs do not change" by region, and region **cannot be changed after account creation** ([data regions](https://www.backblaze.com/docs/cloud-storage-data-regions)) |
| Rate limits | no published RPS; the S3-compatible API documents HTTP **429 "Too Many Requests — Your request exceeded the API rate limit"** ([S3 API intro](https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api)) |

**restic-specific gotchas, all from restic's own docs:**

1. **Use the S3 API, not the native B2 backend.** restic's docs carry a `.. warning::`:
   "Due to issues with error handling in the current B2 library that restic uses, the
   recommended way to utilize Backblaze B2 is by using its S3-compatible API… This is expected
   to work better than using the Backblaze B2 backend directly."
   ([030:456](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst))
1. **Deletes become hides, so a lifecycle rule is mandatory or the bucket grows forever.**
   Same warning block: "Different from the B2 backend, restic's S3 backend will only hide no
   longer necessary files. By default, Backblaze B2 retains all of the different versions of
   the files and 'hides' the older versions. Thus, to free space occupied by hidden files, it
   is **recommended** to use the B2 lifecycle 'Keep only the last version of the file'."
   **Without this, `forget --prune` reclaims nothing and the bill climbs anyway.**
1. **The lifecycle rule is also the ransomware dial.** B2's rule fields are
   `fileNamePrefix`, `daysFromHidingToDeleting`, `daysFromUploadingToHiding`,
   `daysFromStartingToCancelingUnfinishedLargeFiles`, and the presets include "Keep only the
   last version of the file" (hides after one day, then deletes) and "**Keep prior versions
   for this number of days**"; `daysFromHidingToDeleting` accepts "null or numbers one and
   greater" ([lifecycle rules](https://www.backblaze.com/docs/cloud-storage-lifecycle-rules)).
   The preset restic's docs name gives a ~1-day recovery window. **Use the other preset at 30
   days instead** — same space reclamation, 30× the window (§5.4).
1. **Permanent deletion costs double the transactions.**
   [Bugfix #3161](https://github.com/restic/restic/issues/3161) (restic 0.15.0): restic now
   "delete[s] all versions of files, which doubles the amount of Class B transactions necessary
   to delete files, but assures that no file versions are left behind." Free on B2, so this is
   only a concern on providers that bill per request.
1. **Historical EU endpoint string unverified.** The EU Central region is confirmed
   (Amsterdam); the commonly-quoted `s3.eu-central-003.backblazeb2.com` form appears nowhere on
   a Backblaze page I read — their docs only show the pattern `s3.<region>.backblazeb2.com`
   with `us-west-004`/`us-east-005` as examples. **UNVERIFIED-SECONDARY.** Read the real
   endpoint off the bucket's own details page in the B2 console rather than guessing it.

### 2.2 Wasabi — rejected on the minimum charge and the minimum retention

Named explicitly in restic's docs as a supported S3-compatible target, with a pointer to
their service-URL table ([030:347](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst)).
The pricing disqualifies it at our size:

- **$7.99 / TB / month** for US & Europe regions, which Wasabi's own FAQ expands as
  "$.0078 GB/mo" — i.e. they divide by 1024.
- **"minimum monthly charge associated with 1 TB of active storage… If you store less than
  1 TB of active storage in your account, you will still be charged for 1 TB."** So
  **30 GB and 100 GB both cost $7.99/month** — an effective $0.27/GB at 30 GB, ~38× B2.
- **90-day minimum storage duration** on pay-as-you-go, with early deletion charged as
  "Timed Deleted Storage… equal to the storage charge for the remaining days". This is a direct
  tax on `restic forget --prune`: every pack file prune removes before it is 90 days old is
  still billed. A `--keep-daily 7` policy on Wasabi pays for 90 days of everything it deletes.
- Egress free "when monthly egress data transfer is less than or equal to your active storage
  volume" — which, with a 1 TB billed floor but 30 GB actual, is a tight ratio for
  `check --read-data`.
- EU regions: eu-west-1/eu-west-3 (UK), eu-west-2 (Paris), eu-central-1 (Amsterdam),
  eu-central-2 (Frankfurt), eu-south-1 (Milan)
  ([storage regions](https://wasabi.com/company/storage-regions)).
- Sources: [pricing](https://wasabi.com/pricing),
  [pricing FAQs](https://wasabi.com/pricing/pricing-faqs). **Unconfirmed:** which regions carry
  the $9.99/TB tier the FAQ also lists; any numeric rate limit (only a qualitative abuse
  clause); and S3 Object Lock support, which Wasabi markets but which I did not confirm on a
  primary page.

### 2.3 Cloudflare R2 — viable runner-up, worse immutability story

- **Standard: $0.015/GB-month**; Class A $4.50/M ops, Class B $0.36/M ops; **egress free**.
  **Infrequent Access: $0.01/GB-month**, Class A $9.00/M, Class B $0.90/M, retrieval
  $0.01/GB, and a **30-day minimum storage duration**
  ([pricing](https://developers.cloudflare.com/r2/pricing/)).
- Free tier: 10 GB-month storage, 1M Class A, 10M Class B per month — **Standard only**.
- **30 GB / 100 GB Standard: $0.30 / $1.35 per month** (derived, ops inside the free tier).
- **S3 Object Lock and bucket versioning are not supported.**
  `GetBucketVersioning`/`PutBucketVersioning` are listed as unimplemented and object locking
  is marked unsupported on `PutObject`/`CreateMultipartUpload`
  ([S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/)). R2's own
  **bucket locks** exist instead — "Prevent the deletion and overwriting of objects… for a
  specified period — or indefinitely", up to 1,000 rules, strictest wins, taking precedence
  over lifecycle rules ([bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/)) —
  but with no versioning there is no hide-then-expire middle ground, so a bucket lock that
  protects pack files also **blocks `prune` outright** rather than deferring it.
- Limits that matter to restic: **bucket management ops 50/sec per bucket**, **max 1
  concurrent write per second to the same object key**
  ([limits](https://developers.cloudflare.com/r2/platform/limits/)). restic defaults to 5
  backend connections and never writes the same key twice, so neither should bind; worth
  knowing before raising `-o s3.connections`.
- **EU residency is good**: jurisdictions EU / US / FedRAMP, endpoint
  `https://<ACCOUNT_ID>.<JURISDICTION>.r2.cloudflarestorage.com`, "Jurisdictional Restrictions
  guarantee objects in a bucket are stored within a specific jurisdiction", and the
  jurisdiction cannot be changed once set
  ([data location](https://developers.cloudflare.com/r2/reference/data-location/)).
- **Not named in restic's docs.** It is "an S3-compatible storage service that is not Amazon"
  ([030:316](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst)),
  which means `-o s3.bucket-lookup` and `-o s3.region` may need setting by hand; restic
  defaults `bucket-lookup=auto` → `path` for non-Amazon endpoints and region `us-east-1` if
  unset.

### 2.4 Scaleway Object Storage — the EUR-priced alternative

- **Standard Multi-AZ €0.000022/GB/hour ≈ €0.01606/GB/month**; **One Zone
  €0.000011/GB/hour ≈ €0.00803/GB/month**; Glacier €0.0000035/GB/hour ≈ €0.00254/GB/month.
  **Requests "Included"** (free). Egress **75 GB free every month**, then €0.01/GB; intra-regional
  free ([pricing](https://www.scaleway.com/en/pricing/storage/)).
- **30 GB / 100 GB:** Multi-AZ **€0.48 / €1.61**; One Zone **€0.24 / €0.80** (derived, ex-VAT).
- **No early-delete penalty documented.** Billing is hourly and Glacier's page says "no minimum
  commitments". The 90-day rule that exists is a *lifecycle-transition* constraint, not a
  deletion one: "Transition rules created or updated after April 1, 2026 must observe… Objects
  must be stored for at least 90 days before transitioning to Glacier"
  ([lifecycle rules](https://www.scaleway.com/en/docs/object-storage/how-to/manage-lifecycle-rules/)).
- **Object lock in compliance and governance modes**, with per-object and bucket-default
  retention; versioning supported. Compliance mode: "it is only possible to overwrite it or
  delete an object once the Object Lock expires or upon deleting your Scaleway account"
  ([concepts](https://www.scaleway.com/en/docs/object-storage/concepts/)).
- EU regions fr-par, nl-ams, pl-waw, it-mil; Multi-AZ in PAR/AMS/WAW.
- **The free-tier claim is a trap**: the 750 GB allowance is "across the Standard Multi-AZ and
  Standard One Zone classes… **for 90 days**" for new users, not a perpetual monthly allowance
  ([FAQ](https://www.scaleway.com/en/docs/object-storage/faq/)).
- **A PUT rate limit exists but its value is unpublished:** "Scaleway Object Storage applies a
  rate limit on PUT operations for safety reasons", surfacing as `S3 error: Too Many Requests`
  ([troubleshooting](https://www.scaleway.com/en/docs/storage/object/troubleshooting/request-rate-error/)).
  For a backend restic hammers with pack uploads that is the one unknown worth a dry run.
- Not named in restic's docs; generic S3-compatible, same caveats as R2.

**Why not Scaleway, given the EU-residency preference and EUR billing?** Only cost: €1.61/month
Multi-AZ at 100 GB versus $0.63 at B2, no free-request advantage over B2 (both free), and B2's
hide-then-expire semantics give the append-only window Scaleway's compliance lock cannot
(compliance lock and `prune` are mutually exclusive, §5.4). Scaleway is the right answer if EU
residency is ever upgraded from "mild plus" to a requirement and Amsterdam-via-a-US-company
stops counting.

### 2.5 Hetzner Storage Box — closest to the existing mechanism, no immutability

| | |
|---|---|
| Plans (net, 0% VAT) | **BX11 1 TB €3.20/mo**, BX21 5 TB €10.90, BX31 10 TB €20.80, BX41 20 TB €40.60 |
| **30 GB / 100 GB** | **€3.20 / €3.20** — nothing smaller than 1 TB exists |
| Traffic | **unlimited**, no per-request or per-transaction charges |
| Protocols | "FTP, FTPS, SFTP, SCP, Samba/CIFS, BorgBackup, **Restic**, Rclone, rsync via SSH, HTTPS, WebDAV" — restic named on the product page |
| Locations | Germany (FSN1 Falkenstein), Finland (HEL1 Helsinki) |
| Object lock / versioning | **none** |

Prices are not in the product page's HTML; they load client-side. They were read from
**Hetzner's own live price feed**, `https://www.hetzner.com/_resources/app/data/app/live_data_prices.json`,
matched against the `product-key` attributes on
[the product page](https://www.hetzner.com/storage/storage-box/) (BX11→`ROBOT_1333` …
BX41→`ROBOT_1336`). VAT is applied client-side per country; the figures above are net.

**The port gotcha, confirmed on Hetzner's own docs page:** **SSH is on port 23, not 22.**
"Port 22 does not support interactive SSH access." Port 23 is the "extended SSH service" but
offers **no full shell and no pipes or redirects**; individual commands can be run.
"BorgBackup, rsync, scp, sftp, dd, rclone" all use port 23, and **restic is "natively
supported with the SFTP backend"** over it. SSH keys must be in normal OpenSSH format, not
RFC4716 ([access via SSH/rsync/BorgBackup](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/)).

For this fleet that means the existing `sftpCommand` idiom in
`modules/nixos/profiles/backup.nix` transfers almost verbatim — add `-p 23`. restic's sftp
backend never needs a remote shell: it requests the sftp subsystem via `ssh` and does its own
`Mkdir`/`Chmod` round-trips over the protocol
([internal/backend/sftp/sftp.go](https://github.com/restic/restic/blob/v0.19.1/internal/backend/sftp/sftp.go),
`mkdirAllDataSubdirs`), so the no-shell restriction is not a blocker.

Other restic-relevant facts:

- **10 simultaneous connections per Storage Box account.** restic's default is 5 per backend
  ([047_tuning_parameters.rst](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst)),
  so **two concurrent restic jobs against one Storage Box saturate it** — a direct argument for
  the staggered schedule in §4.4, or for per-job sub-accounts.
- **100 sub-accounts** per box, each scoped to a directory and **settable read-only** — the
  closest thing to append-only here, and not close enough: read-only blocks `backup` too.
- **Snapshots: 10/20/30/40 slots** by plan, manual and automated, but "tracked changes will
  consume storage space from your Storage Box's storage capacity" — so snapshot retention
  eats the 1 TB you paid for.
- **SFTP is the slow protocol.** rest-server's own README states it plainly: "even if you use
  HTTPS transport, the REST protocol should be faster and more scalable, due to some
  inefficiencies of the SFTP protocol (everything needs to be transferred in chunks of 32 KiB
  at most, each packet needs to be acknowledged by the server)"
  ([rest-server README](https://github.com/restic/rest-server#rest-server-vs-sftp)). This
  applies to the existing rsync.net destination too.
- **No inode or file-count limit is stated** on the product page or the docs page. That is
  absence of a documented limit, not a confirmed absence of a limit. **Unconfirmed.**

### 2.6 rsync.net — what we already have

- **Standard tier: 1.5 ¢/GB/month with an 800 GB minimum order**, 7 daily ZFS snapshots
  included ([pricing.html](https://www.rsync.net/pricing.html)).
- **Discounted "restic account": $0.01/GB/month, 200 GB minimum, paid annually**, "rsync.net
  accounts have full support for restic" — and, critically, "**Free ZFS filesystem snapshots
  are not included** since you'll be doing versioning and retention with restic"
  ([products/restic.html](https://www.rsync.net/products/restic.html)). The same structure
  exists for borg ([products/borg.html](https://www.rsync.net/products/borg.html)).
- **No egress charges, no per-request model** (SSH/SFTP/rsync only). No published rate limit.
- **Immutability is available but tier-dependent.** Their restic page advertises "point-in-time
  snapshots that are immutable", the ability to "set your account to be immutable (read-only)
  and accessible only by SSH key", append-only mode support, and "full control over your
  authorized_keys file to restrict IP and command access" — while the same page excludes free
  ZFS snapshots from the discounted restic tier. **Which of these the fleet's account actually
  has cannot be settled from a public page.**
- **Locations:** Fremont CA, Denver CO, **Zurich (Equinix ZH4, routing via init7.net)**, Hong
  Kong. "There is no difference in cost between our locations and you may migrate your account
  from one location to another" ([locations](https://www.rsync.net/products/locations.html)).
  **Zurich is Switzerland, not the EU** — fine for latency and Swiss data-protection law, not
  for an EU-only residency requirement.
- **The fleet's 112 GB soft quota matches none of the published minimums** (800 GB standard,
  200 GB restic/borg). The account predates or sits outside the published tiers; **no primary
  source settles what it is or what it costs.** Check the invoice, not this document.

### 2.7 Local / USB

Not a *destination* in the 3-2-1 sense for this fleet, but worth one line of primary-source
hygiene: restic's local backend defaults to **2** connections, not 5
([047_tuning_parameters.rst](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst)),
and larger `--pack-size` "can also improve the backup speed for a repository stored on a local
HDD". A local repository on sawtoothShark would be the cheapest way to satisfy the "2 media
types" half of 3-2-1 and the only one that makes `check --read-data` free.

### 2.8 The comparison, at our sizes

| Backend | 30 GB | 100 GB | Per-request | Min retention | Append-only primitive | EU |
|---|---|---|---|---|---|---|
| **Backblaze B2** (S3 API) | **$0.14** | **$0.63** | free (A/B/C) | **none** | no-delete key + versioning + lifecycle | Amsterdam |
| Cloudflare R2 Standard | $0.30 | $1.35 | free tier covers us | none | bucket lock (blocks prune) | EU jurisdiction |
| Cloudflare R2 IA | $0.30 | $1.00 | 2× Standard rates | **30 d** | as above | as above |
| Scaleway Multi-AZ | €0.48 | €1.61 | included | none | object lock (blocks prune) | PAR/AMS/WAW/MIL |
| Scaleway One Zone | €0.24 | €0.80 | included | none | as above | as above |
| Wasabi (EU) | $7.99 | $7.99 | free | **90 d** | unconfirmed | 6 regions |
| Hetzner BX11 | €3.20 | €3.20 | none | none (flat) | **none** | DE / FI |
| rsync.net restic tier | $2.00 | $2.00 | none | none | ZFS/append-only, tier-dependent | CH (not EU) |

______________________________________________________________________

## 3. NixOS: what the module gives you, and what you have to write

### 3.1 Everything is per-job. There is no global.

Read at nixpkgs rev `7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f`,
`nixos/modules/services/backup/restic.nix` (541 lines). The entire option surface is
`services.restic.backups = mkOption { type = attrsOf (submodule …) }` — **there is no
`services.restic.<global>` anything.** Every one of `repository`, `repositoryFile`,
`passwordFile`, `environmentFile`, `extraOptions`, `extraBackupArgs`, `pruneOpts`,
`checkOpts`, `runCheck`, `paths`, `exclude`, `timerConfig`, `user`, `initialize`,
`backupPrepareCommand`, `backupCleanupCommand`, `dynamicFilesFrom`, `rcloneConfig`,
`createWrapper`, `progressFps`, `inhibitsSleep` and `package` is a per-job attribute.

Consequences for a destinations × jobs cross product:

- **A "job" in the module is really a (paths, destination, policy) triple.** Two destinations
  for the same paths is two entries in the attrset, with everything duplicated. There is no
  sharing mechanism in the module; the sharing has to happen in *your* Nix.
- **Three mutually-exclusive ways to name the repo**, enforced by an assertion:
  "exactly one of repository, repositoryFile or environmentFile should be set", plus
  "passwordFile or environmentFile must be set". So an S3 destination can put
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` *and* `RESTIC_REPOSITORY` in one
  `environmentFile` — which is the natural fit for a sops template — or keep
  `repositoryFile` + `environmentFile` for the credentials only.

### 3.2 The generated unit, step by step

`systemd.services.restic-backups-<name>`, `Type = "oneshot"`:

- **`environment`** — `RESTIC_CACHE_DIR = "/var/cache/restic-backups-${name}"`,
  `RESTIC_PASSWORD_FILE`, `RESTIC_REPOSITORY`, `RESTIC_REPOSITORY_FILE`, plus `RCLONE_*`
  mappings and `RESTIC_PROGRESS_FPS`.
- **`serviceConfig`** — `CacheDirectory = "restic-backups-${name}"`,
  `CacheDirectoryMode = "0700"`, `RuntimeDirectory = "restic-backups-${name}"`,
  `PrivateTmp = true`, `User = backup.user` (default `root`), and `EnvironmentFile` when set.
- **`preStart`** (present when `initialize || doBackup || backupPrepareCommand != null`) —
  runs `backupPrepareCommand`, then the initialize probe, then assembles
  `/run/restic-backups-<name>/includes` from `paths` and `dynamicFilesFrom`.
- **`ExecStart`** is a *list*, executed in order:
  1. `restic <extraOptions> backup <extraBackupArgs> [--exclude-file=…] --files-from=…`
  1. if `pruneOpts != []`: `restic <extraOptions> unlock`
  1. if `pruneOpts != []`: `restic <extraOptions> forget --prune <pruneOpts>`
  1. if `runCheck`: `restic <extraOptions> check <checkOpts>`
- **`postStop`** — `backupCleanupCommand`, then removes the includes file.
- `restartIfChanged = false`; `wants`/`after` `network-online.target`;
  `path = [ config.programs.ssh.package ]`.

Five things in there are load-bearing and non-obvious:

1. **`extraOptions` are `-o` extended options and they apply to *every* restic invocation in
   the unit** — backup, unlock, forget, check. That is why this repo's single
   `sftp.command='…'` entry works for the prune step too. It also means **plain flags cannot
   go there**: `--retry-lock 10m`, which is exactly what you want on forget/check when two
   jobs contend, is not an `-o` option and has **no module surface at all**. `extraBackupArgs`
   reaches only `backup`. Getting `--retry-lock` onto the forget step requires overriding
   `systemd.services.restic-backups-<name>.serviceConfig.ExecStart` by hand.
1. **`pruneOpts` silently implies a bare `restic unlock` before every forget.** The module
   emits `restic unlock` unconditionally whenever `pruneOpts` is non-empty. `unlock` without
   `--remove-all` removes only *stale* locks — "The 'unlock' command removes stale locks that
   have been created by other restic processes"
   ([cmd_unlock.go](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_unlock.go)),
   and stale means "timestamps older than 30 minutes" or a dead PID on the same machine
   ([design.rst:628](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst)) — so it is
   safe, but it is a repository *write* the unit performs on every run. On an append-only
   rest-server it still works: "Removing locks works even with repositories served in
   append-only mode from restic's rest-server" (same source).
1. **`initialize` can only run a bare `restic init`.** The preStart body is
   `restic cat config --no-lock > /dev/null || { status=$?; if [ "$status" -eq 10 ]; then restic init; else exit "$status"; fi; }`
   — exit code 10 being "Repository does not exist (since restic 0.17.0)"
   ([075_scripting.rst:164](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst)).
   **There is no way to make `initialize` pass `--from-repo` or `--copy-chunker-params`.** If
   matched chunker params are wanted (§1.3), the second repository must be `init`ed by hand
   first, and `initialize = true` then finds it and does nothing.
1. **`runCheck` defaults to `checkOpts != []`.** This repo sets `pruneOpts` but never
   `checkOpts`, so **neither live job has ever run `restic check`.** That is a real finding
   about the current state, not a hypothetical.
1. **`createWrapper = true` (the default) puts `restic-<name>` on the system PATH**, with the
   job's environment pre-set. With per-destination jobs that is free ergonomics: `restic-daily`
   and `restic-daily-b2` as two ready-made CLIs for restores and manual checks, no
   `RESTIC_REPOSITORY` juggling.

Also note what the timer does: `systemd.timers.restic-backups-<name>` with
`wantedBy = [ "timers.target" ]`, `inherit (backup) timerConfig`, and
`unitConfig.X-OnlyManualStart = true`. `timerConfig` defaults to
`{ OnCalendar = "daily"; Persistent = true; }` and **`null` means no timer at all** — which
is the clean way to express "this destination is driven by another unit", e.g. a copy job or a
weekly deep check.

### 3.3 Cache handling: per-job, hardcoded, and that is fine

`RESTIC_CACHE_DIR` is `/var/cache/restic-backups-${name}` with systemd `CacheDirectory`
managing it at mode 0700. It is **not an option** — changing it means overriding the unit's
`environment`.

Whether sharing one cache between jobs pointing at *different* repos is safe is settled by
restic's own design doc, and the answer is yes:

> Each repository has its own cache sub-directory, consisting of the repository ID which is
> chosen at `init`. All cache directories for different repositories are independent of each
> other.

— [cache.rst](https://github.com/restic/restic/blob/v0.19.1/doc/cache.rst)

So a shared `RESTIC_CACHE_DIR` would hold one subdirectory per repository ID and the two jobs
would not collide. **But there is no reason to do it**: the cache holds snapshot, index and
data (metadata) files keyed by repo ID, so two repos share no cache entries even when backing
up identical source data — different repo IDs, different index content, different pack IDs.
Sharing buys nothing and costs you systemd's per-unit `CacheDirectory` ownership. **Leave the
default.** The one thing worth knowing is the disk cost: the cache is sized by repository
*metadata*, and with fan-out you now pay it N times under `/var/cache` — on rk1b, whose root
is a 2 GB tmpfs with data on the NVMe at `/var/cache`, confirm `/var/cache` is on the NVMe
before adding a second job.

Related, and easy to miss: **`restic check` builds its own temporary cache by default.** "By
default, check creates a new temporary cache directory to verify that the data stored in the
repository is intact. To reuse the existing cache, you can use the `--with-cache` flag… If the
cache directory is not explicitly set, then `check` creates its temporary cache directory in
the temporary directory"
([045:410](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)).
The unit sets `PrivateTmp = true` and `RESTIC_CACHE_DIR` *is* explicitly set, so check uses
`/var/cache/restic-backups-<name>` — meaning a check will re-download the whole index into the
job's cache unless `checkOpts = [ "--with-cache" ]`. That flag is the module's own documented
example for `checkOpts`.

### 3.4 Established community patterns: three reinvented idioms, no shared one

**Said plainly: there is no established pattern, no wrapper module, and no flake to adopt.**
nix-community publishes **nothing** restic-related (`search/repositories?q=org:nix-community+restic`
→ 0 results); srvos, clan-core and nixos-facter contain no restic code; repo-name searches for
`nixos-restic`, `restic-module`, `restic-flake` turn up only zero-star personal repos. What
exists instead is the *same three idioms* independently reinvented across dozens of personal
configs. Our job is to pick one knowingly, not to find the blessed one.

**Idiom A — N independent jobs, one per (source × destination). Dominant, and what the verdict
recommends.** Everyone writes their own `mapAttrs'` / `listToAttrs` / `genAttrs` wrapper over
`services.restic.backups`. The configs worth actually reading:

- [madslundt/HomeCompute](https://github.com/madslundt/HomeCompute), `modules/nixos/backups.nix` —
  the cleanest explicit cross product: a `destinations` attrset × a `sources` attrset where each
  source declares `destinations = [ … ]`, `lib.concatMap` over both, job names
  `homecompute-<source>-<dest>`. It additionally generates a **second job per pair** with
  `paths = []; pruneOpts = []; runCheck = true;` on a weekly timer — the module-native way to
  get a check that is not welded to the backup unit.
- [darkone-linux/darkone-nixos-framework](https://github.com/darkone-linux/darkone-nixos-framework),
  `modules/service/restic.nix` — `lib.imap0` over `targets × categories` into `listToAttrs` of
  `"${category}-${target.name}"`, and it **staggers the timers by target index** (`shiftHour baseTime idx`) specifically so two destinations cannot collide. Also wraps each unit in an
  `ExecCondition` reachability probe so an unreachable destination *skips* rather than fails —
  directly relevant to a residential-uplink host.
- [kleinbem/nix-presets](https://github.com/kleinbem/nix-presets),
  `nixosModules/backup-engine/default.nix` — a `destinations` submodule whose own comment states
  the fan-out rationale: one independent repo per destination, so "one provider being down never
  blocks the other".
- [ibizaman/selfhostblocks](https://github.com/ibizaman/selfhostblocks), `modules/blocks/restic.nix` —
  job keys are `"${name}_${repoSlugName repository.path}"`, i.e. the schema is already built
  around one unit per (instance, repo) pair. The closest thing to a reusable abstraction in the
  wild.
- Others in the same shape, each with its own sops/secret plumbing per destination:
  [nix-forge/nix-conf](https://github.com/nix-forge/nix-conf) (`resticJob = name: destination:`,
  with `pruneOpts = [ ]` on purpose because pruning is owned by a separate administrator),
  [Swarsel/.dotfiles](https://github.com/Swarsel/.dotfiles),
  [SebastianStork/nixos-config](https://github.com/SebastianStork/nixos-config),
  [NovaViper/NixConfig](https://github.com/NovaViper/NixConfig).

**Idiom B — module for destination 1, hand-rolled `restic copy` unit for destination 2.** The
notable one is [joaovl5/\_nix](https://github.com/joaovl5/_nix),
`lib/units/_backup/rendering.nix`: destinations are *roles* `A`, `B`, …; the module renders
`services.restic.backups` for role A only, then generates
`backup_promote_<item>_to_<role>` oneshots that run
`restic --repo <B> init --from-repo <A> --copy-chunker-params` (guarded by a `--no-lock cat config` probe) followed by `restic copy --from-repo <A>`, plus separate
`backup_forget_<item>_on_<role>` units. **It is the only config I found that handles
`--copy-chunker-params` correctly**, which is itself evidence for how easy §1.3's trap is to
fall into. [MichaelAug/server-config](https://github.com/MichaelAug/server-config)
(`modules/backups/hdd-restic-backup.nix`) does the simple version and carries its own warning
in a comment: "restic copy does not prune old generations, nothing handles this for now" —
the §1.5 "deletions do not propagate" row, discovered the hard way.

**Idiom C — rclone the raw repository objects.**
[geggo98/dotfiles](https://github.com/geggo98/dotfiles), `modules/nixos-backup-copy.nix`, R2 →
Dropbox from a VPS, with the best-argued rationale of any config here: `restic copy` decrypts
and re-encrypts, so it needs the **repository password on the internet-facing host**, whereas
rclone moves ciphertext verbatim and the host needs only a read-only credential. It mitigates
§1.4's "verifies nothing" objection with a verify-then-copy unit that checks pack filenames
against their SHA-256 content hash *without* the password. One person's config, but a genuinely
good idea.

**What nobody does:** `lib.cartesianProduct` with `services.restic.backups` has **zero** hits in
GitHub code search, and no config overrides `RESTIC_CACHE_DIR` to *share* a cache between jobs.

### 3.5 Upstream is moving — on the other axis

The module is actively being reworked, and knowing the direction matters before we build on it:

- **[PR #492460](https://github.com/NixOS/nixpkgs/pull/492460) "nixos/restic: Rewrite module to
  be more flexible"** (provokateurin, opened 2026-02-20, **open**, +345/−483). It restructures
  the schema to **`services.restic.backups.<repository>.jobs.<job>`** — repository becomes the
  *outer* level, carrying `repository`/`repositoryFile`/`passwordFile`/`package`, with N jobs
  under it each having its own `backup`/`forget`/`prune`/`check` enables and `timerConfig`.
  Units become `restic-backups-<repo>-<job>`, and `RESTIC_CACHE_DIR` becomes
  `restic-backups-<repositoryName>` — **shared across jobs within one repository, still never
  across repositories.** The author's own caveat is in the PR body: "This rewrite is not done, I
  only implemented the minimal changes that are needed to support my setup", with tests, docs
  and release notes all unchecked, and no review comments.
  **Note the axis: it solves many-jobs → one-repo, the inverse of our problem.** It makes a
  destinations × jobs product *more* verbose, not less, because the destination moves up a
  level. It adds no `copy` support.
- **[#412106](https://github.com/NixOS/nixpkgs/issues/412106)** "Run prune and check in separate
  systemd services" (2025-05-29, open) is the canonical upstream confirmation that duplicating
  job entries is the accepted workaround — provokateurin,
  [2025-07-12](https://github.com/NixOS/nixpkgs/issues/412106#issuecomment-3065885938): "What I
  did for now is create two services.restic.backups instances and have one with backup+prune and
  one with only check (and different timerConfig to avoid locks). It works, but it's not pretty
  at all."
- **[#456723](https://github.com/NixOS/nixpkgs/issues/456723)** "group backups by repository"
  (2025-10-29, open) — several jobs into one repo, wanting prune/check to run once at the end.
  The reporter's workaround is a dummy backup job that backs up nothing and only prunes, with an
  offset timer. That is the pattern we would want for the *shared* rsync.net repo.
- **[#465973](https://github.com/NixOS/nixpkgs/issues/465973)** "should better scope the `forget`
  command" (2025-11-28, open) — `forget` with `--keep*` applies to every snapshot in the repo,
  grouped only by host and path. **This is live today**: `daily` and `telemetry` share one
  rsync.net repo and each runs its own `forget --prune` with a different policy.
- **`--retry-lock` has an open issue and an open fix, both stalled.**
  [#468191](https://github.com/NixOS/nixpkgs/issues/468191) "Need `restic` module `extraForget`
  options" (2025-12-05, open) reports exactly §3.2 note 1: `--retry-lock 48h` in
  `extraBackupArgs` dropped failure rates a lot, but does not reach the module's `unlock` and
  `forget` invocations, and `extraOptions` cannot carry it because the module prefixes each entry
  with `-o `. [PR #453881](https://github.com/NixOS/nixpkgs/pull/453881) "allow passing global
  flags to the restic binary" (2025-10-20, open) adds the `extraOpts` that would fix it and has
  sat unmerged for roughly a year with a passing `nixpkgs-review` and no maintainer review. So
  the gap is known, acknowledged and unfixed — plan around it, do not wait for it.
- **[#267690](https://github.com/NixOS/nixpkgs/issues/267690)** "Restic doesn't break stale
  locks" (2023-11-15, open) — maintainers robryk and i077 **declined** to auto-`unlock`, citing
  clock skew and PID namespaces, and robryk names our exact hazard: "unless you have two backups
  going to the same repo, thus two services. Or unless there's a different host backing up to
  the same repo." The offered workaround is `backupPrepareCommand` running
  `restic-$YOURBACKUP unlock` — which is reachable from the module today. Note that the
  underlying hazard analysis in that thread cites a `forum.restic.net` post; the *decision* is
  primary (maintainer comments in the issue), the risk reasoning behind it is
  **unverified-secondary**.

**`restic copy` support in the module: never proposed.** `"restic copy"` returns **0 results**
across nixpkgs issues and PRs, and the full commit history of
`nixos/modules/services/backup/restic.nix` contains no commit mentioning `copy`, `from-repo`,
`mirror` or `replicate`. Not rejected — simply never raised. Anyone wanting it writes their own
unit (idiom B).

**The per-job cache is deliberate, and its stated reason is weaker than restic's own docs.**
Commit [`27da11972`](https://github.com/NixOS/nixpkgs/commit/27da11972) (2020-10-04,
"nixos/restic: correct location of cache directory"): "multiple backup services would use the
same cache directory - potentially causing issues with locking, data corruption, etc. The goal
was to ensure, restic uses the correct cache location for a system service - **one cache per
backup specification**, using `/var/cache` as the base directory for it." The problem being
fixed was every unit falling back to `/root/.cache/restic`; restic's own `cache.rst` says that
would have been fine (subdirectory per repository ID, "independent of each other"), so the
"data corruption" rationale is overstated — but the outcome is harmless and §3.3's advice to
leave it alone stands.

### 3.6 The shape to write here

Given all of the above, the pattern that fits this repo — and the one §4 and §5 assume:

- A `destinations` attrset in `modules/nixos/profiles/backup.nix`, each entry carrying its
  `repositoryFile` (or `environmentFile`), `passwordFile`, `extraOptions`, `pruneOpts` and
  `timerConfig`; a `jobs` notion for the existing `daily` / `telemetry` split; and
  `lib.mapAttrs'` producing `services.restic.backups."<job>-<dest>"` — idiom A, named after
  `madslundt/HomeCompute`'s shape.
- **`reportJobs` already keys on job name and the metric label is already `restic_job`**, so the
  existing textfile plumbing (`statusScript`, `resticStamp`) extends by widening the
  `reportJobs` enum to the new names. The `enum [ "daily" "telemetry" ]` is the one place the
  current module hardcodes the job set and would have to open up.
- **One pruning host per destination**, expressed as `pruneOpts = [ ]` on every other host — the
  same posture `nix-forge/nix-conf` documents and the mitigation §4.1 and §5.5 both want.
- **Separate check jobs rather than `checkOpts` on the backup job**, per
  `madslundt/HomeCompute` and #412106's workaround: a `paths = [ ]`, `pruneOpts = [ ]`,
  `runCheck = true` entry on a weekly timer. `paths = null` or `[ ]` with no `dynamicFilesFrom`
  is explicitly supported for this — the module's own comment says "This can be used to create a
  prune-only job."

______________________________________________________________________

## 4. Operational pitfalls once there is more than one destination

### 4.1 Lock contention is per-repository, so fan-out mostly sidesteps it

Locks are files in the repository's `locks/` directory, and the semantics are:

> Locks come in two types: Exclusive and non-exclusive locks. At most one process can have an
> exclusive lock on the repository, and during that time there must not be any other locks
> (exclusive and non-exclusive). There may be multiple non-exclusive locks in parallel.

> When a lock is found, it is tested if the lock is stale, which is the case for locks with
> timestamps older than 30 minutes. If the lock was created on the same machine, even for
> younger locks it is tested whether the process is still alive by sending a signal to it.

— [design.rst:596–645](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst)

Because locks are per-repository, **two fan-out jobs writing two different repos never
contend.** What *does* contend:

- **Several hosts backing up to one shared repository.** The fleet already does this:
  `custom.profiles.backup` points every host's `daily` and `telemetry` jobs at the *same*
  rsync.net repo (`sops.templates."restic-repo"` → `<repo>:backups`). `backup` takes a
  non-exclusive lock and many can run in parallel; **`prune` needs the exclusive one.** With
  four hosts each running `forget --prune` on `OnCalendar = "00/6:00"`, the first to get there
  wins and the others get exit code 11, "Failed to lock repository (since restic 0.17.0)"
  ([075_scripting.rst:166](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst)) —
  a unit failure, and with it a missing `backup_restic_last_success_timestamp_seconds` stamp,
  because `ExecStartPost` only fires when every `ExecStart` step succeeded.
- **The mitigation restic provides is `--retry-lock`**, "retry to lock the repository if it is
  already locked, takes a value like 5m or 2h (default: no retries)"
  ([manual_rest.rst](https://github.com/restic/restic/blob/v0.19.1/doc/manual_rest.rst)).
  **And §3.2 note 1 is why you cannot reach it from the module** — confirmed upstream by
  [#468191](https://github.com/NixOS/nixpkgs/issues/468191), whose reporter found
  `--retry-lock 48h` in `extraBackupArgs` cut failure rates substantially while leaving the
  `unlock` and `forget` steps unprotected. Real configs work around it by smuggling the flag
  into the `extraOptions` string after the sftp command (ugly, and it depends on the module
  concatenating `-o <arg>` without quoting) or by overriding `ExecStart`. Either stagger the
  timers so the windows do not overlap, or give exactly one host the prune duty
  (`pruneOpts = []` everywhere else).

**Giving exactly one host the prune duty is the cleanest of the three** and it composes with
fan-out: each destination gets one designated pruning host, every other host runs
backup-only. It also removes the §5.5 blast radius from three of four hosts. The alternative
practice found in real configs is [kradalby/dotfiles](https://github.com/kradalby/dotfiles)'
`modules/restic-jobs-linux.nix`: prune on Wednesday, check on Monday, "so the two
exclusive-lock holders never share a window by construction", with `--retry-lock=12h` and
`TimeoutStartSec = "24h"`.

### 4.2 Concurrent `prune` on the same repo

Not a correctness risk — the exclusive lock prevents it — but the failure is noisy and the
cost is real. `prune` is the expensive operation: "for repacking, restic must download the
file from the repository storage and re-upload the needed data in the repository. This can be
very time-consuming for remote repositories"
([060_forget.rst:462](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst)).

Two 0.19-era changes affect how much repacking happens:

- **[Chg #5293](https://github.com/restic/restic/issues/5293) (0.19.0): "Prune small packfiles
  more aggressively."** "The `prune` command now repacks more small packfiles by default. The
  option `--repack-small` is no longer needed and has been marked as deprecated." So a 0.19
  prune does *more* download-and-reupload than an 0.18 one, by design. On a per-request-priced
  or metered backend, budget for it.
- `--max-unused` defaults to **5%**; `--max-repack-size`, `--repack-cacheable-only`
  (metadata only, "a very fast repacking using only cached data") and `--repack-smaller-than`
  are the dials. `--max-unused unlimited` is the explicit "minimize the time and bandwidth used
  by the prune operation" setting, at the cost of unbounded dead data.

For a 30–100 GB repository none of this is painful. **Set `--max-unused unlimited` on the
secondary if its prune ever becomes the long pole** — the storage it wastes costs cents at B2
prices, and the whole point of the secondary is to exist, not to be tidy.

**The failure mode this produces is worse than it looks, and it has a dated field report.**
Because the module welds backup, unlock, forget and check into one oneshot's `ExecStart` list
(§3.2), systemd aborts the unit on the first failing step — so a *repository-side* prune
failure marks the unit failed even though the snapshot was already written and logged.
[Multipixelone/infra](https://github.com/Multipixelone/infra), `modules/backup/restic.nix`,
documents exactly this: `restic-backups-home` reported failure on **29 consecutive nights from
2026-07-27** while every run had already logged "snapshot … saved". They now run prune as its
own unit with `pruneOpts = [ ]` on the backup job. **For this fleet the consequence is sharper
than a red unit**: `resticStamp` is wired as `ExecStartPost`, which fires only when every
`ExecStart` step succeeded, so a contended prune suppresses
`backup_restic_last_success_timestamp_seconds` for a backup that actually worked — the Backups
board would show a stale off-site edge that is not stale. Splitting prune into its own unit
fixes the metric as well as the exit status.

### 4.3 Disk and network I/O contention

Fan-out reads the source tree once per destination (§1.5). The levers, all from
[047_tuning_parameters.rst](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst):

- `-o <backend>.connections=N` — global per-backend concurrency, default **5** (local: **2**).
  "For high-latency backends it can be beneficial to increase the number of connections…
  a too high connection count *will degrade performance*." This is an `-o` option, so it **is**
  reachable via `extraOptions` — and on a Hetzner Storage Box it has to be, given the 10-connection
  account cap (§2.5).
- `GOMAXPROCS` — caps CPU cores; "Limiting the number of usable CPU cores can slightly reduce
  the memory usage of restic." Relevant on porcupineFish (a Pi) and on rk1b's aarch64 cores
  if two jobs ever overlap.
- `RESTIC_READ_CONCURRENCY` / `--read-concurrency` — raise on NVMe, which describes rk1b.
- `--no-scan` — drops the progress-estimation I/O entirely. For an unattended systemd job
  there is no one watching the estimate; this is close to free.
- `--pack-size` (MiB, default **16 MiB**) — and the warning that matters for fan-out:
  "Restic requires temporary space according to the pack size, multiplied by the number of
  backend connections plus one." At the default that is 16 × 6 = 96 MiB per concurrent job in
  `$TMPDIR`. The unit sets `PrivateTmp = true`, so that is tmpfs-backed on rk1b — **two
  overlapping jobs want ~192 MiB of a 2 GB tmpfs root.** Set `TMPDIR` onto the NVMe, or stagger.

### 4.4 Staggered scheduling: what the module makes easy

`timerConfig` is a raw systemd timer attrset, so the practice is just systemd practice. The
module's own example is `{ OnCalendar = "00:05"; RandomizedDelaySec = "5h"; Persistent = true; }`
— i.e. **upstream's documented idiom is a wide randomised delay**, not a hand-picked offset.

For this fleet the current `daily` and `telemetry` jobs both sit on `OnCalendar = "00/6:00"`
with `Persistent = true` and no `RandomizedDelaySec`, which means on a host running both they
start in the same second, against the same repository, and race for the prune lock. Adding a
second destination multiplies that. Three practices, in increasing order of how much I would
trust them:

1. **Different `OnCalendar` per destination.** Deterministic, reviewable, and it is what the
   fleet already does implicitly nowhere. E.g. rsync.net at `00/6:00`, B2 at `03/6:00`.
1. **`RandomizedDelaySec` on top**, per upstream's example, to decorrelate the four hosts
   hitting one shared repo. Note this interacts with `AccuracySec`, which the fleet's own
   status timer already sets to `10s`.
1. **One pruning host per destination** (§4.1), which removes the contention rather than
   spreading it.

I have found **no primary source stating a recommended cadence or offset** — restic's docs say
nothing about scheduling, and the nixpkgs module only offers the example above. Any specific
"stagger by two hours" advice is practitioner habit, not documentation.

______________________________________________________________________

## 5. Verification and ransomware resistance

### 5.1 `check` vs `check --read-data-subset`

**Two different checks, and the docs are explicit that the default one does not read your
data:**

> There are two types of checks that can be performed:
>
> - Structural consistency and integrity, e.g. snapshots, trees and pack files (default)
> - Integrity of the actual data that you backed up (enabled with flags, see below)

> By default, the `check` command does not verify that the actual pack files on disk in the
> repository are unmodified, because doing so requires reading a copy of every pack file in
> the repository.

— [045:410–485](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)

`--read-data` reads everything, with the warning "beware that it might incur higher bandwidth
costs than usual". `--read-data-subset` takes **three** syntaxes, all documented:

| Syntax | Meaning | Example |
|---|---|---|
| `n/t` | pack files split into `t` roughly equal groups, check group `n`. Deterministic: `1/5` … `5/5` covers everything over five runs | `check --read-data-subset=1/5` |
| `x%` | a **randomly chosen** `x` percent; "will not guarantee to cover all available pack files after sufficient runs, but it is easy to automate checking a small subset of data after each backup". Accepts floats | `check --read-data-subset=2.5%` |
| `nS` | a randomly chosen subset by size, `K/M/G/T`; converted to a percentage internally, then behaves as `x%` | `check --read-data-subset=10G` |

**On cadence: restic documents none.** The closest the docs come is "it is a good idea to
regularly use the `check` command" and the `x%` form being "easy to automate… after each
backup". Any specific schedule is a practitioner choice. What the primary sources *do* settle:

- `n/t` is the form to use if you want **guaranteed full coverage** on a rotation; `x%` is
  random sampling and will leave gaps indefinitely.
- Pair any `check` with `--with-cache` or it rebuilds its cache from the repository (§3.3).
- A failed check is not advisory: "If `check` reports an error in the repository, then you
  must repair the repository. As long as a repository is damaged, restoring some files or
  directories will fail. New snapshots are not guaranteed to be restorable either."
- `--no-extra-verify` on `backup` (which the fleet does not set, and should not) shifts the
  burden onto check: "you should verify the repository integrity more actively using
  `restic check --read-data`".

Concretely, for a 30–100 GB repo on B2 with free egress inside 3× storage: a weekly
`--read-data-subset=1/4` rotation reads the whole repo monthly and stays inside the free egress
allowance by a wide margin. The same rotation against rsync.net costs nothing either (no egress
charge) but spends sftp time, which §2.5's 32 KiB-chunk note says is the slow path.

### 5.2 Automated restore drills

**restic documents no restore-drill mechanism and the nixpkgs module provides no hook for
one.** `backupCleanupCommand` runs in `postStop` and could invoke one, but it runs as the same
root unit against the same repo — a drill that shares its credentials and its machine with the
thing it is testing. The honest statement is that this has to be built, and the two cheap
shapes are:

1. **`restic restore latest --target /tmp/drill --include <small canary path>`** on a
   schedule, comparing a known file's checksum. Covers the end-to-end path (credentials,
   network, decryption, extraction) on a few MB.
1. **`restic dump latest <path> | sha256sum`**, which skips the filesystem write entirely.

Neither is in restic's docs as a recommended practice; both are straightforward uses of
documented commands. `restic check --read-data-subset` is the documented substitute and covers
repository integrity but *not* the restore path — it never exercises `restore`, target
filesystem permissions, or the operator's ability to find the password.

### 5.3 Prometheus exporters, against "we already roll our own textfile metrics"

**restic has no built-in metrics.** Grepping its entire doc tree for "prometheus" returns
nothing; [#2362](https://github.com/restic/restic/issues/2362) "Prometheus exporter"
(opened 2019-08-07) is still open with no maintainer commitment, and its own proposal is to
build an external tool. The only first-party Prometheus surface in the restic org is
**rest-server's `--prometheus` / `--prometheus-no-auth`**, which exposes server-side I/O
counters (`rest_server_blob_{write,read,delete}_total` and `_bytes_total`, labelled
`user, repo, type`) — useful if we ever run rest-server, irrelevant otherwise.

The third-party field splits cleanly in two, and the split is the whole point:

**(a) Summary-based — parse what restic already tells you.** `restic backup --json`'s final
`summary` message carries `files_new`, `files_changed`, `files_unmodified`, `dirs_*`,
`data_blobs`, `tree_blobs`, `data_added`, `data_added_packed`, `total_files_processed`,
`total_bytes_processed`, `backup_start`, `backup_end`, `total_duration`, `snapshot_id`
([075_scripting.rst](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst),
which also warns the format "is intended to remain backwards compatible. However, new message
types or fields may be added at any time"). `check --json` emits a summary with `num_errors`,
`broken_packs`, `suggest_repair_index`, `suggest_prune`. **Zero extra repository access, zero
extra cost.** [resticprofile](https://creativeprojects.github.io/resticprofile/monitoring/prometheus/)
is the mature implementation of this shape (textfile via `prometheus-save-to-file` or
Pushgateway via `prometheus-push`; metrics `resticprofile_backup_{duration_seconds,files_new, files_changed,files_unmodified,dir_*,files_processed,added_bytes,added_bytes_packed, processed_bytes,status,time_seconds}`), but it is a whole scheduling framework we do not need.

**(b) Scrape-based — open the repository and ask it.**
[ngosang/restic-exporter](https://github.com/ngosang/restic-exporter) (Python, MIT, 2.1.2 on
2026-06-25) is the reference implementation and the one nixpkgs packages. It exposes
`restic_check_success`, `restic_locks_total`, `restic_snapshots_total`, `restic_size_total`,
`restic_uncompressed_size_total`, `restic_compression_ratio`, `restic_blob_count_total`,
`restic_scrape_duration_seconds` globally, plus a per-backup family
(`restic_backup_timestamp`, `restic_backup_{files_total,size_total,files_new,files_changed, files_unmodified,dirs_new,dirs_changed,dirs_unmodified,data_added_bytes,duration_seconds, snapshots_total}`) labelled `client_hostname, client_username, client_version, snapshot_hash, snapshot_tag, snapshot_tags, snapshot_paths`. **It needs the repository password in its own
environment** and it shells out to `restic stats` ("expensive in CPU/Memory") and
`restic check` ("takes 20 seconds or more") on every refresh, with `NO_CHECK`/`NO_GLOBAL_STATS`
defaulting to off.

nixpkgs does ship `services.prometheus.exporters.restic`
(`nixos/modules/services/monitoring/prometheus/exporters/restic.nix`, default port 9753,
options `repository`/`repositoryFile`, mandatory `passwordFile`, `environmentFile`,
`refreshInterval`, rclone passthrough) wrapping `prometheus-restic-exporter` — **pinned at
upstream 1.7.0 against upstream's current 2.1.2**, with `refreshInterval` defaulting to **60
seconds** while upstream's own default is 3600. A 60-second refresh that runs `restic check`
each time is a self-inflicted DoS on a metered remote repository. Two gotchas, both verified
against the module source: that default, and that `extraFlags` is inert because the exporter
has no argparse at all (configuration is env-var only, so `NO_CHECK` must go through
`environmentFile`).

**Verdict against our own textfile metrics.** The fleet's
`backup_restic_enabled{restic_job}` / `backup_restic_last_success_timestamp_seconds{restic_job}`
pair already covers (a) — and covers it *better* for the fan-out case, because it is emitted
from config and therefore shows a *disabled or absent* destination as `0` rather than as
missing data, which no exporter can do. **Keep it; extend `reportJobs` to the new destination
names.** What it does not cover and (b) would:

- repository **size and growth** per destination — the one number that tells you a lifecycle
  rule is missing on B2 (§2.1 gotcha 2) before the bill does
- **`restic_check_success`** — and the fleet runs no `check` at all today (§3.2 note 4), so
  this is a gap in the *backup* config, not in the metrics
- **stale lock count** — directly the §4.1 failure mode

The cheap move is to extend the existing textfile script rather than adopt an exporter: the
fleet already has the idiom, and `restic stats --json` (fields `total_size`,
`total_file_count`, `total_blob_count`, `snapshots_count`, `total_uncompressed_size`,
`compression_ratio`, `compression_progress`, `compression_space_saving`) plus `check --json`'s
`num_errors` are two shell lines into the same `.prom` file, run on the job's own schedule
instead of every 60 seconds. **That is the recommendation: no exporter.**

One caveat for whoever writes it: `restic snapshots --json`'s `--latest` default grouping
**changed in 0.19.0** — it now returns one globally-latest snapshot instead of one per client
— so pass `--latest 1 --group-by host,paths` explicitly, and expect
`{"group_key":…,"snapshots":[…]}` rather than a flat list when `--group-by` is used.

### 5.4 Append-only, and what each backend can actually offer

restic's docs are blunt about how rare this is:

> To prevent a compromised backup client from deleting its backups (for example due to a
> ransomware infection), a repository service/backend can serve the repository in a so-called
> append-only mode… Restic's `rest-server` features an append-only mode, but **few other
> standard backends do.** To support append-only with such backends, you can use `rclone` as a
> complement in between the backup client and the backend service.

> The usual and recommended setup with append-only repositories is therefore to use a separate
> and well-secured client whenever full access to the repository is needed, e.g. for
> administrative tasks such as running `forget`, `prune` and other maintenance commands.

— [060_forget.rst:395–420](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst)

**rest-server `--append-only`** "allows creation of new backups but prevents deletion and
modification of existing backups. This can be useful when backing up systems that have a
potential of being hacked"
([rest-server README](https://github.com/restic/rest-server#readme)). It is the only
first-party answer. It also requires a server *we* run, which for an off-site second
destination means paying for a VPS — and kelpy is in the fleet, 90 GB of disk, so it is not
an independent off-site.

**nixpkgs does ship the server side, and it is a one-line enable.**
`nixos/modules/services/backup/restic-rest-server.nix` provides `services.restic.server` with
`enable`, `listenAddress` (socket-activated, default `"8000"`, and an assertion rejects a
leading `:`), `dataDir` (`/var/lib/restic`), **`appendOnly` (bool, default `false`)** whose own
description is "allows creation of new backups but prevents deletion and modification of
existing backups", `htpasswd-file`, `privateRepos`, `prometheus`, `extraFlags` and `package`.
It runs as `User/Group = restic` under socket activation with `ProtectSystem=strict`,
`PrivateNetwork=true` and a `@system-service` syscall filter. So **if a cheap EU VPS with disk
ever enters the picture, `services.restic.server.appendOnly = true` plus `privateRepos` is the
strongest destination available to this fleet** — stronger than anything B2 can offer, because
the deny happens server-side on every write rather than being reconstructed from versioning and
a lifecycle rule. It is not the recommendation today only because it costs a machine and B2
costs $0.63.

**restic's docs say nothing at all about object lock or S3 versioning** — grepping the doc
tree for "object lock", "versioning" and "immutab" returns zero hits. Everything below about
object lock is deduction from the *providers'* primary sources, and I flag it as such.

**The B2 route the verdict recommends, and why it is not quite immutability:**

1. **A B2 application key without `deleteFiles`.** restic supports this explicitly —
   [Enh #2134](https://github.com/restic/restic/issues/2134) (restic 0.15.0): "When the B2
   backend does not have the necessary permissions to permanently delete files, it now
   automatically falls back to hiding files. This allows using restic with an application key
   which is not allowed to delete files. **This can prevent an attacker from deleting backups
   with such an API key.** To use this feature create an application key without the
   `deleteFiles` capability… `b2 create-key --bucket <bucketName> <keyName> listBuckets,readFiles,writeFiles,listFiles`. Alternatively, you can use the S3 backend to
   access B2, as described in the documentation. **In this mode, files are also only hidden
   instead of being deleted permanently.**"
1. **A lifecycle rule that reclaims the hidden versions after 30 days**, using B2's "Keep prior
   versions for this number of days" preset rather than the "Keep only the last version"
   preset restic's docs name (which hides after one day then deletes).
1. The result: **`forget --prune` from the host hides pack files; B2 deletes them 30 days
   later.** Space is reclaimed, so §2.1's gotcha 2 is satisfied. And a compromised host that
   runs `forget --prune --keep-last 1` has hidden, not destroyed, 30 days' worth of history.
1. **Pair it with `--keep-within`**, which is restic's own documented advice for append-only
   repositories: "With append-only repositories, you should specifically use the
   `--keep-within` option of the `forget` command when removing snapshots", because an
   attacker who can *add* snapshots can otherwise poison a `--keep-weekly`-style policy into
   deleting the legitimate ones. The worked example and its limits are in
   [060_forget.rst:421–447](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst).

**This is a 30-day recovery window, not immutability.** Be precise about it: the window only
helps if someone notices inside 30 days, which is what §5.3's size/last-success metrics are
for. True immutability needs compliance-mode object lock — and **compliance-mode object lock
and `restic prune` are mutually exclusive**, because prune's job is to delete pack files and
compliance mode refuses deletion until retention expires (B2:
[object lock docs](https://www.backblaze.com/docs/cloud-storage-enable-object-lock-with-the-native-api);
Scaleway states it outright: "it is only possible to overwrite it or delete an object once the
Object Lock expires or upon deleting your Scaleway account"). That deduction is **not settled
by any restic source** — restic documents no object-lock interaction at all — so if genuine
immutability is wanted, the design is "locked bucket, no prune ever, forget only, accept
unbounded growth", and it should be tested before being trusted.

**Per-backend summary of what is actually available:**

| Backend | Append-only primitive | Does `prune` still work? |
|---|---|---|
| rest-server | **`--append-only`** (first-party, documented) | no — run forget/prune from a separate trusted client, per restic's docs |
| B2 | no-delete app key → deletes become hides; versioning + lifecycle window | yes, as hide-then-expire (**recommended**) |
| S3 generic (Scaleway) | object lock compliance/governance; versioning | **no** under compliance retention (deduced) |
| R2 | bucket locks, **no versioning, no S3 Object Lock** | **no** under a lock (deduced; no hide tier exists) |
| Hetzner Storage Box | read-only sub-accounts only — blocks `backup` too | n/a |
| rsync.net | ZFS snapshots / read-only account / append-only advertised, **but ZFS snapshots are excluded from the discounted restic tier** | depends on the account; unresolvable from public pages |

### 5.5 The real risk: one compromised client, every reachable repo

This is the failure mode fan-out introduces and it deserves stating plainly rather than as a
bullet. **A host running fan-out holds write credentials for every destination.** Root on that
host can run `restic forget --prune --keep-last 1` against all of them in sequence. restic's
own docs concede the point: "To remove snapshots and recover the corresponding disk space, the
`forget` and `prune` commands require full read, write and delete access to the repository. If
an attacker has this, **the protection offered by append-only mode is naturally void.**"

Three structural mitigations, in order of effectiveness, all available today:

1. **Asymmetric credentials per destination.** The primary (rsync.net) keeps full access
   because that is where retention is managed; the secondary (B2) gets a key that *cannot
   delete* (§5.4). One compromised host then destroys one copy, not two. **This is the single
   highest-value item in this document** and it costs one B2 key capability list.
1. **One pruning host per destination** (§4.1). Three of four hosts then carry
   backup-only credentials and `pruneOpts = []`, so the `forget --prune` capability exists in
   one place per repo instead of four.
1. **Separate repository passwords per destination.** `passwordFile` is per-job
   (§3.1), so this is free. Today `custom.profiles.backup` hands every job the same
   `restic/password` from sops; a second destination reusing it means one leaked password
   reads both repositories. A leaked password alone cannot delete anything — it needs repo
   access too — but there is no reason to couple them.

And the operational corollary: **monitor the secondary's snapshot count and repository size,
not just last-success.** A compromised client running `forget` still produces a *successful*
backup unit and a fresh `backup_restic_last_success_timestamp_seconds`. Size collapsing or
`snapshots_count` dropping is the signal; §5.3 is where it would come from, and the fleet does
not emit it today.

______________________________________________________________________

## ⚠️ RISK CALLOUT — nothing in this fleet currently verifies a backup, anywhere

Two findings from the config and module source, independent of which second destination gets
chosen, and both are prerequisites rather than nice-to-haves:

**1. `restic check` has never run on this fleet.** `runCheck`'s default is
`checkOpts != []` (§3.2 note 4) and `modules/nixos/profiles/backup.nix` sets `pruneOpts` on
both jobs and `checkOpts` on neither. So the rsync.net repository's structural integrity has
never been verified by anything, and `backup_restic_last_success_timestamp_seconds` means
"restic exited 0 writing a snapshot" — which is a statement about the *write* path only. A
repository can be structurally damaged and still accept new snapshots; restic says so
directly: "New snapshots are not guaranteed to be restorable either."

**2. Both existing jobs share one repository, one password, one SSH identity, and one
schedule.** `custom.profiles.backup` points `daily` and `telemetry` at the same
`sops.templates."restic-repo"` and the same `restic_password`, both on `OnCalendar = "00/6:00"`,
both with `pruneOpts` — so on a host that enables both, two units start in the same second and
race for the same exclusive prune lock (§4.1). rk1b avoids this today only because
`monitoringTelemetry.enable = false` there. Enabling telemetry anywhere, or adding a second
destination without staggering, trips it.

**Consequence for sequencing.** Adding a second destination to an unverified primary buys two
copies of unknown quality. The cheap fix comes first and is three lines: add
`checkOpts = [ "--with-cache" ]` to the existing jobs so a structural check runs after every
backup (seconds, no data download), then a weekly `--read-data-subset=1/4` rotation, then the
second destination. If only one thing from this document gets done, it should be that one, not
the new bucket.

______________________________________________________________________

## Sources

**restic, read at tag `v0.19.1`** (the version rk1b builds) —
[`doc/030_preparing_a_new_repo.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst)
(sftp, S3, S3-compatible, Wasabi, B2 warning, rest-server, rclone),
[`doc/040_backup.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst),
[`doc/045_working_with_repos.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst)
(copy, `--copy-chunker-params`, check, `--read-data-subset`),
[`doc/047_tuning_parameters.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst)
(connections, `GOMAXPROCS`, pack size, `--no-scan`, `--no-extra-verify`),
[`doc/060_forget.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst)
(policy options, append-only security considerations, prune internals and options),
[`doc/075_scripting.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst)
(exit codes, JSON summary fields and their stability caveat),
[`doc/cache.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/cache.rst),
[`doc/design.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst)
(repo layout, `chunker_polynomial`, locks, CDC),
[`doc/manual_rest.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/manual_rest.rst)
(caching, `--retry-lock`, `--no-lock`),
[`doc/REST_backend.rst`](https://github.com/restic/restic/blob/v0.19.1/doc/REST_backend.rst),
[`CHANGELOG.md`](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md)
(#5453 copy batching, #5293 prune small packfiles, #3161 B2 double Class B, #2134 no-delete B2
keys), [`cmd/restic/cmd_unlock.go`](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_unlock.go),
[`internal/backend/sftp/sftp.go`](https://github.com/restic/restic/blob/v0.19.1/internal/backend/sftp/sftp.go)

**restic issues** — [#265](https://github.com/restic/restic/issues/265) (closed; fd0's rclone
recommendation and MichaelEischer's closing rationale),
[#679](https://github.com/restic/restic/issues/679) (closed),
[#2362](https://github.com/restic/restic/issues/2362) (Prometheus exporter, open, no
direction), [#4432](https://github.com/restic/restic/issues/4432) (open,
`state: need direction`, maintainer's memory-cost assessment)

**rest-server** — [README](https://github.com/restic/rest-server#readme) (`--append-only`,
`--prometheus`, the SFTP-vs-REST performance note)

**nixpkgs module source**, read at this repo's pinned rev
`7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f` — `nixos/modules/services/backup/restic.nix`;
`nixos/modules/services/backup/restic-rest-server.nix` (`services.restic.server`, `appendOnly`);
`nixos/modules/services/monitoring/prometheus/exporters/restic.nix` and
`pkgs/by-name/pr/prometheus-restic-exporter/package.nix`. Option set and defaults cross-checked
against [search.nixos.org](https://search.nixos.org/options?query=services.restic.backups)
(26 options under `services.restic.backups`, none per-destination). Cache rationale from commit
[`27da11972`](https://github.com/NixOS/nixpkgs/commit/27da11972) (2020-10-04).

**nixpkgs issues and PRs** — [PR #492460](https://github.com/NixOS/nixpkgs/pull/492460)
(module rewrite, open 2026-02-20), [PR #453881](https://github.com/NixOS/nixpkgs/pull/453881)
(global flags / `--retry-lock`, open 2025-10-20),
[#412106](https://github.com/NixOS/nixpkgs/issues/412106) (prune/check in separate units, and
the duplicate-job workaround), [#456723](https://github.com/NixOS/nixpkgs/issues/456723)
(group backups by repository), [#465973](https://github.com/NixOS/nixpkgs/issues/465973)
(`forget` scoping), [#468191](https://github.com/NixOS/nixpkgs/issues/468191)
(`extraForget` / `--retry-lock` unreachable),
[#267690](https://github.com/NixOS/nixpkgs/issues/267690) (stale locks; maintainers decline
auto-`unlock`), [#216457](https://github.com/NixOS/nixpkgs/issues/216457). `"restic copy"`
returns zero results across nixpkgs issues and PRs, and the module's full commit history
mentions no `copy`/`from-repo`/`mirror`/`replicate`.

**Community NixOS configs** (all one-off personal configs — read as evidence of *practice*, not
as endorsement) — [madslundt/HomeCompute](https://github.com/madslundt/HomeCompute)
`modules/nixos/backups.nix`,
[darkone-linux/darkone-nixos-framework](https://github.com/darkone-linux/darkone-nixos-framework)
`modules/service/restic.nix`, [kleinbem/nix-presets](https://github.com/kleinbem/nix-presets)
`nixosModules/backup-engine/default.nix`,
[ibizaman/selfhostblocks](https://github.com/ibizaman/selfhostblocks)
`modules/blocks/restic.nix`, [nix-forge/nix-conf](https://github.com/nix-forge/nix-conf),
[Swarsel/.dotfiles](https://github.com/Swarsel/.dotfiles),
[SebastianStork/nixos-config](https://github.com/SebastianStork/nixos-config),
[NovaViper/NixConfig](https://github.com/NovaViper/NixConfig),
[joaovl5/\_nix](https://github.com/joaovl5/_nix) `lib/units/_backup/rendering.nix`,
[MichaelAug/server-config](https://github.com/MichaelAug/server-config),
[geggo98/dotfiles](https://github.com/geggo98/dotfiles) `modules/nixos-backup-copy.nix`,
[Multipixelone/infra](https://github.com/Multipixelone/infra) `modules/backup/restic.nix`,
[kradalby/dotfiles](https://github.com/kradalby/dotfiles) `modules/restic-jobs-linux.nix`.
**nix-community publishes nothing restic-related** (`org:nix-community restic` → 0
repositories); srvos, clan-core and nixos-facter contain no restic code.

**This repo** — `modules/nixos/profiles/backup.nix`, `hosts/rk1/backup.nix`,
`docs/adr/0030-git-annex-and-backups-across-hosts-and-users.md`,
`docs/adr/0021-telemetry-durable-disk-capped-retention.md`, `flake.lock` (`nixpkgs_7`)

**Provider pages, all read 2026-10-05** — Backblaze
[pricing](https://www.backblaze.com/cloud-storage/pricing),
[transaction pricing](https://www.backblaze.com/cloud-storage/transaction-pricing),
[data regions](https://www.backblaze.com/docs/cloud-storage-data-regions),
[object lock](https://www.backblaze.com/docs/cloud-storage-enable-object-lock-with-the-native-api),
[lifecycle rules](https://www.backblaze.com/docs/cloud-storage-lifecycle-rules),
[S3-compatible API intro](https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api);
Wasabi [pricing](https://wasabi.com/pricing),
[pricing FAQs](https://wasabi.com/pricing/pricing-faqs),
[storage regions](https://wasabi.com/company/storage-regions);
Cloudflare [R2 pricing](https://developers.cloudflare.com/r2/pricing/),
[S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/),
[bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/),
[limits](https://developers.cloudflare.com/r2/platform/limits/),
[data location](https://developers.cloudflare.com/r2/reference/data-location/);
Scaleway [storage pricing](https://www.scaleway.com/en/pricing/storage/),
[Object Storage concepts](https://www.scaleway.com/en/docs/object-storage/concepts/),
[lifecycle rules](https://www.scaleway.com/en/docs/object-storage/how-to/manage-lifecycle-rules/),
[FAQ](https://www.scaleway.com/en/docs/object-storage/faq/),
[request-rate troubleshooting](https://www.scaleway.com/en/docs/storage/object/troubleshooting/request-rate-error/),
[Glacier](https://www.scaleway.com/en/glacier-cold-storage/);
Hetzner [Storage Box product page](https://www.hetzner.com/storage/storage-box/) and its live
price feed `https://www.hetzner.com/_resources/app/data/app/live_data_prices.json`,
[SSH/rsync/BorgBackup access docs](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/);
rsync.net [pricing](https://www.rsync.net/pricing.html),
[restic](https://www.rsync.net/products/restic.html),
[borg](https://www.rsync.net/products/borg.html),
[locations](https://www.rsync.net/products/locations.html)

**Exporters** — [ngosang/restic-exporter](https://github.com/ngosang/restic-exporter),
[resticprofile Prometheus docs](https://creativeprojects.github.io/resticprofile/monitoring/prometheus/)

**Explicitly not settled by any primary source**, and said so in place: the Backblaze EU S3
endpoint string (§2.1); Wasabi's object-lock support, its $9.99/TB region list and any numeric
rate limit (§2.2); Scaleway's PUT rate-limit value (§2.4); Hetzner's inode/file-count limits
(§2.5); what tier and immutability the fleet's own rsync.net account is on, given a 112 GB
quota that matches no published minimum (§2.6); whether `forget` actually succeeds against a
no-delete B2 application key via the S3 backend (§5.4); and the interaction between
compliance-mode object lock and `prune`, which restic documents nowhere (§5.4); and any
recommended `check` cadence or timer stagger, which neither restic's docs nor the nixpkgs module
state (§4.4, §5.1).

**Two places where a non-primary source is the only one available**, both flagged in place:
the append-only-with-rclone route restic's docs point at rests on a
[blog post by Simon Ruderich](https://ruderich.org/simon/notes/append-only-backups-with-restic-and-rclone)
— linked *from* restic's docs but not itself primary, and not relied on for any claim here; and
the lock-removal hazard analysis behind nixpkgs
[#267690](https://github.com/NixOS/nixpkgs/issues/267690) cites a `forum.restic.net` thread, so
the *decision* not to auto-unlock is primary (maintainer comments in the issue) while the risk
reasoning behind it is unverified-secondary.
