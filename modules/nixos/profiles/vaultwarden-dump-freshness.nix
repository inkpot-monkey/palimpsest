# A restic `backupPrepareCommand` that refuses to ship a kelpy snapshot with no vault database
# in it (users#57).
#
# WHY THIS EXISTS, and why it is NOT the same guard as its Immich sibling. The vault's live
# `db.sqlite3` is deliberately EXCLUDED from the backup: a file-level copy of an open SQLite
# database is not a consistent artifact, and the `-wal`/`-shm` pair cannot be copied atomically
# beside it. What travels instead is Vaultwarden's own `VACUUM INTO` dump, taken by
# `vaultwarden-db-dump.service` (see vaultwarden.nix) and written as `db_<UTC>.sqlite3` into the
# same state directory.
#
# So the failure this guards is harsher than Immich's. There, a stopped dump leaves a snapshot
# whose pixels are current and whose albums are stale. Here, a stopped dump leaves a snapshot
# with the attachments, the sends and the RSA keypair — and NO VAULT. Every password in it, the
# TOTP seeds, the whole reason the host is backed up at all: absent, while restic reports
# success and stamps the Backups board green.
#
# ⚠ This is the SECOND line, not the first. `vaultwarden-db-dump.service` verifies its own work
# (it waits for the file, runs `PRAGMA integrity_check` on it and fails the unit otherwise), so
# a broken dump already announces itself. What that unit cannot report is its own absence: a
# masked or disabled timer, a generation that predates it, or a host booted with the profile
# off. Nothing on the host would then be failing — which is exactly the state in which a backup
# quietly becomes worthless.
#
# A deliberate duplicate of immich-db-dump-freshness.nix rather than a shared abstraction. The
# two scripts' SHELL is near-identical and their MESSAGES are the deliverable: each one tells
# the reader which data is missing from which snapshot and what to go and look at. Merged, both
# would have to say "some dump" about "some service", which is the half of a 03:00 failure that
# is worth having. Keep them in step by hand; they are 40 lines each.
#
# Wired as `backupPrepareCommand`, which the NixOS restic module puts in `preStart` — run with
# `set -e`, so a non-zero exit here fails the unit BEFORE restic runs. `ExecStartPost` then
# never fires, so the last-success stamp (modules/nixos/profiles/backup.nix) stays where it was
# and the board shows the job going COLD rather than green. Failing loudly and visibly is the
# entire point; a warning would be worthless.
#
# Parameterised, and kept out of the host file, so `parts/checks/vaultwarden-dump-freshness`
# can exercise THIS script on the build platform instead of a copy-paste of it. A test over a
# duplicate of the logic would pass while the real one rotted.
{
  pkgs,
  # Directory the dumps land in. Not a choice: `VACUUM INTO` writes beside `db.sqlite3`, so
  # this is Vaultwarden's state directory — and on an impermanence host the caller passes the
  # BACKING STORE path (`/persistent/...`), because what restic ships is what should be checked.
  dumpDir,
  # How old the newest dump may be before the job refuses. Callers pick this from their own
  # restic schedule against the dump timer's; see the note in hosts/kelpy/configuration.nix.
  maxAgeSeconds,
}:
pkgs.writeShellScript "vaultwarden-dump-freshness" ''
  set -euo pipefail
  dump_dir=${pkgs.lib.escapeShellArg dumpDir}

  if [ ! -d "$dump_dir" ]; then
    echo "vaultwarden-dump-freshness: $dump_dir does not exist — the vault has no state directory here." >&2
    echo "  Either custom.profiles.vaultwarden is not enabled on this host, or its state has" >&2
    echo "  moved and every path in hosts/kelpy's backup job now points at nothing." >&2
    exit 1
  fi

  # Only the epoch is taken, never the path — the same reason the Immich sibling gives: a
  # filename carries dots, so trimming the fraction off a "<epoch> <path>" line would eat part
  # of the path. Ask find for the mtime alone.
  newest=$(${pkgs.findutils}/bin/find "$dump_dir" -maxdepth 1 -type f \
    -name 'db_*.sqlite3' -printf '%T@\n' \
    | ${pkgs.coreutils}/bin/sort -rn \
    | ${pkgs.coreutils}/bin/head -1 \
    | ${pkgs.coreutils}/bin/cut -d. -f1)

  if [ -z "$newest" ]; then
    echo "vaultwarden-dump-freshness: no db_*.sqlite3 in $dump_dir." >&2
    echo "  The live db.sqlite3 is excluded from this job on purpose, so a snapshot taken now" >&2
    echo "  would carry the attachments and the RSA keypair and NO VAULT AT ALL. Check" >&2
    echo "  vaultwarden-db-dump.timer and vaultwarden-db-dump.service. Refusing." >&2
    exit 1
  fi

  age=$(( $(${pkgs.coreutils}/bin/date +%s) - newest ))
  if [ "$age" -gt ${toString maxAgeSeconds} ]; then
    echo "vaultwarden-dump-freshness: newest dump in $dump_dir is $(( age / 3600 ))h old" >&2
    echo "  (limit ${
      toString (maxAgeSeconds / 3600)
    }h). The vault's dump timer has stopped running, and the live" >&2
    echo "  database is excluded from this job — so this snapshot's vault would be that old." >&2
    echo "  Refusing. Start with: systemctl status vaultwarden-db-dump.timer" >&2
    exit 1
  fi

  echo "vaultwarden-dump-freshness: newest dump is $(( age / 3600 ))h old — OK."
''
