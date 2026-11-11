# A restic `backupPrepareCommand` that refuses to ship an rk1a snapshot with Home Assistant's
# recorder history missing from it.
#
# WHY THIS EXISTS. Home Assistant keeps two halves of one installation: `.storage/` — inert JSON
# holding the config entries, the entity/device/area registries, the auth store and the
# dashboards, which is what makes this THIS house's installation — and `home-assistant_v2.db`,
# which holds its past: state history, and the long-term statistics the energy dashboard and
# every long-range graph are drawn from. The first half travels verbatim. The second cannot: it
# is open with WAL, so a file-level copy is a torn page set and the `-wal`/`-shm` pair cannot be
# captured atomically beside it. What travels instead is the `VACUUM INTO` dump that
# `ha-db-dump.service` writes as `db_<UTC>.sqlite3` into the same directory (see
# homeassistant.nix).
#
# ⚠ SECOND LINE, not the first. `ha-db-dump.service` verifies its own work — it runs
# `PRAGMA integrity_check` on the dump and deletes it rather than leave an unopenable file as the
# newest one — so a broken dump announces itself. What that unit cannot report is its own
# ABSENCE: a masked or disabled timer, a generation that predates it, or a host booted with
# `backup.dump.enable = false`. Nothing on the host would then be failing, which is exactly the
# state in which a backup quietly becomes worthless.
#
# ── WHERE THIS DIVERGES FROM ITS PAPERLESS AND VAULT SIBLINGS, AND WHY ───────────────────────
# Those two refuse when there is no dump, full stop. This one refuses only when there is a LIVE
# DATABASE and no fresh dump — an absent database PASSES, loudly.
#
# That is not laxness, it is the fix for an outage. kelpy's paperless gate took the whole host's
# backup down on 2026-11-10, the first deploy that carried it: on a fresh deploy the dump timer
# had not fired, so there was no dump, so the gate refused, so NOTHING was backed up — not just
# paperless, but the mail store and the vault too. A guard meant to protect one service had
# switched off the backup for everything else on the host. The dump unit now also runs at
# activation, which closes it from the other end, but the SHAPE of the bug is still there in any
# gate whose refusal is unconditional.
#
# Reasoning it through from what the gate is actually FOR: it exists because the live database is
# excluded. If there is no live database, the exclusion is hiding nothing, the snapshot is
# complete, and refusing it would discard `.storage` — the half that matters most — to protect a
# history that does not exist. Home Assistant creates the database on first start, and recreates
# it if it finds it corrupt, so "absent" is an ordinary state here rather than a fault.
#
# What this gate therefore insists on, and the paperless one does not check at all, is that the
# PAYLOAD is really there: a state directory with a non-empty `.storage` in it. That is the
# failure mode a targeted job has instead — paths pointing at a tree that moved — and against it
# "a dump exists" is no evidence whatsoever.
#
# A deliberate relative of vaultwarden-dump-freshness.nix and its paperless and Immich siblings
# rather than a shared abstraction, for the reason the vault's copy already gives: the shell is
# near-identical and the MESSAGES are the deliverable. Each one tells the reader which data is
# missing from which snapshot and which timer to go and look at; merged, all four would have to
# say "some dump" about "some service" at 03:00. Keep them in step by hand.
#
# Wired as `backupPrepareCommand`, which the NixOS restic module puts in `preStart` — run with
# `set -e`, so a non-zero exit here fails the unit BEFORE restic runs. `ExecStartPost` then never
# fires, so the last-success stamp (modules/nixos/profiles/backup.nix) stays where it was and the
# Backups board shows the job going COLD rather than green.
#
# Parameterised, and kept out of the host file, so `parts/checks/ha-dump-freshness` can exercise
# THIS script on the build platform instead of a copy-paste of it.
{
  pkgs,
  # Home Assistant's config directory: where the dumps land, beside the database. On an
  # impermanence host the caller passes the BACKING STORE path (`/persistent/...`), because what
  # restic ships is what should be checked.
  stateDir,
  # How old the newest dump may be before the job refuses. Callers pick this from their own
  # restic schedule against the dump timer's; see the note in hosts/rk1/ha-backup.nix.
  maxAgeSeconds,
}:
pkgs.writeShellScript "ha-dump-freshness" ''
  set -euo pipefail
  state_dir=${pkgs.lib.escapeShellArg stateDir}

  if [ ! -d "$state_dir" ]; then
    echo "ha-dump-freshness: $state_dir does not exist — Home Assistant has no state directory here." >&2
    echo "  Either custom.profiles.homeassistant is not enabled on this host, or its state has" >&2
    echo "  moved and the paths in this job now point at nothing. Refusing." >&2
    exit 1
  fi

  # ⚠ THE PAYLOAD CHECK, which this gate's siblings have no equivalent of. `.storage` is the
  # whole of Home Assistant's own configuration — config entries (every bulb, the voice
  # pipeline), the entity/device/area registries, the auth store, the dashboards. A job whose
  # paths have drifted off the real state directory would otherwise back up an empty tree and
  # report success, and no amount of dump-freshness checking would notice.
  if [ -z "$(${pkgs.findutils}/bin/find "$state_dir/.storage" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
    echo "ha-dump-freshness: $state_dir/.storage holds no files." >&2
    echo "  That directory IS Home Assistant's configuration — config entries for every device," >&2
    echo "  the entity/device/area registries, the auth store, the dashboards. A snapshot taken" >&2
    echo "  now would carry none of it, so a restore would come up as a blank install that" >&2
    echo "  happens to have this house's history. Either Home Assistant has never started here" >&2
    echo "  or this job's paths no longer point at its state. Refusing." >&2
    exit 1
  fi

  # The absent-database case: PASS. See the long note in this file's header — the exclusion is
  # hiding nothing, so the snapshot is complete, and refusing it would throw away `.storage` to
  # protect a history that does not exist.
  if [ ! -f "$state_dir/home-assistant_v2.db" ]; then
    echo "ha-dump-freshness: no home-assistant_v2.db in $state_dir, so the recorder has no"
    echo "  history here yet (fresh deploy, or recorder disabled) and nothing is being excluded"
    echo "  from this snapshot. .storage is present and travels. OK."
    exit 0
  fi

  # Only the epoch is taken, never the path — a filename carries dots, so trimming the fraction
  # off a "<epoch> <path>" line would eat part of the path. Ask find for the mtime alone.
  #
  # ⚠ THE GLOB IS THE WHOLE GUARD. `db_*.sqlite3` matches the dumps and NOT the live
  # `home-assistant_v2.db` sitting in this same directory, nor its `-wal`/`-shm` siblings. Widen
  # it and this gate goes permanently green over a dump that stopped months ago, which is
  # precisely what it exists to catch.
  newest=$(${pkgs.findutils}/bin/find "$state_dir" -maxdepth 1 -type f \
    -name 'db_*.sqlite3' -printf '%T@\n' \
    | ${pkgs.coreutils}/bin/sort -rn \
    | ${pkgs.coreutils}/bin/head -1 \
    | ${pkgs.coreutils}/bin/cut -d. -f1)

  if [ -z "$newest" ]; then
    echo "ha-dump-freshness: no db_*.sqlite3 in $state_dir, but home-assistant_v2.db is there." >&2
    echo "  That live database is excluded from this job on purpose — copying an open WAL" >&2
    echo "  database is not a restorable artifact — so a snapshot taken now would carry this" >&2
    echo "  house's configuration with NO HISTORY AT ALL: no state history, and none of the" >&2
    echo "  long-term statistics the energy dashboard and every long-range graph are drawn from," >&2
    echo "  which nothing can regenerate. Check ha-db-dump.timer and ha-db-dump.service." >&2
    echo "  Refusing." >&2
    exit 1
  fi

  age=$(( $(${pkgs.coreutils}/bin/date +%s) - newest ))
  if [ "$age" -gt ${toString maxAgeSeconds} ]; then
    echo "ha-dump-freshness: newest dump in $state_dir is $(( age / 3600 ))h old" >&2
    echo "  (limit ${
      toString (maxAgeSeconds / 3600)
    }h). The dump timer has stopped running, and the live" >&2
    echo "  database is excluded from this job — so this snapshot's history would be that old," >&2
    echo "  against a configuration that is current. Refusing." >&2
    echo "  Start with: systemctl status ha-db-dump.timer" >&2
    exit 1
  fi

  echo "ha-dump-freshness: newest dump is $(( age / 3600 ))h old — OK."
''
