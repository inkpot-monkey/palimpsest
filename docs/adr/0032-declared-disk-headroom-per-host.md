# Disk headroom is a per-host declared number, defended and reported against

The fleet collected `node_filesystem_*` from every node and alerted on none of
it. `sawtoothShark`'s root filled to 91% and the first anyone heard was KDE's
free-space notifier on the desktop — after the fact, on one machine, with no
equivalent for the headless hosts at all. Meanwhile `rk1a` had spent 141 hours
under 5 GiB free on a 29 GiB card without anyone knowing.

Adding "an alert at 80%" would have been worse than nothing. This ADR records
why, and what replaced it.

## Decision

**Each host declares one number — `diskFloorGiB` in the fleet registry
(`parts/settings.nix`) — and it has two consumers.** The nix daemon defends it
as `min-free`, collecting mid-build before the disk fills
(`profiles/nixConfig.nix`); the disk-space watcher reports on it, alerting when
any real filesystem drops below it (`profiles/monitoring/disk-space.nix`). So
"this host must never have less than X free" is stated once and both enforced
and observed, and the two cannot drift into disagreeing about what counts as
dangerously full.

**Two tiers against that one number:** WARN under `2 ×` the floor, CRITICAL
under the floor itself, each debounced by an hour.

**The watcher is central, on `rk1b`, not per host.** Every other on-host check
here reads state only that host can see. Disk usage is not like that —
node-exporter already ships it fleet-wide — so one querying check covers
everything with no new secret anywhere. A check on each host would need
`infra_alerts_hook_id` keyed for five more of them, and sops here is
all-or-nothing per host, so that means re-keying every secret file to gain
nothing. The usual objection (a central check goes blind when the host it
watches is unreachable) does not bite: unreachability is already the
[ADR-0019](0019-uptime-alerting.md) probe's job, and a filling disk is a
days-long signal that does not need to survive a partition.

## Why not a percentage

Because it is unusable on a fleet whose devices span 29 GiB to 451 GiB. At 80%
used `sawtoothShark` still has ~90 GiB free and is entirely healthy, while
`rk1a` has 5.8 GiB and is one build from death. The same number means opposite
things.

This is measured, not asserted. `monitoring/disk-space-backtest.py` replays
candidate thresholds against retained history and reports how many alert
episodes each would have produced. Over the 48 days available:

- A flat `>=80%` rule would have held `sawtoothShark` **in alarm for 441 of its
  498 observed hours** — a permanent siren, which is how alerting becomes noise
  nobody reads.
- A free-**space** floor separates cleanly: every genuinely dangerous episode in
  the window sat under ~10 GiB free, and no comfortable device ever did.
- The floor cannot be fleet-wide either. `rk1b`'s SD card idles at 13.6 GiB free
  and is perfectly healthy, so a flat 15 GiB floor would have alarmed on it for
  **930 of 1155 hours**.

Hence per-host, and hence space rather than percentage. The debounce is measured
too: lengthening it from 1 h to 12 h removed only 2 of 13 episodes, so the short,
responsive value wins — `kelpy`'s root has moved 46 percentage points inside a
single day.

**Re-run the backtest before changing any threshold**, and put its summary in the
commit. Numbers picked without measuring are exactly what this ADR exists to
prevent.

## Deduplication is load-bearing, not tidiness

The impermanence hosts bind-mount dozens of paths off one device, and
node-exporter reports each mountpoint separately with identical numbers: `kelpy`
publishes **30 series for a single filesystem**, `rk1a` 15. Without
`max by (host, device)` one full disk on `kelpy` arrives as 30 alerts. The
selector is shared verbatim with the `Disk usage %` panel on the fleet-overview
dashboard so the board and the alert can never disagree. It also drops `tmpfs` —
four of five hosts have a tmpfs `/` by design, 1–2 GiB, which is not a disk and
would otherwise be either permanently alarming or permanently meaningless.

## Consequences

- **A host that is genuinely too small says so, loudly and permanently.** `rk1a`
  sits near its warn line on a 29 GiB card. That is the alert working: a capacity
  problem to fix on the host, not a threshold to tune around. Resist raising a
  floor to silence a host — that is the percentage mistake in another costume.
- **An unregistered node is still watched.** A host absent from the registry
  falls through to `defaultFloorGiB` rather than being silently skipped.
- **Alerts ride the shared delivery path**, so they inherit its out-of-band
  fallback ([ADR-0020](0020-out-of-band-web-push-relay.md)) — which matters here
  more than most, because two of the watched filesystems are `kelpy`'s and the
  in-band webhook routes through `kelpy`.
- **The nix daemon's valve is now real.** It was `min-free = 100 MiB` on a 451 GiB
  disk: dormant until the disk was essentially dead. Being derived from the same
  declared number, it can no longer be forgotten separately.
