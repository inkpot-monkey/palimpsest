# A restic `backupPrepareCommand` that refuses to ship an Immich snapshot whose database
# half is stale.
#
# WHY THIS EXISTS. Immich's media directory holds only pixels. Albums, people, faces, share
# links and every asset's EXIF live in its postgres database, and the backup of that database
# is Immich's OWN nightly logical dump, written into `<mediaLocation>/backups`. That dump is
# configured in Immich's admin settings — which live inside the database itself, not in this
# repo and not declaratively. So it can be switched off in the UI, or start failing, with
# nothing here changing. restic would go on backing up the same stale `.sql.gz` every night
# and reporting success: a job that is green on the Backups board and cannot restore an album.
#
# Hence a guard rather than a comment. Wired as `backupPrepareCommand`, which the NixOS restic
# module puts in `preStart` — run with `set -e`, so a non-zero exit here fails the unit BEFORE
# restic runs. That also means `ExecStartPost` never fires, so the last-success stamp
# (modules/nixos/profiles/backup.nix) stays stale and the board shows the job going COLD rather
# than green. Failing loudly and visibly is the entire point; a warning would be worthless.
#
# Parameterised, and kept out of the host file, so `parts/checks/immich-db-dump-freshness`
# can exercise THIS script on the build platform instead of a copy-paste of it. A test over a
# duplicate of the logic would pass while the real one rotted.
{
  pkgs,
  # Directory Immich writes its dumps into — `<mediaLocation>/backups`.
  dumpDir,
  # How old the newest dump may be before the job refuses. Callers pick this from their own
  # restic schedule against Immich's dump schedule; see the note in hosts/rk1/backup.nix.
  maxAgeSeconds,
}:
pkgs.writeShellScript "immich-db-dump-freshness" ''
  set -euo pipefail
  dump_dir=${pkgs.lib.escapeShellArg dumpDir}

  if [ ! -d "$dump_dir" ]; then
    echo "immich-db-dump-freshness: $dump_dir does not exist — Immich's database backup has never run." >&2
    echo "  Enable it in Immich: Administration → Settings → Backup Settings → Database Dump." >&2
    exit 1
  fi

  # Only the epoch is taken, never the path: a dump FILENAME contains dots (the version stamp
  # and the .sql.gz suffix), so trimming the fraction off a "<epoch> <path>" line would eat
  # part of the path instead. Ask find for the mtime alone.
  newest=$(${pkgs.findutils}/bin/find "$dump_dir" -maxdepth 1 -type f \
    -name 'immich-db-backup-*.sql.gz' -printf '%T@\n' \
    | ${pkgs.coreutils}/bin/sort -rn \
    | ${pkgs.coreutils}/bin/head -1 \
    | ${pkgs.coreutils}/bin/cut -d. -f1)

  if [ -z "$newest" ]; then
    echo "immich-db-dump-freshness: no immich-db-backup-*.sql.gz in $dump_dir." >&2
    echo "  The photo FILES would still back up, but albums, people and faces live only in" >&2
    echo "  the database — a restore from this snapshot would lose all of them. Refusing." >&2
    exit 1
  fi

  age=$(( $(${pkgs.coreutils}/bin/date +%s) - newest ))
  if [ "$age" -gt ${toString maxAgeSeconds} ]; then
    echo "immich-db-dump-freshness: newest dump in $dump_dir is $(( age / 3600 ))h old" >&2
    echo "  (limit ${
      toString (maxAgeSeconds / 3600)
    }h). Immich's database backup has stopped running." >&2
    echo "  Refusing to ship a snapshot whose database half is stale." >&2
    exit 1
  fi

  echo "immich-db-dump-freshness: newest dump is $(( age / 3600 ))h old — OK."
''
