# The nightly backup artifact for paperless: a consistent `VACUUM INTO` dump of its SQLite
# database, taken beside the live one as `db_<UTC>.sqlite3`.
#
# WHY A DUMP AND NOT THE DATABASE. Paperless keeps the scanned originals under `media/` as
# ordinary inert files, and everything that makes them an ARCHIVE — correspondent, document
# type, tags, dates, the OCR'd content search runs against, and the filename mapping from a row
# to a file on disk — in `db.sqlite3`. That database is open with WAL, so a file-level copy is a
# torn page set plus a `-wal`/`-shm` pair no backup tool can capture atomically beside it: the
# artifact looks like a database and may simply not open. Worse, and measured on the vault next
# door (users#57), SQLite may not have checkpointed for days — so copying `db.sqlite3` alone can
# silently restore an index that is a week stale against media that is current.
#
# So the host's restic job EXCLUDES the live triple and ships these dumps instead, with
# paperless-dump-freshness.nix refusing the whole job if they stop arriving.
#
# ── WHAT THIS IS NOT ─────────────────────────────────────────────────────────────────────────
# NOT `document_exporter`, paperless's own export command, and the choice is deliberate. That
# produces a version-portable tree of documents PLUS a metadata manifest — the right artifact
# for a migration, and the wrong one for a nightly: it re-copies every original, doubling the
# library on a 90G host, to protect files the backup already carries verbatim. What is at risk
# here is only the index, which is what this takes.
#
# The same reasoning the vault's header gives for holding no standing export applies: an export
# insures against FORMAT and SOFTWARE risk, it can be taken at any time while the system still
# works, and so it belongs at a NAMED TRIGGER — before a major paperless upgrade, or a migration
# off it — not on a cadence.
#
# ── WHY IT NEEDS NOTHING FROM THE RUNNING SERVICE ────────────────────────────────────────────
# Unlike its vault sibling, which has to SIGUSR1 Vaultwarden because only that process holds the
# database, this talks to SQLite directly: `VACUUM INTO` opens its own connection, is read-only
# with respect to the source, and in WAL mode takes a snapshot of the committed state — the WAL
# included — while paperless keeps writing. Three things fall out, and they are the reason this
# unit is half the length of the vault's:
#   * no signal, so no asynchronous artifact to wait for and poll;
#   * no dependency on paperless being up, so a dump still happens on a host where the service
#     is stopped or crash-looping — which is exactly when one is most wanted;
#   * one connection's worth of consistency, with no coordination to get wrong.
#
# ── HOW TO RESTORE (NOT DRILLED — see the warning at the end) ────────────────────────────────
#   1. Take from the snapshot: the newest `db_<UTC>.sqlite3`, and `media/` entire. There is NO
#      `db.sqlite3` in it by design, and no `index/` or `log/` either — both are excluded as
#      derived (hosts/kelpy/configuration.nix says why).
#   2. `cp db_<newest>.sqlite3 <dataDir>/db.sqlite3` — a `VACUUM INTO` output is a complete
#      standalone database, not a delta — then `chown paperless:paperless` it. The dump is
#      root-free but it is 0600 and owned by whoever ran the unit; paperless cannot open what it
#      does not own.
#   3. Start paperless on it. The same version ideally; a newer one runs its Django migrations
#      on first start, which is the one step that is not reversible — take a copy of the dump
#      first.
#   4. Rebuild the search index, which was deliberately not backed up:
#      `paperless-manage document_index reindex`.
#   5. Verify from both sides. Server: `sqlite3 -readonly db.sqlite3 'PRAGMA integrity_check;'`
#      and `select count(*) from documents_document where deleted_at is null;` against the count
#      this unit logged on the night the dump was taken. Client: open a document in the web UI
#      and confirm its file actually resolves — that is the half that proves the row-to-file
#      mapping survived, and the half a count cannot show.
#
# ⚠ UNDRILLED, and the distinction matters: the vault's restore above it in this directory was
# performed end to end against real data, and these steps have not been. The dump itself is
# proven — parts/checks/paperless-db-dump reads one back as a standalone database — but the
# library on this fleet is EMPTY (zero documents as of 2026-11-08), so there has never been
# anything to restore. Drill this the day it holds paper worth restoring.
#
# ⚠ IT RUNS AS THE PAPERLESS USER, which INVERTS the vault's choice (root, because its state dir
# is 0700 and taking the vault's identity would let the dump unit write the database it copies).
# The hazard here is the other way round: root opening a WAL database read-WRITE can create or
# replace the `-shm`/`-wal` files beside it, leaving them ROOT-OWNED — and paperless, which is
# not root, then cannot write its own database on next start. Running as the owner makes every
# file this touches correctly owned by construction. Being able to write the source is the
# lesser risk, and nothing here opens it for writing.
{
  pkgs,
  lib,
  # Paperless's data directory, as the UNIT sees it (the bind-mounted view, not /persistent/…).
  # The live database is `db.sqlite3` inside it, and the dumps land beside it — which is why no
  # new path or persistence entry is needed: the host already backs this directory up.
  dataDir,
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
  dir = lib.escapeShellArg dataDir;
  db = lib.escapeShellArg "${dataDir}/db.sqlite3";
in
pkgs.writeShellScript "paperless-db-dump" ''
  set -euo pipefail
  ${post}

  # The dump's name. `db_<UTC %Y%m%d_%H%M%S>.sqlite3` is the fleet's dump convention (the vault
  # inherits it from upstream's own `backup_sqlite`) and is what paperless-dump-freshness.nix
  # globs for — the `db_` prefix is the whole reason that guard cannot mistake the live
  # `db.sqlite3` for a backup.
  #
  # PAPERLESS_DUMP_STAMP is a TEST SEAM and nothing else: it lets
  # parts/checks/paperless-db-dump drive filenames deterministically instead of racing the
  # clock. No unit sets it.
  stamp="''${PAPERLESS_DUMP_STAMP:-$(date -u +%Y%m%d_%H%M%S)}"
  target=${dir}/db_"$stamp".sqlite3

  if [ ! -f ${db} ]; then
    post "🚨 [${hostName}] paperless — no database dump taken: ${dataDir}/db.sqlite3 does not exist. Either paperless has never started here, or its data directory moved and the backup's paperless paths now point at nothing. The live database is excluded from the backup, so the next restic run will refuse rather than ship an index-less snapshot."
    echo "paperless-db-dump: ${dataDir}/db.sqlite3 does not exist." >&2
    exit 1
  fi

  # `VACUUM INTO` refuses to overwrite, so a second invocation inside the same UTC second would
  # fail the unit. Only a human double-start can produce that, and a failed unit plus an alert
  # is the wrong answer to "you already have tonight's dump" — so say so and stop. Not exit 1:
  # there is nothing wrong with this host.
  if [ -e "$target" ]; then
    echo "paperless-db-dump: $target already exists — a dump was taken this same UTC second. Nothing to do."
    exit 0
  fi

  # The dump itself. Quoted into the SQL rather than passed as a parameter because VACUUM INTO
  # takes a literal; the path is built from a baked directory and a timestamp, so it carries
  # nothing that needs escaping.
  if ! err=$(sqlite3 ${db} "VACUUM INTO '$target';" 2>&1); then
    post "🚨 [${hostName}] paperless — the database dump FAILED: $err. The live db.sqlite3 is excluded from the backup, so restic will fall back to the previous dump until it ages past the freshness limit, then refuse the whole job."
    echo "paperless-db-dump: VACUUM INTO failed: $err" >&2
    exit 1
  fi

  # Mode first, before anything else reads it: restic preserves modes, and this directory is
  # 0755 (paperless serves `consume` to other writers), so the file's own mode is the only thing
  # keeping a complete copy of the document index from being world-readable here and after a
  # restore. UMask on the unit should already do it; this does not depend on that.
  chmod 0600 "$target"

  # The one check that distinguishes a dump from a file: a truncated or torn VACUUM output is
  # still a plausible-looking sqlite3 file, and the time to find out is not during a restore.
  if ! check=$(sqlite3 -readonly "$target" 'PRAGMA integrity_check;' 2>&1) \
    || [ "$check" != "ok" ]; then
    # DELETE the bad dump, deliberately — the same reasoning the vault's unit records. Leaving
    # it would make it the NEWEST file in the directory, so the freshness gate would pass and
    # restic would ship a corrupt index; removing it lets the gate fall back to last night's
    # good dump and start refusing on its own once that ages out. A stale index beats an
    # unopenable one, and this unit has already failed either way.
    rm -f "$target"
    post "🚨 [${hostName}] paperless — the database dump FAILED ITS INTEGRITY CHECK and has been deleted: $check. The backup will fall back to the previous dump until it ages past the freshness limit, then refuse."
    echo "paperless-db-dump: integrity_check on $target said: $check" >&2
    exit 1
  fi

  # Logged every night on purpose: this is the number a restore is verified against, and an
  # archive that silently loses rows is otherwise invisible until someone goes looking for a
  # document.
  #
  # ⚠ NON-FATAL, which is the lesson the vault's unit learned the hard way: a reporting query
  # took down the artifact it was reporting on, after a perfectly good dump had been taken and
  # integrity-checked, and before retention ran. The table is `documents_document` and the
  # soft-delete column `deleted_at` (documents/models.py — `Document(SoftDeleteModel, …)`, no
  # `db_table` override, so Django's default name); upstream renaming either should degrade
  # this line, not lose a good dump.
  counts="counts unavailable (schema changed? see documents/models.py)"
  if total=$(sqlite3 -readonly "$target" 'select count(*) from documents_document;' 2>/dev/null) \
    && live=$(sqlite3 -readonly "$target" \
        'select count(*) from documents_document where deleted_at is null;' 2>/dev/null); then
    counts="$total documents ($live live, $(( total - live )) in trash)"
  fi
  echo "paperless-db-dump: $target — integrity ok, $counts, $(stat -c %s "$target") bytes."

  # Retention. Nothing else prunes these, so without this the data directory grows one full copy
  # of the index per night, forever — on a host whose only real storage is 90G.
  find ${dir} -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%T@ %p\n' \
    | sort -rn \
    | tail -n +${toString (keep + 1)} \
    | cut -d' ' -f2- \
    | while read -r old; do
        echo "paperless-db-dump: pruning $old (keeping ${toString keep})"
        rm -f "$old"
      done
''
