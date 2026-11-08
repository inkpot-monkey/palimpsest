# A restic `backupPrepareCommand` that refuses to ship a kelpy snapshot with no paperless
# database in it.
#
# WHY THIS EXISTS. Paperless keeps two halves of one archive: the scanned originals under
# `media/`, which are ordinary inert files, and `db.sqlite3`, which is the only record of what
# any of them ARE — correspondent, type, tags, dates, the OCR'd content every search runs
# against, and the filename mapping that ties a row to a file on disk. Restore the media
# without the database and what comes back is a directory of PDFs named by a format string;
# the archive is gone even though every byte of it is present.
#
# That database is open with WAL, so it is excluded from the backup for the same reason the
# vault's is: a file-level copy of an open SQLite database is a torn page set, and the
# `-wal`/`-shm` pair cannot be captured atomically beside it. What travels instead is the
# nightly `VACUUM INTO` dump that `paperless-db-dump.service` writes as `db_<UTC>.sqlite3`
# into the same state directory (see paperless.nix).
#
# ⚠ SECOND LINE, not the first. `paperless-db-dump.service` verifies its own work — it waits
# for the file, runs `PRAGMA integrity_check` on it, and fails the unit otherwise — so a
# broken dump announces itself. What that unit cannot report is its own ABSENCE: a masked or
# disabled timer, a generation that predates it, or a host booted with `dump.enable = false`.
# Nothing on the host would then be failing, which is exactly the state in which a backup
# quietly becomes worthless.
#
# A deliberate duplicate of vaultwarden-dump-freshness.nix and its Immich sibling rather than
# a shared abstraction, for the reason the vault's copy already gives: the shell is
# near-identical and the MESSAGES are the deliverable. Each one tells the reader which data is
# missing from which snapshot and which timer to go and look at; merged, all three would have
# to say "some dump" about "some service" at 03:00. Keep them in step by hand.
#
# Wired as `backupPrepareCommand`, which the NixOS restic module puts in `preStart` — run with
# `set -e`, so a non-zero exit here fails the unit BEFORE restic runs. `ExecStartPost` then
# never fires, so the last-success stamp (modules/nixos/profiles/backup.nix) stays where it
# was and the Backups board shows the job going COLD rather than green.
#
# Parameterised, and kept out of the host file, so `parts/checks/paperless-dump-freshness` can
# exercise THIS script on the build platform instead of a copy-paste of it.
{
  pkgs,
  # Directory the dumps land in. Not a choice: `VACUUM INTO` is pointed at a path beside the
  # database, so this is paperless's data directory — and on an impermanence host the caller
  # passes the BACKING STORE path (`/persistent/...`), because what restic ships is what
  # should be checked.
  dumpDir,
  # How old the newest dump may be before the job refuses. Callers pick this from their own
  # restic schedule against the dump timer's; see the note in hosts/kelpy/configuration.nix.
  maxAgeSeconds,
}:
pkgs.writeShellScript "paperless-dump-freshness" ''
  set -euo pipefail
  dump_dir=${pkgs.lib.escapeShellArg dumpDir}

  if [ ! -d "$dump_dir" ]; then
    echo "paperless-dump-freshness: $dump_dir does not exist — paperless has no data directory here." >&2
    echo "  Either custom.profiles.paperless is not enabled on this host, or its state has" >&2
    echo "  moved and the paperless paths in this job now point at nothing." >&2
    exit 1
  fi

  # Only the epoch is taken, never the path — a filename carries dots, so trimming the
  # fraction off a "<epoch> <path>" line would eat part of the path. Ask find for the mtime
  # alone.
  #
  # ⚠ THE GLOB IS THE WHOLE GUARD. `db_*.sqlite3` matches the dumps and NOT the live
  # `db.sqlite3` sitting in this same directory (no underscore), nor its `-wal`/`-shm`
  # siblings, nor `celerybeat-schedule.db`. Widen it and this gate goes permanently green over
  # a dump that stopped months ago, which is precisely what it exists to catch.
  newest=$(${pkgs.findutils}/bin/find "$dump_dir" -maxdepth 1 -type f \
    -name 'db_*.sqlite3' -printf '%T@\n' \
    | ${pkgs.coreutils}/bin/sort -rn \
    | ${pkgs.coreutils}/bin/head -1 \
    | ${pkgs.coreutils}/bin/cut -d. -f1)

  if [ -z "$newest" ]; then
    echo "paperless-dump-freshness: no db_*.sqlite3 in $dump_dir." >&2
    echo "  The live db.sqlite3 is excluded from this job on purpose, so a snapshot taken now" >&2
    echo "  would carry the scanned originals under media/ and NO RECORD OF WHAT THEY ARE —" >&2
    echo "  no correspondents, tags, dates, OCR content or filename mapping. Check" >&2
    echo "  paperless-db-dump.timer and paperless-db-dump.service. Refusing." >&2
    exit 1
  fi

  age=$(( $(${pkgs.coreutils}/bin/date +%s) - newest ))
  if [ "$age" -gt ${toString maxAgeSeconds} ]; then
    echo "paperless-dump-freshness: newest dump in $dump_dir is $(( age / 3600 ))h old" >&2
    echo "  (limit ${
      toString (maxAgeSeconds / 3600)
    }h). The dump timer has stopped running, and the live" >&2
    echo "  database is excluded from this job — so this snapshot's document index would be" >&2
    echo "  that old, against media/ as it is tonight. Refusing." >&2
    echo "  Start with: systemctl status paperless-db-dump.timer" >&2
    exit 1
  fi

  echo "paperless-dump-freshness: newest dump is $(( age / 3600 ))h old — OK."
''
