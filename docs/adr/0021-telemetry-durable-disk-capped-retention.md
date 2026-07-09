# Telemetry is a durable data class: disk-capped retention + snapshot→restic backup

When the **monitoring server** moves from `kelpy` to `rk1b` (see
`.scratch/kelpy-offload/issues/01`), we had to decide how its **telemetry**
(VictoriaMetrics samples + VictoriaLogs lines) is retained and protected. We
treat telemetry as its own data class — neither a **blob** (git-annex) nor
**service state** (restic of `/persistent`) — with two distinct properties:
**bounded so it cannot fill its disk**, and **durable so it survives `rk1b`
dying**. It is explicitly *not* disposable.

## Decision

**Retention is bounded by disk, not just time.** A time-only window can be
breached by a log spike well before it elapses, wedging the partition. So:

- VictoriaLogs: `-retention.maxDiskSpaceUsageBytes` ≈ **20 GiB**, plus a **30 d**
  backstop window. Logs are the bulky, spiky kind — cap them by *size*.
- VictoriaMetrics: `retentionPeriod` cut **12 mo → 3 mo**, plus
  `-storage.minFreeDiskSpaceBytes` ≈ **10 GiB** as the can't-overflow valve that
  halts ingestion before the partition fills.

**Telemetry is backed up by consistent-snapshot → restic → rsync.net**, as its
own `restic.backups.telemetry` entry (separate keep-policy from service-state's
`backups.daily`, e.g. keep-daily 7), every ~6 h. The backup is taken from a
**VM-created snapshot** (`/snapshot/create`, a consistent hardlink view), never
from the live data directory — restic-ing a churning TSDB dir risks an
unrestorable copy. RPO ≈ one backup interval (~6 h).

**Rejected: a hot replica.** `vmagent` dual remote-write gives RPO≈0 but forces
a *second* running TSDB onto another always-on host — and the only candidate is
`kelpy`, the box this whole epic is unloading. Self-defeating. Losing ≤6 h of
graphs on a disk death is acceptable for non-critical telemetry.

**Rejected: git-annex for telemetry.** git-annex is content-addressed; a
constantly-compacting TSDB would explode the annex with per-write blob churn.
git-annex stays the store for **blobs** only.

## Enabling change: repartition `rk1b`'s NVMe

The telemetry data dirs must live on the NVMe, not the eMMC. Inspection showed
the NVMe layout was badly skewed — `/nix` was a **400 GiB** partition holding an
**18 GiB** store (95 % idle, live closure only 6.5 GiB), while the data
partition (`rk1cache`) was 76 GiB. We repartition to **`/nix` 128 GiB**
(≈7× current — generous headroom for `rk1b`'s role as the fleet's aarch64
build-offload node, whose store balloons transiently during big builds) and
**`rk1cache` ≈ 349 GiB** for telemetry + paperless. Done live over ssh
(no BMC): GC the store to ~7 GiB, `relocateNixStore = false` so it parks on
eMMC, recreate the GPT, then `relocateNixStore = true` to move it back. Media is
*not* sized here — it gets its own disk.

## Consequences

- Telemetry history is bounded by **disk**, so a noisy period shortens the
  window rather than crashing the box. "Cannot fill the disk" is a guarantee.
- On `rk1b` disk death, ≤ ~6 h of telemetry is lost; everything older is
  restorable from rsync.net.
- Small recurring rsync.net cost for ~15–30 GiB of deduped telemetry backup.
- `kelpy` keeps zero monitoring write-IO (the original abuse cause) — no replica
  is pushed back onto it.
