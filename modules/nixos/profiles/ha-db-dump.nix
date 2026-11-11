# The nightly backup artifact for Home Assistant's recorder: a consistent `VACUUM INTO` dump of
# its SQLite database, taken beside the live one as `db_<UTC>.sqlite3`.
#
# WHY A DUMP AND NOT THE DATABASE. `home-assistant_v2.db` is open with WAL (verified on rk1a:
# `PRAGMA journal_mode` → wal, with a 4 MB `-wal` beside a 1.6 MB database), so a file-level copy
# is a torn page set plus a `-wal`/`-shm` pair no backup tool can capture atomically beside it.
# The artifact looks like a database and may simply not open. So the host's restic job EXCLUDES
# the live triple and ships these dumps instead, with ha-dump-freshness.nix refusing the job if
# they stop arriving.
#
# WHY BACK UP THE RECORDER AT ALL — this is the part worth arguing, because unlike paperless's
# index the recorder is NOT load-bearing for a working restore. Home Assistant comes up perfectly
# well on an empty one: everything that makes it THIS house's installation (config entries, the
# entity/device/area registries, the auth store, dashboards) lives in `.storage/`, which is inert
# JSON written with atomic replace and travels verbatim. What the recorder holds is HISTORY, and
# one slice of that history is not regenerable from anything: LONG-TERM STATISTICS, the hourly
# means/min/max the energy dashboard and every long-range sensor graph are drawn from. Lose the
# database and the house's past is gone for good, while the present keeps working — a failure
# nobody notices until they look at a year-over-year graph. At single-digit MB it is the cheapest
# irreplaceable thing on this host, so it travels.
#
# ── WHAT THIS IS NOT ─────────────────────────────────────────────────────────────────────────
# NOT Home Assistant's own `backup` integration, and the choice is deliberate — it is the
# analogue of paperless's `document_exporter` next door, with the same answer. That produces an
# encrypted, compressed tar of the whole config directory: the right artifact for a migration or
# a pre-upgrade safety net, and the wrong one for a nightly. It re-copies everything this
# snapshot already carries verbatim, and being compressed and encrypted per run it is opaque to
# restic's deduplication — so each night would cost a fresh full copy instead of the handful of
# changed chunks. It also needs an authenticated API call, which turns a backup into something
# that can only happen while Home Assistant is healthy.
#
# The reasoning the vault's header gives applies unchanged: a full export insures against FORMAT
# and SOFTWARE risk, it can be taken at any time while the system still works, and so it belongs
# at a NAMED TRIGGER — before a major Home Assistant upgrade — not on a cadence.
#
# ── WHY IT NEEDS NOTHING FROM THE RUNNING SERVICE ────────────────────────────────────────────
# `VACUUM INTO` opens its own connection, is read-only with respect to the source, and in WAL
# mode snapshots the committed state — the WAL included — while Home Assistant keeps writing.
# Verified against the live database on rk1a while HA was up: `integrity_check` → ok, 3318
# states, 5 long-term statistics rows. Three things fall out:
#   * no signal and no API call, so no asynchronous artifact to wait for;
#   * no dependency on Home Assistant being up, so a dump still happens on a host where the
#     service is stopped or crash-looping — which is exactly when one is most wanted;
#   * one connection's worth of consistency, with no coordination to get wrong.
#
# ── HOW TO RESTORE (NOT DRILLED — see the warning at the end) ────────────────────────────────
#   1. Take from the snapshot: the whole of `/persistent/var/lib/hass`, and note that it contains
#      NO `home-assistant_v2.db` by design — the newest `db_<UTC>.sqlite3` in it is that database.
#      `configuration.yaml` in there is a SYMLINK into /etc/home-assistant: nix writes it, so a
#      dangling link in the restore is expected and is repaired by the first deploy.
#   2. Restore `/var/lib/nixos` from the same snapshot BEFORE first activation, or the `hass`
#      uid/gid is re-allocated and every restored file belongs to the wrong user — see
#      [[kelpy-uid-map-drift]] for how that looks in practice. The alternative is a
#      `chown -R hass:hass` of the state directory afterwards.
#   3. `cp db_<newest>.sqlite3 <configDir>/home-assistant_v2.db` — a `VACUUM INTO` output is a
#      complete standalone database, not a delta — then `chown hass:hass` it. The dump is 0600
#      and owned by whoever ran the unit; Home Assistant cannot open what it does not own.
#   4. Start Home Assistant on it. Ideally the same version: the recorder migrates the schema
#      forward on first start (this dump's schema version is logged every night, below), and that
#      migration is the one step here that is not reversible — keep a copy of the dump first.
#   5. Verify from both sides. Server: `sqlite3 -readonly home-assistant_v2.db 'PRAGMA
#      integrity_check;'` and the row counts against the ones this unit logged the night the dump
#      was taken. Client: open Settings → Devices, confirm the bulbs are present and controllable
#      (that is `.storage`), then open a sensor's history and the energy dashboard (that is this
#      database) — a count cannot show that the statistics actually resolve.
#
# ⚠ UNDRILLED. The dump itself is proven — `VACUUM INTO` was run against the live database on
# rk1a and read back as a standalone one, and parts/checks/ha-db-dump exercises this script —
# but no restore has been performed. Drill it the day the history is worth more than the house.
#
# ⚠ IT RUNS AS THE `hass` USER, not root, which follows paperless's choice next door for the same
# reason: root opening a WAL database read-WRITE can create or replace the `-shm`/`-wal` files
# beside it, leaving them ROOT-OWNED — and Home Assistant, which is not root, then cannot write
# its own database on next start. Running as the owner makes every file this touches correctly
# owned by construction. Nothing here opens the source for writing.
{
  pkgs,
  lib,
  # Home Assistant's config directory, as the UNIT sees it (the bind-mounted view, not
  # /persistent/…). The live database is `home-assistant_v2.db` inside it and the dumps land
  # beside it — which is why no new path or persistence entry is needed: the host already backs
  # this directory up.
  configDir,
  # How many dumps to keep. Retention is ours; nothing prunes these but this script.
  keep,
  # This host's name, baked into the alert text rather than read with `hostname` at runtime —
  # the same spelling (`[<host>] <service> — …`) every other alerter on the fleet uses.
  hostName,
  # Shell defining `post <text>` for operator alerts. The profile passes the #infra-alerts
  # webhook poster; the check passes a stub, which is the point of taking it as a parameter.
  post,
}:
let
  dir = lib.escapeShellArg configDir;
  db = lib.escapeShellArg "${configDir}/home-assistant_v2.db";
in
pkgs.writeShellScript "ha-db-dump" ''
  set -euo pipefail
  ${post}

  # The dump's name. `db_<UTC %Y%m%d_%H%M%S>.sqlite3` is the fleet's dump convention (the vault
  # inherits it from upstream's own `backup_sqlite`, paperless followed it) and is what
  # ha-dump-freshness.nix globs for. Here the prefix also keeps the dumps clear of the live
  # `home-assistant_v2.db*` triple, which is what the host EXCLUDES — two disjoint patterns, so
  # neither can ever match the other's files.
  #
  # HA_DUMP_STAMP is a TEST SEAM and nothing else: it lets parts/checks/ha-db-dump drive
  # filenames deterministically instead of racing the clock. No unit sets it.
  stamp="''${HA_DUMP_STAMP:-$(date -u +%Y%m%d_%H%M%S)}"
  target=${dir}/db_"$stamp".sqlite3

  # No database is NOT an error here, which INVERTS paperless's choice next door and is the one
  # place these two scripts deliberately differ. Paperless always has a database; Home
  # Assistant's recorder creates one on first start, so on a host that has just been deployed —
  # or one where recorder is off, or has just recreated a database it found corrupt — its absence
  # is an ordinary state rather than a fault. Failing here would also be pointless: the thing a
  # failure protects is the backup, and ha-dump-freshness.nix already handles the absent-database
  # case directly, by PASSING (nothing is being excluded from the snapshot, so nothing is
  # missing from it). Exiting 0 with a loud line is the honest answer.
  if [ ! -f ${db} ]; then
    echo "ha-db-dump: ${configDir}/home-assistant_v2.db does not exist, so there is no recorder"
    echo "  history to dump. Expected on a freshly deployed host (Home Assistant creates it on"
    echo "  first start) and with recorder disabled. The backup is NOT blocked by this: the live"
    echo "  database is the only thing excluded from the snapshot, and there isn't one."
    exit 0
  fi

  # `VACUUM INTO` refuses to overwrite, so a second invocation inside the same UTC second would
  # fail the unit. Only a human double-start can produce that, and a failed unit plus an alert is
  # the wrong answer to "you already have tonight's dump" — so say so and stop. Not exit 1:
  # there is nothing wrong with this host.
  if [ -e "$target" ]; then
    echo "ha-db-dump: $target already exists — a dump was taken this same UTC second. Nothing to do."
    exit 0
  fi

  # The dump itself. Quoted into the SQL rather than passed as a parameter because VACUUM INTO
  # takes a literal; the path is built from a baked directory and a timestamp, so it carries
  # nothing that needs escaping.
  if ! err=$(sqlite3 ${db} "VACUUM INTO '$target';" 2>&1); then
    post "🚨 [${hostName}] home-assistant — the recorder database dump FAILED: $err. The live home-assistant_v2.db is excluded from the backup, so restic will fall back to the previous dump until it ages past the freshness limit, then refuse the whole job — which would also stop .storage (config entries, registries, dashboards) from travelling."
    echo "ha-db-dump: VACUUM INTO failed: $err" >&2
    exit 1
  fi

  # Mode first, before anything else reads it: restic preserves modes, and while this directory
  # is 0700 today the file's own mode is what keeps a complete copy of the house's history from
  # being readable after a restore into somewhere laxer. UMask on the unit should already do it;
  # this does not depend on that.
  chmod 0600 "$target"

  # The one check that distinguishes a dump from a file: a truncated or torn VACUUM output is
  # still a plausible-looking sqlite3 file, and the time to find out is not during a restore.
  if ! check=$(sqlite3 -readonly "$target" 'PRAGMA integrity_check;' 2>&1) \
    || [ "$check" != "ok" ]; then
    # DELETE the bad dump, deliberately — the same reasoning the vault's and paperless's units
    # record. Leaving it would make it the NEWEST file in the directory, so the freshness gate
    # would pass and restic would ship an unopenable history; removing it lets the gate fall back
    # to last night's good dump and start refusing on its own once that ages out. A stale history
    # beats an unopenable one, and this unit has already failed either way.
    rm -f "$target"
    post "🚨 [${hostName}] home-assistant — the recorder database dump FAILED ITS INTEGRITY CHECK and has been deleted: $check. The backup will fall back to the previous dump until it ages past the freshness limit, then refuse."
    echo "ha-db-dump: integrity_check on $target said: $check" >&2
    exit 1
  fi

  # Logged every night on purpose. The counts are what a restore is verified against, and the
  # SCHEMA VERSION is what decides whether a given Home Assistant will open this file at all:
  # the recorder migrates forward on first start and never back, so restoring into a newer
  # version is a one-way door. Knowing the dump's schema before taking that step is the
  # difference between a restore and an experiment.
  #
  # ⚠ NON-FATAL, which is the lesson the vault's unit learned the hard way: a reporting query
  # took down the artifact it was reporting on, after a perfectly good dump had been taken and
  # integrity-checked, and before retention ran. `statistics` is the long-term table — the one
  # irreplaceable thing in here — and `schema_changes` is where the recorder records its version
  # (53 on 2026-11-11). An upstream rename of either should degrade this line, not lose a good dump.
  # ⚠ NO STRING LITERALS IN THIS SQL, on purpose. The query lives inside a single-quoted shell
  # string, so a SQL string literal would have to be double-quoted — and modern SQLite reads a
  # DOUBLE-quoted literal as an IDENTIFIER, which turns the whole line into "no such column" and
  # loses the counts. Selecting bare columns and letting sqlite3's default `|` separator do the
  # joining keeps the SQL literal-free. (Found by parts/checks/ha-db-dump, which is the point of
  # having it.)
  counts="counts unavailable (recorder schema changed?)"
  if row=$(sqlite3 -readonly "$target" \
      'select (select count(*) from states),
              (select count(*) from events),
              (select count(*) from statistics),
              (select count(*) from statistics_meta),
              (select schema_version from schema_changes order by change_id desc limit 1);' \
      2>/dev/null); then
    IFS='|' read -r n_states n_events n_stats n_series schema <<<"$row"
    counts="$n_states states, $n_events events, $n_stats long-term statistics rows"
    counts="$counts ($n_series series), schema $schema"
  fi
  echo "ha-db-dump: $target — integrity ok, $counts, $(stat -c %s "$target") bytes."

  # Retention. Nothing else prunes these, so without this the config directory grows one full
  # copy of the recorder per night, forever — on a host whose only real storage is a 29 GB eMMC
  # already at 79%.
  find ${dir} -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%T@ %p\n' \
    | sort -rn \
    | tail -n +${toString (keep + 1)} \
    | cut -d' ' -f2- \
    | while read -r old; do
        echo "ha-db-dump: pruning $old (keeping ${toString keep})"
        rm -f "$old"
      done
''
