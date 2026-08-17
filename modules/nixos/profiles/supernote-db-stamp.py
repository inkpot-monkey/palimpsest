#!/usr/bin/env python3
"""Re-stamp a fork-migrated Supernote database onto upstream's alembic history.

WHY THIS EXISTS. palimpsest#112 retired the vendored `inkpot-monkey/supernote` fork for a pin on
upstream. The fork carried its OWN alembic migrations, so a database it created is stamped with a
revision upstream has never heard of. Upstream's alembic then refuses to start at all:

    alembic.util.exc.CommandError: Can't locate revision identified by '9d2f7b3c1a08'

That is a hard startup failure, not a warning — and because `supernote-account-bootstrap` has
`Requires=supernote-server.service` with no start timeout, a crash-looping server turns into a
`nixos-rebuild` that hangs forever rather than failing. It cost a 35-minute outage on rk1b on
2026-08-17 before it was diagnosed.

WHY A RE-STAMP IS THE RIGHT FIX, AND NOT A HACK. The fork and upstream converged on the SAME
schema by independent routes — upstream implemented the device planner surface itself rather than
cherry-picking the fork (ADR-0031, 2026-08-13 revision). Verified on the real rk1b database:
upstream's initial schema creates 13 tables and the fork database has exactly those 13; every one
of the nine columns upstream's head migration adds to `t_schedule_task` is already present; and
the three columns the fork has in addition are all safe for upstream to insert around
(`device_task_id` and `last_modified` nullable, `is_deleted` NOT NULL but DEFAULT 0).

So there is no schema work to do. The ONLY thing wrong is the bookkeeping row that tells alembic
where it is. This rewrites that row and nothing else — no DDL, no data.

WHAT IT REFUSES TO DO. It re-stamps exactly one known revision, and only after re-checking the
column evidence on the actual database in front of it rather than trusting the revision string.
Any other unrecognised revision is a hard failure: a database from a DIFFERENT fork lineage might
be stamped with something equally unknown while having a genuinely divergent schema, and silently
declaring such a database "at head" would let upstream run against a shape it does not expect and
corrupt it. Failing to start is recoverable; a wrong stamp may not be.

Idempotent: a database already on an upstream revision is left untouched, so this is safe as an
ExecStartPre that runs on every server start, including crash restarts.
"""

import shutil
import sqlite3
import sys
import time
from pathlib import Path

# The vendored fork's head. The single revision this script knows how to translate.
FORK_REVISION = "9d2f7b3c1a08"

# Upstream's alembic history, as of the pinned rev (supernote/alembic/versions/). If a future pin
# adds migrations, add them here — an unknown revision is deliberately fatal, so a stale list
# fails loudly rather than silently mis-stamping.
UPSTREAM_INITIAL = "0543a383957b"
UPSTREAM_HEAD = "7a8291f043bc"
UPSTREAM_REVISIONS = {UPSTREAM_INITIAL, UPSTREAM_HEAD}

# The columns upstream's head migration (7a8291f043bc) adds to `t_schedule_task`. Their presence
# is what proves this fork database really did converge on upstream's shape, rather than merely
# claiming an unfamiliar revision. Checked against the database, not inferred from the revision.
HEAD_COLUMNS = {
    "links",
    "sort",
    "sort_completed",
    "planer_sort",
    "all_sort",
    "all_sort_completed",
    "sort_time",
    "planer_sort_time",
    "all_sort_time",
}


def fail(message):
    raise SystemExit(f"supernote-db-stamp: {message}")


def current_revision(conn):
    """The single row of `alembic_version`, or None if the table does not exist yet."""
    try:
        rows = conn.execute("select version_num from alembic_version").fetchall()
    except sqlite3.OperationalError:
        return None
    if len(rows) != 1:
        fail(f"expected exactly one alembic_version row, found {len(rows)}")
    return rows[0][0]


def schedule_task_columns(conn):
    return {row[1] for row in conn.execute("PRAGMA table_info(t_schedule_task)")}


def main():
    if len(sys.argv) != 2:
        fail("usage: supernote-db-stamp.py <path to supernote.db>")
    database = Path(sys.argv[1])

    # A fresh deployment has no database yet; upstream's alembic will create one at head. Nothing
    # to translate, and nothing to warn about.
    if not database.exists():
        print("supernote-db-stamp: no database yet — upstream will create one at head")
        return

    conn = sqlite3.connect(database)
    revision = current_revision(conn)

    if revision is None:
        print(
            "supernote-db-stamp: database has no alembic_version table — leaving it alone"
        )
        return

    if revision in UPSTREAM_REVISIONS:
        print(
            f"supernote-db-stamp: already on upstream revision {revision} — nothing to do"
        )
        return

    if revision != FORK_REVISION:
        fail(
            f"the database is stamped {revision!r}, which is neither an upstream revision "
            f"({sorted(UPSTREAM_REVISIONS)}) nor the known vendored fork head "
            f"({FORK_REVISION!r}). Refusing to guess: re-stamping a database whose schema may "
            "genuinely differ from upstream's would let the server corrupt it. Inspect the "
            "schema by hand, and extend this script only once you have evidence it converged."
        )

    # The revision says "fork". Confirm the SCHEMA agrees before acting on that claim.
    missing = HEAD_COLUMNS - schedule_task_columns(conn)
    if missing:
        fail(
            f"the database is stamped as the vendored fork ({FORK_REVISION}) but "
            f"t_schedule_task is missing {sorted(missing)}, which upstream's head migration "
            "adds. This fork database did NOT converge on upstream's schema, so a re-stamp "
            "would be a lie. It needs a real migration, not this."
        )

    # Snapshot before touching it. The change is one row and the schema check above is strong,
    # but this is the device's sync store and the whole failure mode being fixed here is one
    # nobody predicted — so leave a copy that predates the only write this script ever makes.
    backups = database.parent.parent / "backups"
    backups.mkdir(mode=0o700, parents=True, exist_ok=True)
    snapshot = backups / f"supernote-pre-stamp-{time.strftime('%Y-%m-%d-%H%M%S')}.db"
    shutil.copy2(database, snapshot)

    conn.execute("update alembic_version set version_num = ?", (UPSTREAM_HEAD,))
    conn.commit()
    print(
        f"supernote-db-stamp: re-stamped the vendored fork's {FORK_REVISION} onto upstream's "
        f"{UPSTREAM_HEAD} (schema already matched; snapshot at {snapshot})"
    )


if __name__ == "__main__":
    main()
