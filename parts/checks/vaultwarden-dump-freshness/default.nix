{
  self,
  pkgs,
  ...
}:

# The vault dump-freshness guard (modules/nixos/profiles/vaultwarden-dump-freshness.nix),
# wired as kelpy's restic `backupPrepareCommand` in hosts/kelpy/configuration.nix (users#57).
#
# What is worth pinning is not "does it run" — it is that the guard refuses in each of the
# ways the nightly `VACUUM INTO` dump can stop, and passes in the one way that means it is
# still running. The consequence of getting it backwards is worse here than for its Immich
# sibling: kelpy's job EXCLUDES the live db.sqlite3, so a snapshot taken without a fresh dump
# carries the attachments, the sends and the RSA keypair and NO VAULT AT ALL, with restic
# reporting success over it.
#
# Case 3 is the one that does not exist in the Immich check and is the reason this file is not
# a copy of it. The dumps live in the SAME directory as the live database, so this directory is
# never empty and never without a `.sqlite3` in it. A glob that matched `db.sqlite3` — or its
# `-wal`/`-shm` siblings — would make the guard permanently green over a dump that stopped
# months ago, which is precisely the state it exists to catch.
#
# The `-gt` boundary gets both sides explicitly. A `>=`/`>` slip there is a one-character
# regression no other test would notice, and it decides whether a healthy nightly dump trips
# the alarm every day or a dead one never does.
#
# No VM and no restic: the guard is pure shell over coreutils/findutils and its whole contract
# is (directory state) -> (exit code), so a derivation exercising the REAL script against
# synthetic dump directories tests all of it and runs in CI without KVM. The script is imported
# from the same file the host imports — deliberately not a copy, which would pass while the
# live one rotted.

let
  # 20h matches the threshold hosts/kelpy/configuration.nix passes, so the boundary cases below
  # are the boundary the fleet actually runs. Kept as a literal rather than read back out of the
  # host config: this check is about the script's behaviour at its limit, and should keep
  # testing both sides of 20h even if a host later chooses a different one.
  maxAgeSeconds = 20 * 60 * 60;
  dumpDir = "/tmp/vaultwarden-state";

  guard = import (self + /modules/nixos/profiles/vaultwarden-dump-freshness.nix) {
    inherit pkgs dumpDir maxAgeSeconds;
  };
in
pkgs.runCommand "check-vaultwarden-dump-freshness"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    set -euo pipefail

    # The guard hardcodes its dump_dir (it is baked from the profile's dataDir), so the
    # fixtures are built at that path rather than passed in.
    dump_dir=${dumpDir}

    # Asserts the guard's exit code, printing its output on a surprise so a failing build says
    # which case broke and what the guard actually said.
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
    # Upstream's filename: db_<UTC %Y%m%d_%H%M%S>.sqlite3, written beside the database.
    dump()  { mkdir -p "$dump_dir"; touch -d "@$(( $(date +%s) - $1 ))" \
                "$dump_dir/db_20260101_023000.sqlite3"; }
    # The live database and the two files SQLite keeps beside it — always present, never a
    # backup artifact.
    live()  { mkdir -p "$dump_dir"; touch "$dump_dir/db.sqlite3" \
                "$dump_dir/db.sqlite3-wal" "$dump_dir/db.sqlite3-shm"; }

    # 1. No state directory at all: the vault is not on this host, or its state has moved and
    #    every path in the job points at nothing.
    reset
    expect 1 "missing state directory refuses"

    # 2. The directory exists and holds nothing.
    reset; mkdir -p "$dump_dir"
    expect 1 "empty state directory refuses"

    # 3. ⚠ THE CASE THIS GUARD EXISTS FOR. A live, healthy vault with its dump timer dead: the
    #    database is right there, modified seconds ago, with its -wal and -shm beside it. The
    #    directory is non-empty, something was written to it just now, and there is a `.sqlite3`
    #    in it — and there is still NOTHING to restore, because the live triple is excluded from
    #    the snapshot. The glob is what decides, and this is the case that proves it.
    reset; live
    expect 1 "the live database alone refuses (it is excluded from the backup)"

    # 4. The attachments and the RSA keypair are in this directory too, and are backed up — but
    #    they are not a vault either.
    reset; live; mkdir -p "$dump_dir/attachments"; touch "$dump_dir/rsa_key.pem"
    expect 1 "a populated state directory with no dump refuses"

    # 5. Stale: comfortably past the limit. The dead-timer case, after the last good dump aged
    #    out.
    reset; live; dump $(( 72 * 3600 ))
    expect 1 "72h-old dump refuses"

    # 6/7. The boundary, both sides. ${toString (maxAgeSeconds / 3600)}h is the limit and the
    #      comparison is `-gt`, so 19h passes and 21h fails.
    reset; live; dump $(( 19 * 3600 ))
    expect 0 "19h-old dump passes (just inside the limit)"

    reset; live; dump $(( 21 * 3600 ))
    expect 1 "21h-old dump refuses (just outside the limit)"

    # 8. Steady state: the dump timer fires at 02:30 and restic runs at 03:00/15:00, so a
    #    healthy newest dump is ~0.5h old at the first run and ~12.5h at the second. These are
    #    the cases that must never alarm.
    reset; live; dump 1800
    expect 0 "30m-old dump passes (steady state, just after the 02:30 dump)"

    reset; live; dump $(( 25 * 1800 ))
    expect 0 "12.5h-old dump passes (the 15:00 run)"

    # 9. ...and one missed dump must FAIL here, unlike the Immich guard which tolerates it. The
    #    dump unit on this host verifies its own work and alerts when it cannot, so a miss is a
    #    bug rather than weather — 24.5h is the 03:00 run after a missed night.
    reset; live; dump $(( 49 * 1800 ))
    expect 1 "24.5h-old dump refuses (one missed night is NOT tolerated here)"

    # 10. Freshness is the NEWEST dump, not the oldest or an arbitrary one. `keep` is 3, so a
    #     directory of older dumps plus one fresh one is the normal shape — sorting the wrong
    #     way round here would fail every healthy night.
    reset; live; dump 1800
    for age in 24 48; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$dump_dir/db_2026010''${age}_023000.sqlite3"
    done
    expect 0 "fresh dump among older ones passes (newest wins)"

    # 11. ...and the converse: three dumps, none fresh. Guards against an "any dump at all" read
    #     of the previous case — the exact shape a dead timer leaves behind for two nights.
    reset; live
    for age in 24 48 72; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$dump_dir/db_2026010''${age}_023000.sqlite3"
    done
    expect 1 "three dumps but none fresh refuses"

    echo "SUCCESS: the vault dump-freshness guard refuses an absent, empty, dump-less or stale state directory — the live database included — and passes a live nightly dump."
    touch $out
  ''
