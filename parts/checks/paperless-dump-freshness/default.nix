{
  self,
  pkgs,
  ...
}:

# The paperless dump-freshness guard (modules/nixos/profiles/paperless-dump-freshness.nix),
# wired into kelpy's restic `backupPrepareCommand` in hosts/kelpy/configuration.nix.
#
# What is worth pinning is not "does it run" — it is that the guard refuses in each of the ways
# the nightly `VACUUM INTO` dump can stop, and passes in the one way that means it is still
# running. kelpy's job EXCLUDES paperless's live db.sqlite3, so a snapshot taken without a fresh
# dump carries the scanned originals under media/ and NO RECORD OF WHAT THEY ARE — no
# correspondents, tags, dates, OCR content or row-to-file mapping — with restic reporting success
# over it.
#
# Case 3 is the one that matters most and the reason the glob is the whole guard: the dumps live
# in the SAME directory as the live database, so this directory is never empty and never without
# a `.sqlite3` in it. A glob that matched `db.sqlite3` — or its `-wal`/`-shm` siblings, or
# `celerybeat-schedule.db` — would make the guard permanently green over a dump that stopped
# months ago.
#
# A near-twin of parts/checks/vaultwarden-dump-freshness, deliberately, because the guards are
# near-twins; the fixtures differ where paperless's directory does (media/, consume/, the
# celerybeat database).
#
# No VM and no restic: the guard is pure shell over coreutils/findutils and its whole contract is
# (directory state) -> (exit code), so a derivation exercising the REAL script against synthetic
# directories tests all of it and runs in CI without KVM. The script is imported from the same
# file the host imports — deliberately not a copy, which would pass while the live one rotted.

let
  # 20h matches the threshold hosts/kelpy/configuration.nix passes, so the boundary cases below
  # are the boundary the fleet actually runs. Kept as a literal rather than read back out of the
  # host config: this check is about the script's behaviour at its limit, and should keep testing
  # both sides of 20h even if a host later chooses a different one.
  maxAgeSeconds = 20 * 60 * 60;
  dumpDir = "/tmp/paperless-state";

  guard = import (self + /modules/nixos/profiles/paperless-dump-freshness.nix) {
    inherit pkgs dumpDir maxAgeSeconds;
  };
in
pkgs.runCommand "check-paperless-dump-freshness"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    set -euo pipefail

    # The guard hardcodes its dump_dir (it is baked from the profile's dataDir), so the fixtures
    # are built at that path rather than passed in.
    dump_dir=${dumpDir}

    expect() {
      local want="$1" desc="$2" out rc
      set +e
      out=$(${guard} 2>&1)
      rc=$?
      set -e
      if [ "$rc" != "$want" ]; then
        echo "FAIL: $desc — expected exit $want, got $rc" >&2
        echo "  guard said: $out" >&2
        exit 1
      fi
      echo "ok (exit $rc): $desc"
    }

    reset() { rm -rf "$dump_dir"; }
    # The dump filename the unit writes: db_<UTC %Y%m%d_%H%M%S>.sqlite3, beside the database.
    dump()  { mkdir -p "$dump_dir"; touch -d "@$(( $(date +%s) - $1 ))" \
                "$dump_dir/db_20260101_024500.sqlite3"; }
    # The live database and the two files SQLite keeps beside it — always present, never a
    # backup artifact.
    live()  { mkdir -p "$dump_dir"; touch "$dump_dir/db.sqlite3" \
                "$dump_dir/db.sqlite3-wal" "$dump_dir/db.sqlite3-shm"; }

    # 1. No data directory at all: paperless is not on this host, or its state has moved and
    #    the job's paperless paths point at nothing.
    reset
    expect 1 "missing data directory refuses"

    # 2. The directory exists and holds nothing.
    reset; mkdir -p "$dump_dir"
    expect 1 "empty data directory refuses"

    # 3. ⚠ THE CASE THIS GUARD EXISTS FOR. A live, healthy paperless with its dump timer dead:
    #    the database is right there, modified seconds ago, with its -wal and -shm beside it.
    #    The directory is non-empty, something was written to it just now, and there is a
    #    `.sqlite3` in it — and there is still NOTHING to restore, because the live triple is
    #    excluded from the snapshot.
    reset; live
    expect 1 "the live database alone refuses (it is excluded from the backup)"

    # 4. The rest of a real paperless data directory is in here too and IS backed up — the
    #    scanned originals most of all. None of it is an index.
    reset; live
    mkdir -p "$dump_dir/media/documents/originals" "$dump_dir/consume"
    touch "$dump_dir/media/documents/originals/0000001.pdf" \
          "$dump_dir/celerybeat-schedule.db" \
          "$dump_dir/nixos-paperless-secret-key"
    expect 1 "a populated data directory with documents but no dump refuses"

    # 5. Stale: comfortably past the limit. The dead-timer case, after the last good dump aged
    #    out.
    reset; live; dump $(( 72 * 3600 ))
    expect 1 "72h-old dump refuses"

    # 6/7. The boundary, both sides. ${toString (maxAgeSeconds / 3600)}h is the limit and the
    #      comparison is `-gt`, so 19h passes and 21h fails. A `>=`/`>` slip here is a
    #      one-character regression that decides whether a healthy nightly trips the alarm every
    #      day or a dead one never does.
    reset; live; dump $(( 19 * 3600 ))
    expect 0 "19h-old dump passes (just inside the limit)"

    reset; live; dump $(( 21 * 3600 ))
    expect 1 "21h-old dump refuses (just outside the limit)"

    # 8. Steady state: the dump timer fires at 02:45 and restic runs at 03:00/15:00, so a
    #    healthy newest dump is ~0.25h old at the first run and ~12.25h at the second. These are
    #    the cases that must never alarm.
    reset; live; dump 900
    expect 0 "15m-old dump passes (steady state, just after the 02:45 dump)"

    reset; live; dump $(( 49 * 900 ))
    expect 0 "12.25h-old dump passes (the 15:00 run)"

    # 9. ...and one missed dump must FAIL, as on the vault and unlike the Immich guard which
    #    tolerates one on purpose. The dump unit here verifies its own artifact and alerts when
    #    it cannot, so a miss is a bug rather than weather — 24.25h is the 03:00 run after a
    #    missed night.
    reset; live; dump $(( 97 * 900 ))
    expect 1 "24.25h-old dump refuses (one missed night is NOT tolerated here)"

    # 10. Freshness is the NEWEST dump, not the oldest or an arbitrary one. `keep` is 3, so a
    #     directory of older dumps plus one fresh one is the normal shape — sorting the wrong way
    #     round here would fail every healthy night.
    reset; live; dump 900
    for age in 24 48; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$dump_dir/db_2026010''${age}_024500.sqlite3"
    done
    expect 0 "fresh dump among older ones passes (newest wins)"

    # 11. ...and the converse: three dumps, none fresh. Guards against an "any dump at all" read
    #     of the previous case — the exact shape a dead timer leaves behind for two nights.
    reset; live
    for age in 24 48 72; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$dump_dir/db_2026010''${age}_024500.sqlite3"
    done
    expect 1 "three dumps but none fresh refuses"

    echo "SUCCESS: the paperless dump-freshness guard refuses an absent, empty, dump-less or stale data directory — the live database and a full media tree included — and passes a live nightly dump."
    touch $out
  ''
