{
  self,
  pkgs,
  ...
}:

# The nightly paperless dump script (modules/nixos/profiles/paperless-db-dump.nix), which is the
# ONLY copy of the document index that reaches off-site storage: kelpy's restic job excludes the
# live `db.sqlite3` because a file-level copy of an open WAL database is not a restorable
# artifact, and ships these dumps instead.
#
# So the property under test is not "a file appeared". It is that the file is a COMPLETE,
# STANDALONE database that can be read back — because the failure this whole arrangement guards
# against is a backup that holds something database-shaped that nothing can open, discovered
# during a restore. Case 2 therefore queries the dump rather than stat-ing it.
#
# It also pins the three ways the script must NOT fail the operator: a garbage source alerts and
# leaves nothing behind rather than a half-dump that would satisfy the freshness gate; a schema
# change degrades the journal line instead of losing a good dump (the lesson the vault's unit
# learned by failing a real night on a renamed column); and a double-start is not an incident.
#
# No VM: the script's contract is (data directory, environment) -> (exit code, files on disk),
# so a derivation running the REAL script against a real SQLite database covers all of it in
# seconds and needs no KVM. The script is imported from the file the profile imports — not a
# copy, which would pass while the live one rotted.
#
# ⚠ The script calls `sqlite3`, `find`, `date` and `stat` through PATH, exactly as the vault's
# inline dump script does; the unit supplies them via `path` and this check supplies the same
# closure in `nativeBuildInputs`. A missing entry there is a build failure here, which is the
# point.
#
# NOT covered, deliberately and worth knowing: the WAL-staleness case. `VACUUM INTO` is supposed
# to see committed data still sitting in the `-wal` (the vault's drill measured a live database
# eight days behind its own WAL), but provoking an uncheckpointed WAL from the sqlite3 CLI means
# holding a reader open across invocations to block the close-time checkpoint — a hang risk in
# CI for a property that is SQLite's, not this script's. What is covered is that a WAL-mode
# database dumps complete.

let
  dataDir = "/tmp/paperless-state";
  keep = 3;

  # A stub `post`, so the check needs no webhook, no secrets and no network — and so a case can
  # assert that an alert WAS raised, by looking for the line it prints.
  post = ''
    post() { echo "ALERT: $1"; }
  '';

  dump = import (self + /modules/nixos/profiles/paperless-db-dump.nix) {
    inherit
      pkgs
      dataDir
      keep
      post
      ;
    inherit (pkgs) lib;
    hostName = "testhost";
  };
in
pkgs.runCommand "check-paperless-db-dump"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.sqlite
    ];
  }
  ''
    set -euo pipefail

    data_dir=${dataDir}
    db="$data_dir/db.sqlite3"

    # Runs the script and captures both its exit code and its output, so a case can assert on
    # the operator-facing text as well as the status.
    #
    # `said_text`, NOT `out`: these have to be globals (the assertions below read them after the
    # call), and `$out` is the derivation's OUTPUT PATH. Clobbering it makes every case pass and
    # the build then fail with "failed to produce output path" — which is how this was found.
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

    reset() { rm -rf "$data_dir"; mkdir -p "$data_dir"; }

    # A paperless-shaped database: the `documents_document` table the counts query names, in WAL
    # mode as the live one is, with one soft-deleted row so the live/trash split is exercised
    # rather than just the total.
    # Single-quoted literals throughout, and a heredoc so the shell does not eat them: modern
    # SQLite reads a DOUBLE-quoted literal as an IDENTIFIER, so "Rent contract" is a missing
    # column, not a string.
    seed_db() {
      sqlite3 "$db" "
        PRAGMA journal_mode=WAL;
        create table documents_document (id integer primary key, title text, deleted_at text);
        insert into documents_document (title, deleted_at) values
          ('Rent contract', NULL),
          ('Tax return 2025', NULL),
          ('Scanned by mistake', '2026-11-01 10:00:00');
      " >/dev/null
    }

    newest_dump() {
      find "$data_dir" -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%T@ %p\n' \
        | sort -rn | head -1 | cut -d' ' -f2-
    }

    # ── 1. No database ─────────────────────────────────────────────────────────────────────
    # Paperless has never started here, or its data directory moved. The job's freshness gate
    # will refuse tonight either way; what matters is that this says so and alerts, rather than
    # exiting 0 having dumped nothing.
    reset
    expect 1 "a missing db.sqlite3 refuses"
    said "ALERT:"
    said "does not exist"

    # ── 2. ⚠ THE PROPERTY THE BACKUP RESTS ON ──────────────────────────────────────────────
    # A dump is taken, and it is a complete standalone database: opened on its own, with no
    # `-wal` beside it and no source in sight, it returns every row. This is the restore, in
    # miniature.
    reset; seed_db
    expect 0 "a healthy database produces a dump"
    said "integrity ok"
    said "3 documents (2 live, 1 in trash)"

    d=$(newest_dump)
    [ -n "$d" ] || { echo "FAIL: no dump file was written" >&2; exit 1; }

    # Read it back somewhere else entirely, with nothing of the original beside it — a dump that
    # only opens next to its own WAL is not a backup.
    mkdir -p /tmp/restore && cp "$d" /tmp/restore/db.sqlite3
    got=$(sqlite3 -readonly /tmp/restore/db.sqlite3 \
      "select group_concat(title, '|') from documents_document order by id;")
    want='Rent contract|Tax return 2025|Scanned by mistake'
    if [ "$got" != "$want" ]; then
      echo "FAIL: the dump did not read back intact" >&2
      echo "  got:  $got" >&2
      echo "  want: $want" >&2
      exit 1
    fi
    [ "$(sqlite3 -readonly /tmp/restore/db.sqlite3 'PRAGMA integrity_check;')" = "ok" ] \
      || { echo "FAIL: the restored copy fails integrity_check" >&2; exit 1; }
    echo "ok: the dump reads back intact as a standalone database"

    # And it is 0600. restic preserves modes, so a group- or world-readable dump stays that way
    # off-site and after a restore — in a 0755 directory, the file's own mode is the only thing
    # protecting a complete copy of the document index.
    mode=$(stat -c %a "$d")
    [ "$mode" = "600" ] || { echo "FAIL: dump mode is $mode, expected 600" >&2; exit 1; }
    echo "ok: the dump is 0600"
    rm -rf /tmp/restore

    # ── 3. A double-start is not an incident ───────────────────────────────────────────────
    # `VACUUM INTO` refuses to overwrite, so a second run inside the same UTC second would fail
    # the unit and page someone over "you already have tonight's dump". It must exit 0 and leave
    # the existing dump alone.
    reset; seed_db
    export PAPERLESS_DUMP_STAMP=20260101_024500
    expect 0 "the first run with a fixed stamp dumps"
    before=$(stat -c %s "$data_dir/db_20260101_024500.sqlite3")
    expect 0 "a second run in the same UTC second exits 0 without re-dumping"
    said "already exists"
    after=$(stat -c %s "$data_dir/db_20260101_024500.sqlite3")
    [ "$before" = "$after" ] || { echo "FAIL: the existing dump was modified" >&2; exit 1; }
    unset PAPERLESS_DUMP_STAMP

    # ── 4. A schema change must not lose a good dump ───────────────────────────────────────
    # The counts query is a journal nicety; the integrity check is the gate. The vault's unit
    # failed a real night on this exact shape — a renamed column made `sqlite3` exit non-zero
    # and `set -e` threw away a perfectly good dump and skipped retention with it.
    reset
    sqlite3 "$db" 'PRAGMA journal_mode=WAL; create table something_else (id integer);' >/dev/null
    expect 0 "a database without documents_document still dumps"
    said "counts unavailable"
    said "integrity ok"
    [ -n "$(newest_dump)" ] || { echo "FAIL: no dump survived the failed counts query" >&2; exit 1; }

    # ── 5. A garbage source leaves nothing behind ──────────────────────────────────────────
    # Something that is not a database where the database should be. The script must alert and
    # leave NO dump: a half-written file would be the newest in the directory, which is exactly
    # what makes the freshness gate green over an unopenable index.
    reset
    printf 'this is not a database' > "$db"
    expect 1 "a source that is not a database refuses"
    said "ALERT:"
    [ -z "$(newest_dump)" ] || { echo "FAIL: a dump was left behind: $(newest_dump)" >&2; exit 1; }

    # ── 6. Retention ───────────────────────────────────────────────────────────────────────
    # Nothing else prunes these. Unchecked, the data directory grows one full copy of the index
    # per night forever, on a host whose only real storage is 90G. `keep` counts the newest
    # INCLUDING the one just taken.
    reset; seed_db
    for age in 1 2 3 4 5; do
      touch -d "@$(( $(date +%s) - age * 86400 ))" \
        "$data_dir/db_2026010''${age}_024500.sqlite3"
    done
    expect 0 "a run with five old dumps present succeeds"
    said "pruning"
    count=$(find "$data_dir" -maxdepth 1 -type f -name 'db_*.sqlite3' | wc -l)
    [ "$count" = "${toString keep}" ] \
      || { echo "FAIL: ${toString keep} dumps should remain, found $count" >&2; exit 1; }
    # ...and the survivors are the NEWEST, with tonight's among them. Pruning the wrong end
    # would keep the oldest copies and delete the one just verified.
    survivor=$(newest_dump)
    case "$survivor" in
      *db_2026010*) echo "FAIL: tonight's dump was pruned, oldest kept: $survivor" >&2; exit 1 ;;
    esac
    [ "$(sqlite3 -readonly "$survivor" 'select count(*) from documents_document;')" = "3" ] \
      || { echo "FAIL: the surviving newest dump is not tonight's" >&2; exit 1; }
    echo "ok: retention keeps the ${toString keep} newest, tonight's included"

    echo "SUCCESS: the paperless dump script writes a complete, standalone, 0600 index that reads back intact; refuses and alerts on a missing or unreadable source without leaving a half-dump behind; survives a schema change; tolerates a double-start; and prunes to the newest ${toString keep}."
    touch $out
  ''
