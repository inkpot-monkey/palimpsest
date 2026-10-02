{
  self,
  pkgs,
  ...
}:

# The Immich database-dump freshness guard
# (modules/nixos/profiles/immich-db-dump-freshness.nix), wired as rk1b's restic
# `backupPrepareCommand` in hosts/rk1/backup.nix.
#
# What is worth pinning is not "does it run" — it is that the guard FAILS in each of the three
# ways Immich's own database backup can silently stop, and succeeds in the one way that means
# it is still running. Get any of those backwards and the result is the exact failure the guard
# exists to prevent: restic ships photo files with a stale or absent database dump, stamps
# last-success, and the Backups board goes green over a snapshot that cannot restore an album.
#
# The `-gt` boundary gets both sides explicitly. A `>=`/`>` slip there is a one-character
# regression that no other test would notice, and it decides whether a healthy nightly dump
# trips the alarm every day or a dead one never does.
#
# No VM and no restic: the guard is pure shell over coreutils/findutils and its whole contract
# is (directory state) -> (exit code), so a derivation exercising the REAL script against
# synthetic dump directories tests all of it and runs in CI without KVM. The script is imported
# from the same file the host imports — deliberately not a copy, which would pass while the
# live one rotted.

let
  # 48h matches the threshold hosts/rk1/backup.nix passes, so the boundary cases below are the
  # boundary the fleet actually runs. Kept as a literal rather than read back out of the host
  # config: this check is about the script's behaviour at its limit, and should keep testing
  # both sides of 48h even if a host later chooses a different one.
  maxAgeSeconds = 48 * 60 * 60;
  dumpDir = "/tmp/immich-backups";

  guard = import (self + /modules/nixos/profiles/immich-db-dump-freshness.nix) {
    inherit pkgs dumpDir maxAgeSeconds;
  };
in
pkgs.runCommand "check-immich-db-dump-freshness"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    set -euo pipefail

    # The guard hardcodes its dump_dir (it is baked from the host's mediaLocation), so the
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
    dump()  { mkdir -p "$dump_dir"; touch -d "@$(( $(date +%s) - $1 ))" \
                "$dump_dir/immich-db-backup-20260101T020000-v3.2.2-pg17.11.sql.gz"; }

    # 1. Immich's database backup has never run — the directory is not even there.
    reset
    expect 1 "missing dump directory refuses"

    # 2. Directory exists but holds no dump. This is the shape left behind when the dump is
    #    switched off in Immich's admin UI after having run: the folder survives, empty.
    reset; mkdir -p "$dump_dir"
    expect 1 "empty dump directory refuses"

    # 3. A file that is not a dump must not count as one. Immich's own `.immich` marker lives
    #    in this directory, so "directory is non-empty" is NOT evidence a dump exists — the
    #    glob is what decides, and this is the case that proves it is doing the deciding.
    reset; mkdir -p "$dump_dir"
    touch "$dump_dir/.immich" "$dump_dir/some-other-file.sql.gz"
    expect 1 "non-dump files alone refuse"

    # 4. Stale: comfortably past the limit. The dead-dump case.
    reset; dump $(( 72 * 3600 ))
    expect 1 "72h-old dump refuses"

    # 5/6. The boundary, both sides. ${toString (maxAgeSeconds / 3600)}h is the limit and the
    #      comparison is `-gt`, so 47h passes and 49h fails.
    reset; dump $(( 47 * 3600 ))
    expect 0 "47h-old dump passes (just inside the limit)"

    reset; dump $(( 49 * 3600 ))
    expect 1 "49h-old dump refuses (just outside the limit)"

    # 7. Steady state: Immich dumps at 02:00 and restic runs at 00/6:00, so a healthy newest
    #    dump is ~22h old at the 00:00 run. The case that must NOT alarm, every single night.
    reset; dump $(( 22 * 3600 ))
    expect 0 "22h-old dump passes (steady state)"

    # 8. Freshness is the NEWEST dump, not the oldest or an arbitrary one. Immich keeps several
    #    (five on rk1b), so a directory of old dumps plus one fresh one is the normal shape —
    #    sorting the wrong way round here would fail every healthy night.
    reset; dump $(( 6 * 3600 ))
    for age in 200 300 400; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$dump_dir/immich-db-backup-2025010''${age}T020000-v3.2.2-pg17.11.sql.gz"
    done
    expect 0 "fresh dump among older ones passes (newest wins)"

    # 9. ...and the converse: many dumps, none fresh. Guards against a "any dump at all" read
    #    of the previous case.
    reset; mkdir -p "$dump_dir"
    for age in 200 300 400; do
      touch -d "@$(( $(date +%s) - age * 3600 ))" \
        "$dump_dir/immich-db-backup-2025010''${age}T020000-v3.2.2-pg17.11.sql.gz"
    done
    expect 1 "many dumps but none fresh refuses"

    echo "SUCCESS: the dump-freshness guard refuses absent, empty, non-dump and stale states, and passes a live nightly dump."
    touch $out
  ''
