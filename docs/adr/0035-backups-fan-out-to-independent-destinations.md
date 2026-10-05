# Backups fan out to independent destinations, and backup / prune / check are three units, not one

The fleet reached one working off-site destination on 2026-10-02 (ADR-0034's photo library,
palimpsest#150's first live restic job). One destination is not 3-2-1: the Immich library exists
on rk1b's single NVMe and in one rsync.net repository, and the third copy — Google Photos — was
deleted once the import was verified. This ADR records how a second destination gets added, and
a prerequisite that turned out to matter more than the second destination itself.

Full working notes, every claim traced to a primary source, are in
`research/restic-multi-destination.md`.

## Decision 1 — fan out, do not replicate

restic cannot write one backup to two repositories. The two available shapes are **fan-out** (an
independent `restic backup` run per destination, each reading the source from local disk) and
**replication** (`restic copy` from the primary to the secondary). We fan out.

The deciding fact is not architectural taste, it is bandwidth, and it is easy to get backwards:
**`restic copy` downloads the entire payload.** restic's own documentation flags this
`.. important::` — the two repositories use different encryption keys, so data cannot move
provider-to-provider and must pass through the machine running the command. On rk1b that means
a full download from rsync.net followed by a full upload to the secondary. Fan-out reads from
the local NVMe instead: no download, one upload. Fan-out is **cheaper on this topology**, not
merely more independent.

Independence is the second reason and the one that matters after a compromise: fan-out produces
two repositories that share no history, so corruption, a bad `forget`, or a lapsed account in
one cannot propagate to the other. Replication makes the secondary a derivative of the primary.

The cost accepted is 2× local read and chunking CPU per host. Measured upload is ~40 MB/s, and
a run moves ~12.8 GiB, so this is affordable.

**Chunker parameters are a one-shot decision the NixOS module cannot make.** `initialize = true`
runs a bare `restic init` (it probes for exit code 10 and inits on that), with no way to pass
`--from-repo --copy-chunker-params`, and restic states plainly that the chunker parameters of an
existing repository cannot be changed afterwards. So the second repository is to be
`init`-ed **by hand with matched parameters**, purely to keep the `restic copy` route available
later at no cost today. This is the only step in the rollout that cannot be expressed in Nix.

## Decision 2 — the second destination is object storage with immutability, not another sftp target

Rejected: **Hetzner Storage Box**, despite being the closest mechanism match (sftp, so it reuses
the existing transport; flat €3.81/mo for 1 TB; EU-resident; restic named on their own page). It
has **no immutability primitive at all**, and it caps connections at 10 against restic's default
of 5. A second sftp target with full delete rights, whose key sits on the same host as the first
one's key, survives a vendor failing but not a compromised client running `forget --prune` — and
that is the threat the third copy is for.

Rejected: **Wasabi** — a 1 TB minimum charge ($7.99 at our size) plus a 90-day minimum retention
that directly taxes `forget --prune`.

Chosen: **Backblaze B2** via its S3-compatible API, EU Central, behind an application key with
no `deleteFiles` capability and a lifecycle rule retaining prior versions 30 days. ~$0.14/mo at
30 GB. The point is not the price, it is that the fleet cannot destroy this copy even if a host
is fully compromised.

**What would change this:** if a cheap EU VPS is acceptable,
`services.restic.server.appendOnly = true` beats B2 outright — real append-only, EU-resident, no
per-request pricing, and one less external account.

## Decision 3 — backup, prune and check are separate units (landed first, 2026-10-05)

This started as a prerequisite and became the most valuable part. Two defects were found by
reading the nixpkgs module rather than by anything failing:

**Nothing on this fleet had ever verified a backup.** `runCheck` defaults to
`checkOpts != [ ]` (`nixos/modules/services/backup/restic.nix:257`); `checkOpts` was never set
on either job, so `restic check` had never run anywhere. Every "successful" backup was
unverified — and palimpsest#150's own acceptance criterion asks for exactly this.

**The last-success metric could report a failure as success's absence.** The module appends
`unlock` and `forget --prune` to the *backup* unit's `ExecStart` list (line 453), and this repo
stamps `backup_restic_last_success_timestamp_seconds` from `ExecStartPost` — which systemd runs
only when every `ExecStart` step succeeded. A prune failing on a contended lock therefore
suppressed the stamp for a backup that had in fact succeeded, and the Backups board went cold on
a good night. The comment in `backup.nix` already said "ExecStartPost only fires when every
ExecStart step succeeded"; the consequence was simply not followed through.

So the job is decomposed. `pruneOpts` is now empty on both jobs — retention is unchanged, just
relocated — and `restic-prune-<job>` and `restic-check-<job>` run on their own timers with their
own gauges (`last_prune`, `last_check`, `check_success`). Three consequences:

1. `last_success` now means what its name says.
1. A failing check cannot mask a succeeding backup, and vice versa.
1. The exclusive-lock operation leaves the backup path — which is the **only** available
   mitigation, because `--retry-lock` cannot be reached through the module at all
   (`extraOptions` entries are each prefixed `-o `, and `extraBackupArgs` reaches only the
   `backup` subcommand; nixpkgs#468191, fix open ~a year). Staggered scheduling is therefore
   mandatory with two destinations, not hygiene.

`check` defaults to `--read-data-subset=10%`: structure plus a random tenth of pack data each
week, covering the repository in ~10 weeks while downloading a tenth per run. A bare structural
check proves index and metadata consistency but reads no pack data, so it cannot see bit rot in
the packs — the failure an off-site copy exists to survive.

## Decision 4 — no restic exporter

The Backups board is fed by config-derived textfile metrics, and for fan-out that **beats** an
exporter: a destination that is switched off publishes `enabled = 0` rather than going missing,
which is the distinction the board exists to draw. The two real gaps — repository size and check
status — are a few lines of `restic stats --json` / the check unit's own exit code into the
existing `.prom`, and `check_success` already landed with Decision 3.

## Risk recorded: upstream is moving the other way

The active nixpkgs rewrite (PR #492460) restructures `services.restic` on the **opposite** axis —
many jobs into one repository — whereas this design is destinations × jobs. If that lands, the
generator here may need rework. Not a reason to wait on an unmerged PR, but the reason this ADR
names it.

## Rollout

| Phase | What | State |
| --- | --- | --- |
| 0 | Separate backup / prune / check; first real `check` | **done 2026-10-05** |
| 1 | Refactor to a `destinations` attrset, rsync.net only; move the daily job to 03:00/15:00 | **done 2026-10-05** |
| 2 | B2 bucket + no-delete key; hand-`init` with matched chunker params; enable on rk1b | pending, needs the account |
| 3 | kelpy, porcupineFish, sawtoothShark | pending |
| 4 | Automated restore drill with its own metric (palimpsest#150) | pending |

Phase 1 also fixed an RPO gap visible in the live snapshots: Immich dumps its database at 02:00
while the backup ran at 00/6:00, so a snapshot paired metadata up to 22h older than the files
beside it. Assets would restore onto disk that the database cannot see. Running at 03:00 and
15:00 puts the dump an hour ahead of the day's first snapshot; the 15:00 run trades that for a
12h file RPO, and a restore wanting the consistent pair picks the 03:00 one.

Phase 3 on kelpy is the largest single win and deserves its own change: flipping
`backup.enable` there ships the Supernote document library — palimpsest#150's stated highest
priority — and the `pictures` annex, and activates the ADR-0031 exclude assertion that has been
dormant since it was written.

______________________________________________________________________

## Revision — 2026-10-05: phase 1 landed, and it corrected Decision 3

The `destinations` × `jobs` cross product is in (`modules/nixos/profiles/backup.nix`), rsync.net
is its only entry, and a host now declares *what* it backs up
(`custom.profiles.backup.jobs.<name>`) while the profile owns *where* it goes. Adding B2 in
phase 2 is one `destinations.b2` entry: no host edits, no hand-written units, no metric
plumbing. Three things were learned doing it, and the first contradicts Decision 3 above.

**1. `prune` and `check` are per REPOSITORY, not per job.** Decision 3 split them out of the
backup unit — right — but kept them keyed by job, which only looked correct while rk1b was the
only host backing up. The fleet's hosts all write into **one** rsync.net repository (snapshots
are told apart by restic's own hostname field), so `restic-check-daily` and
`restic-check-telemetry` would have downloaded and verified the *same* repository twice, and
four hosts' prune units would have repacked the same packs while fighting for the same
exclusive lock. They are now `restic-prune-<destination>` / `restic-check-<destination>`, and a
per-destination `maintenance` flag elects **one host** to run them. Their metrics lose the
`restic_job` label and gain `restic_dest`, which is what they always meant.

**2. Retention was unscoped, and that was a latent data-loss bug.** `restic forget` is explicit
that with no snapshot filter "all snapshots are first divided into groups according to
`--group-by`" (default `host,paths`) "and after that the policy specified by the `--keep-*`
options is applied to each group individually" — i.e. it considers the **whole repository**. So
`restic-prune-daily` on rk1b was applying rk1b's `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` to *every* group in the shared repository. Harmless only by accident: rk1b is
the sole host backing up today and telemetry is off. The moment phase 3 enabled kelpy, rk1b's
policy would have started expiring kelpy's snapshots, and daily's policy telemetry's.

Fixed by scoping retention to `--host <this host> --tag <job>`, with every snapshot now tagged
with its job name (`extraBackupArgs = [ "--tag <job>" ]`). The failure direction is deliberately
safe: if the filters ever match nothing, snapshots are kept rather than deleted. Snapshots
written before this change carry no tag and must be retagged once per repository
(`restic tag --add <job> --host <host>`), or they are immortal.

**3. `forget` takes an exclusive lock even without `--prune`** — `cmd_forget.go` in v0.19.1
opens with `openWithExclusiveLock` unconditionally. So splitting retention into its own unit
relocates lock contention rather than removing it, and on a shared repository several hosts'
weekly `forget` runs *will* collide. The mitigation is `--retry-lock`, which is reachable here
only because these units are hand-written: it still cannot be passed to the module's own backup
unit (nixpkgs#468191). Retention, prune and check therefore all wait rather than fail; the
backup itself still relies on staggered scheduling, which is why that is now a build-time
assertion rather than a comment.

Also added, because the refactor made them cheap: a build failure when an enabled job has no
paths (restic exits 0 having backed up nothing — the quiet failure `hosts/rk1/backup.nix`
warns about in prose), and a build failure when one job fires at the same minute on two
destinations. And the Backups board gained the verification table that Decision 4 promised:
`check_success` and the last check/prune ages, per repository.

One test property is worth naming, because it is what the refactor bought: destinations being
data means `parts/checks/backup-status` can declare a **local-disk** destination and run real
restic against it. It creates another host's snapshots and another job's snapshots in one
repository, runs retention with `--keep-last 1`, and asserts that only this host's own job lost
a snapshot. That is the bug in (2), pinned where reading the code had missed it.
