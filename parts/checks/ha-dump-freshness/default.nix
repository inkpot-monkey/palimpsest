{
  self,
  pkgs,
  ...
}:

# The Home Assistant dump-freshness guard (modules/nixos/profiles/ha-dump-freshness.nix), wired
# into rk1a's restic `backupPrepareCommand` in hosts/rk1/ha-backup.nix.
#
# What is worth pinning is not "does it run" — it is that the guard refuses in each of the ways
# the recorder dump can stop, passes in the ways that mean it is still running, and passes in the
# one way that is NOT a fault at all. rk1a's job EXCLUDES the live `home-assistant_v2.db`, so a
# snapshot taken without a fresh dump carries this house's whole configuration with none of its
# past: no state history, and none of the long-term statistics the energy dashboard and every
# long-range graph are drawn from, which nothing regenerates.
#
# ⚠ TWO CASES CARRY THE DESIGN, and both are deliberate departures from this guard's paperless
# and vault siblings:
#
#   Case 3 — a live database with the dump timer dead must REFUSE. The dumps live in the SAME
#   directory as the database, so this directory is never empty and never without a `.sqlite3` in
#   it. A glob that matched `home-assistant_v2.db` would make the guard permanently green over a
#   dump that stopped months ago.
#
#   Case 4 — NO live database must PASS. This is the fix for kelpy's 2026-11-10 outage, where an
#   unconditional refusal on a fresh deploy took down the backup of everything else on the host.
#   With no database, the exclusion is hiding nothing: the snapshot is complete, and refusing it
#   would discard `.storage` — the half that matters most — to protect a history that does not
#   exist. A later "make these guards consistent" refactor would delete this, so it is a case.
#
#   Case 2 — the payload check, which neither sibling has. A targeted job's other failure is
#   paths that have drifted off the real state directory, and against that "a dump exists" is no
#   evidence whatsoever.
#
# No VM and no restic: the guard is pure shell over coreutils/findutils and its whole contract is
# (directory state) -> (exit code), so a derivation exercising the REAL script against synthetic
# directories tests all of it and runs in CI without KVM. The script is imported from the same
# file the host imports — deliberately not a copy, which would pass while the live one rotted.

let
  # 20h matches the threshold hosts/rk1/ha-backup.nix passes, so the boundary cases below are the
  # boundary the fleet actually runs. Kept as a literal rather than read back out of the host
  # config: this check is about the script's behaviour at its limit, and should keep testing both
  # sides of 20h even if a host later chooses a different one.
  maxAgeSeconds = 20 * 60 * 60;
  stateDir = "/tmp/hass-state";

  guard = import (self + /modules/nixos/profiles/ha-dump-freshness.nix) {
    inherit pkgs stateDir maxAgeSeconds;
  };
in
pkgs.runCommand "check-ha-dump-freshness"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    set -euo pipefail

    # The guard hardcodes its state_dir (it is baked from the service's configDir), so the
    # fixtures are built at that path rather than passed in.
    state_dir=${stateDir}

    expect() {
      local want="$1" desc="$2" said rc
      set +e
      said=$(${guard} 2>&1)
      rc=$?
      set -e
      if [ "$rc" != "$want" ]; then
        echo "FAIL: $desc — expected exit $want, got $rc" >&2
        echo "  guard said: $said" >&2
        exit 1
      fi
      echo "ok (exit $rc): $desc"
    }

    reset() { rm -rf "$state_dir"; }

    # Home Assistant's own store: config entries, the entity/device/area registries, the auth
    # store, the dashboards. The thing this job exists to carry, and what the payload check looks
    # for.
    storage() {
      mkdir -p "$state_dir/.storage"
      touch "$state_dir/.storage/core.config_entries" \
            "$state_dir/.storage/core.entity_registry" \
            "$state_dir/.storage/auth"
    }
    # The live recorder database and the two files SQLite keeps beside it — always present on a
    # running host, never a backup artifact.
    live() { mkdir -p "$state_dir"; touch "$state_dir/home-assistant_v2.db" \
               "$state_dir/home-assistant_v2.db-wal" "$state_dir/home-assistant_v2.db-shm"; }
    # The dump filename the unit writes: db_<UTC %Y%m%d_%H%M%S>.sqlite3, beside the database.
    dump() { mkdir -p "$state_dir"; touch -d "@$(( $(date +%s) - $1 ))" \
               "$state_dir/db_20260101_024500.sqlite3"; }

    # ── 1. No state directory at all ───────────────────────────────────────────────────────
    # Home Assistant is not on this host, or its state has moved and the job's paths point at
    # nothing.
    reset
    expect 1 "missing state directory refuses"

    # ── 2. ⚠ THE PAYLOAD CHECK ─────────────────────────────────────────────────────────────
    # A state directory with history but no `.storage` — the shape a drifted path leaves, and
    # also the shape of a half-restored host. A snapshot of it would come up as a blank Home
    # Assistant that happens to own this house's past: no bulbs, no voice pipeline, no
    # dashboards, no tokens. A fresh dump must NOT be enough to pass this.
    reset; live; dump 900
    expect 1 "history with no .storage refuses (even with a fresh dump)"

    # ...and an empty `.storage` is the same thing. A directory is not a payload.
    reset; live; dump 900; mkdir -p "$state_dir/.storage"
    expect 1 "an empty .storage refuses"

    # ── 3. ⚠ THE CASE THIS GUARD EXISTS FOR ────────────────────────────────────────────────
    # A live, healthy Home Assistant with its dump timer dead: the database is right there,
    # modified seconds ago, with its -wal and -shm beside it. The directory is non-empty,
    # something was written to it just now, and `.storage` is intact — and the house's whole past
    # would still be missing from tonight's snapshot, because the live triple is excluded.
    reset; storage; live
    expect 1 "the live database alone refuses (it is excluded from the backup)"

    # ── 4. ⚠ NO DATABASE PASSES, and this is not laxness ───────────────────────────────────
    # The fix for kelpy's 2026-11-10 outage. A freshly deployed host whose recorder has not
    # started yet: nothing is being excluded, so the snapshot is complete, and `.storage` — the
    # irreplaceable half — travels. Refusing here would be a guard for the recorder switching off
    # the backup of everything else.
    reset; storage
    expect 0 "no database at all passes (nothing is being excluded)"

    # ...including when old dumps are lying around from before the database was recreated.
    reset; storage; dump $(( 72 * 3600 ))
    expect 0 "no database passes even with only stale dumps beside it"

    # ── 5. Stale: comfortably past the limit ───────────────────────────────────────────────
    # The dead-timer case, after the last good dump aged out.
    reset; storage; live; dump $(( 72 * 3600 ))
    expect 1 "72h-old dump refuses"

    # ── 6/7. The boundary, both sides ──────────────────────────────────────────────────────
    # ${toString (maxAgeSeconds / 3600)}h is the limit and the comparison is `-gt`, so 19h passes
    # and 21h fails. A `>=`/`>` slip here is a one-character regression that decides whether a
    # healthy nightly trips the alarm every day or a dead one never does.
    reset; storage; live; dump $(( 19 * 3600 ))
    expect 0 "19h-old dump passes (just inside the limit)"

    reset; storage; live; dump $(( 21 * 3600 ))
    expect 1 "21h-old dump refuses (just outside the limit)"

    # ── 8. Steady state ───────────────────────────────────────────────────────────────────
    # The dump timer fires at 02:45 and 14:45 and restic runs at 03:00/15:00, so a healthy newest
    # dump is ~0.25h old at EVERY run. These are the cases that must never alarm.
    reset; storage; live; dump 900
    expect 0 "15m-old dump passes (steady state, just after a dump)"

    # ── 9. One missed dump is tolerated, two are not ───────────────────────────────────────
    # With dumps twice a day, a single skipped timer puts the next run at ~12h15m — weather, not
    # a fault, and the 20h limit is chosen to absorb exactly one. The run after a second
    # consecutive miss is ~24h15m and must refuse.
    reset; storage; live; dump $(( 49 * 900 ))
    expect 0 "12.25h-old dump passes (one missed dump is tolerated)"

    reset; storage; live; dump $(( 97 * 900 ))
    expect 1 "24.25h-old dump refuses (two consecutive misses are not)"

    # ── 10. Freshness is the NEWEST dump ──────────────────────────────────────────────────
    # `keep` is 3, so a directory of older dumps plus one fresh one is the normal shape — sorting
    # the wrong way round here would fail every healthy run.
    reset; storage; live; dump 900
    for age in 24 48; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$state_dir/db_2026010''${age}_024500.sqlite3"
    done
    expect 0 "fresh dump among older ones passes (newest wins)"

    # ── 11. ...and the converse ───────────────────────────────────────────────────────────
    # Three dumps, none fresh. Guards against an "any dump at all" read of the previous case —
    # the exact shape a dead timer leaves behind after two days.
    reset; storage; live
    for age in 24 48 72; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$state_dir/db_2026010''${age}_024500.sqlite3"
    done
    expect 1 "three dumps but none fresh refuses"

    echo "SUCCESS: the Home Assistant dump-freshness guard refuses an absent or payload-less state directory, a live database with no fresh dump, and a stale one — while passing a live nightly dump, one missed dump, and the fresh-host case where there is no database to exclude at all."
    touch $out
  ''
