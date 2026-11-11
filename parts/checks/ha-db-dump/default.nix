{
  self,
  pkgs,
  ...
}:

# The nightly Home Assistant recorder dump (modules/nixos/profiles/ha-db-dump.nix), which is the
# ONLY copy of this house's history that reaches off-site storage: rk1a's restic job excludes the
# live `home-assistant_v2.db` because a file-level copy of an open WAL database is not a
# restorable artifact, and ships these dumps instead.
#
# So the property under test is not "a file appeared". It is that the file is a COMPLETE,
# STANDALONE database that can be read back — because the failure this whole arrangement guards
# against is a backup holding something database-shaped that nothing can open, discovered during
# a restore. Case 2 therefore queries the dump rather than stat-ing it, and does so with nothing
# of the original beside it.
#
# ⚠ CASE 1 IS WHERE THIS DIVERGES FROM ITS PAPERLESS TWIN, and the divergence is the point:
# an absent database exits 0 here and 1 there. Home Assistant creates its recorder on first
# start and recreates it if it finds it corrupt, so "no database" is an ordinary state on a
# freshly deployed host rather than a fault — and failing on it would buy nothing, because what
# a failure protects is the backup, and ha-dump-freshness.nix handles the absent-database case
# itself by passing (nothing is excluded, so nothing is missing). Pinned as a case because it is
# the kind of asymmetry a later "make these two consistent" refactor would quietly delete.
#
# No VM: the script's contract is (config directory, environment) -> (exit code, files on disk),
# so a derivation running the REAL script against a real SQLite database covers all of it in
# seconds and needs no KVM. The script is imported from the file the profile imports — not a
# copy, which would pass while the live one rotted.
#
# ⚠ The script calls `sqlite3`, `find`, `date` and `stat` through PATH; the unit supplies them via
# `path` and this check supplies the same closure in `nativeBuildInputs`. A missing entry there
# is a build failure here, which is the point.

let
  configDir = "/tmp/hass-state";
  keep = 3;

  # A stub `post`, so the check needs no webhook, no secrets and no network — and so a case can
  # assert that an alert WAS raised, by looking for the line it prints.
  post = ''
    post() { echo "ALERT: $1"; }
  '';

  dump = import (self + /modules/nixos/profiles/ha-db-dump.nix) {
    inherit
      pkgs
      configDir
      keep
      post
      ;
    inherit (pkgs) lib;
    hostName = "testhost";
  };
in
pkgs.runCommand "check-ha-db-dump"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.sqlite
    ];
  }
  ''
    set -euo pipefail

    config_dir=${configDir}
    db="$config_dir/home-assistant_v2.db"

    # Runs the script and captures both its exit code and its output, so a case can assert on the
    # operator-facing text as well as the status.
    #
    # `said_text`, NOT `out`: these have to be globals (the assertions below read them after the
    # call), and `$out` is the derivation's OUTPUT PATH. Clobbering it makes every case pass and
    # the build then fail with "failed to produce output path".
    run() {
      set +e
      said_text=$("${dump}" 2>&1)
      rc=$?
      set -e
    }

    expect() {
      local want="$1" desc="$2"
      run
      if [ "$rc" != "$want" ]; then
        echo "FAIL: $desc — expected exit $want, got $rc" >&2
        echo "  script said: $said_text" >&2
        exit 1
      fi
      echo "ok (exit $rc): $desc"
    }

    said() {
      if ! printf '%s' "$said_text" | grep -qF "$1"; then
        echo "FAIL: expected the script to say '$1'" >&2
        echo "  script said: $said_text" >&2
        exit 1
      fi
    }

    said_not() {
      if printf '%s' "$said_text" | grep -qF "$1"; then
        echo "FAIL: the script must NOT say '$1'" >&2
        echo "  script said: $said_text" >&2
        exit 1
      fi
    }

    reset() { rm -rf "$config_dir"; mkdir -p "$config_dir"; }

    # A recorder-shaped database: every table the nightly counts line names, in WAL mode as the
    # live one is. The shape is the real one — `schema_changes` is where the recorder records the
    # schema version a restore has to match (53 on rk1a, 2026-11-11), and `statistics` is the
    # long-term table, the one genuinely irreplaceable thing in here.
    #
    # Single-quoted literals throughout, and a heredoc so the shell does not eat them: modern
    # SQLite reads a DOUBLE-quoted literal as an IDENTIFIER.
    seed_db() {
      sqlite3 "$db" "
        PRAGMA journal_mode=WAL;
        create table states (state_id integer primary key, state text);
        create table events (event_id integer primary key, time_fired_ts real);
        create table statistics (id integer primary key, mean real);
        create table statistics_meta (id integer primary key, statistic_id text);
        create table schema_changes (change_id integer primary key, schema_version integer);
        insert into states (state) values ('on'), ('off'), ('unavailable');
        insert into events (time_fired_ts) values (1.0), (2.0);
        insert into statistics (mean) values (21.5), (22.0), (19.75), (20.0);
        insert into statistics_meta (statistic_id) values ('sensor.office_temperature');
        insert into schema_changes (schema_version) values (52), (53);
      " >/dev/null
    }

    newest_dump() {
      find "$config_dir" -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%T@ %p\n' \
        | sort -rn | head -1 | cut -d' ' -f2-
    }

    # ── 1. ⚠ NO DATABASE IS NOT A FAILURE HERE ─────────────────────────────────────────────
    # The inversion described in this file's header. A freshly deployed host has no recorder yet;
    # exiting 0 is the honest answer, and it must NOT alert — a 🚨 on every first boot is how an
    # alert channel gets muted.
    reset
    expect 0 "a missing home-assistant_v2.db exits 0 (fresh host, or recorder off)"
    said "does not exist"
    said_not "ALERT:"
    [ -z "$(newest_dump)" ] || { echo "FAIL: a dump appeared with no source database" >&2; exit 1; }

    # ── 2. ⚠ THE PROPERTY THE BACKUP RESTS ON ──────────────────────────────────────────────
    # A dump is taken, and it is a complete standalone database: opened on its own, with no `-wal`
    # beside it and no source in sight, it returns every row. This is the restore, in miniature.
    reset; seed_db
    expect 0 "a healthy recorder database produces a dump"
    said "integrity ok"
    said "3 states, 2 events, 4 long-term statistics rows (1 series)"
    # The schema version is on that line because restoring into a newer Home Assistant is a
    # one-way migration — knowing the dump's schema before taking that step is the difference
    # between a restore and an experiment.
    said "schema 53"

    d=$(newest_dump)
    [ -n "$d" ] || { echo "FAIL: no dump file was written" >&2; exit 1; }

    # Read it back somewhere else entirely, with nothing of the original beside it — a dump that
    # only opens next to its own WAL is not a backup. The statistics are what this checks, since
    # they are the rows nothing can regenerate.
    mkdir -p /tmp/restore && cp "$d" /tmp/restore/home-assistant_v2.db
    got=$(sqlite3 -readonly /tmp/restore/home-assistant_v2.db \
      "select group_concat(mean, '|') from statistics order by id;")
    want='21.5|22.0|19.75|20.0'
    if [ "$got" != "$want" ]; then
      echo "FAIL: the dump did not read back intact" >&2
      echo "  got:  $got" >&2
      echo "  want: $want" >&2
      exit 1
    fi
    [ "$(sqlite3 -readonly /tmp/restore/home-assistant_v2.db 'PRAGMA integrity_check;')" = "ok" ] \
      || { echo "FAIL: the restored copy fails integrity_check" >&2; exit 1; }
    echo "ok: the dump reads back intact as a standalone database"

    # And it is 0600. restic preserves modes, so a group- or world-readable dump stays that way
    # off-site and after a restore into somewhere laxer than hass's own 0700 directory.
    mode=$(stat -c %a "$d")
    [ "$mode" = "600" ] || { echo "FAIL: dump mode is $mode, expected 600" >&2; exit 1; }
    echo "ok: the dump is 0600"
    rm -rf /tmp/restore

    # ── 3. The dump glob cannot collide with the live triple ───────────────────────────────
    # The host EXCLUDES `home-assistant_v2.db*` and the freshness gate INCLUDES `db_*.sqlite3`,
    # both over this one directory. If the dump ever landed under a name the exclusion matched it
    # would never travel; if it landed under one the live triple matched, the gate would go green
    # over the live database. Pin that the two patterns stay disjoint.
    reset; seed_db
    touch "$db-wal" "$db-shm"
    expect 0 "a dump is taken beside the live triple"
    d=$(newest_dump)
    case "$(basename "$d")" in
      home-assistant_v2.db*)
        echo "FAIL: the dump is named $d, which the host's exclusion would drop" >&2; exit 1 ;;
    esac
    echo "ok: the dump's name is disjoint from the excluded home-assistant_v2.db* triple"

    # ── 4. A double-start is not an incident ───────────────────────────────────────────────
    # `VACUUM INTO` refuses to overwrite, so a second run inside the same UTC second would fail
    # the unit and page someone over "you already have this run's dump". It must exit 0 and leave
    # the existing dump alone.
    reset; seed_db
    export HA_DUMP_STAMP=20260101_024500
    expect 0 "the first run with a fixed stamp dumps"
    before=$(stat -c %s "$config_dir/db_20260101_024500.sqlite3")
    expect 0 "a second run in the same UTC second exits 0 without re-dumping"
    said "already exists"
    after=$(stat -c %s "$config_dir/db_20260101_024500.sqlite3")
    [ "$before" = "$after" ] || { echo "FAIL: the existing dump was modified" >&2; exit 1; }
    unset HA_DUMP_STAMP

    # ── 5. A schema change must not lose a good dump ───────────────────────────────────────
    # The counts line is a journal nicety; the integrity check is the gate. The vault's unit
    # failed a real night on this exact shape — a renamed column made `sqlite3` exit non-zero and
    # `set -e` threw away a perfectly good dump and skipped retention with it. Home Assistant
    # renames recorder tables between schema versions as a matter of course, so this is not a
    # hypothetical here.
    reset
    sqlite3 "$db" 'PRAGMA journal_mode=WAL; create table something_else (id integer);' >/dev/null
    expect 0 "a database without the recorder tables still dumps"
    said "counts unavailable"
    said "integrity ok"
    [ -n "$(newest_dump)" ] || { echo "FAIL: no dump survived the failed counts query" >&2; exit 1; }

    # ── 6. A garbage source leaves nothing behind ──────────────────────────────────────────
    # Something that is not a database where the database should be. The script must alert and
    # leave NO dump: a half-written file would be the newest in the directory, which is exactly
    # what makes the freshness gate green over an unopenable history.
    reset
    printf 'this is not a database' > "$db"
    expect 1 "a source that is not a database refuses"
    said "ALERT:"
    [ -z "$(newest_dump)" ] || { echo "FAIL: a dump was left behind: $(newest_dump)" >&2; exit 1; }

    # ── 7. Retention ───────────────────────────────────────────────────────────────────────
    # Nothing else prunes these. Unchecked, the config directory grows one full copy of the
    # recorder per run forever, on a host whose only real storage is a 29 GB eMMC already at 79%.
    # `keep` counts the newest INCLUDING the one just taken.
    reset; seed_db
    for age in 1 2 3 4 5; do
      touch -d "@$(( $(date +%s) - age * 86400 ))" \
        "$config_dir/db_2026010''${age}_024500.sqlite3"
    done
    expect 0 "a run with five old dumps present succeeds"
    said "pruning"
    count=$(find "$config_dir" -maxdepth 1 -type f -name 'db_*.sqlite3' | wc -l)
    [ "$count" = "${toString keep}" ] \
      || { echo "FAIL: ${toString keep} dumps should remain, found $count" >&2; exit 1; }
    # ...and the survivors are the NEWEST, with this run's among them. Pruning the wrong end
    # would keep the oldest copies and delete the one just verified.
    survivor=$(newest_dump)
    case "$survivor" in
      *db_2026010*) echo "FAIL: this run's dump was pruned, oldest kept: $survivor" >&2; exit 1 ;;
    esac
    [ "$(sqlite3 -readonly "$survivor" 'select count(*) from statistics;')" = "4" ] \
      || { echo "FAIL: the surviving newest dump is not this run's" >&2; exit 1; }
    echo "ok: retention keeps the ${toString keep} newest, this run's included"

    echo "SUCCESS: the Home Assistant recorder dump writes a complete, standalone, 0600 database that reads back intact and cannot collide with the excluded live triple; exits 0 WITHOUT alerting when there is no recorder yet; refuses and alerts on an unreadable source without leaving a half-dump behind; survives a schema change; tolerates a double-start; and prunes to the newest ${toString keep}."
    touch $out
  ''
