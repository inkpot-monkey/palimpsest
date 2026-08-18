#!/usr/bin/env python3
"""Mirror the Supernote device's whole store down into ``library/supernote/``.

ADR-0031's governing revision moved book delivery to an OPDS pull, so nothing is injected into the
Private Cloud store any more and the server is kept for one job: getting what the device holds —
above all the handwriting — back into the git-annex tree. This is that job, one direction only.
``library/supernote/`` is a materialisation of the store, never a source.

**Scope is the whole device, deliberately.** An earlier version mirrored only
``/DOCUMENT/Document/ereader``, inherited from the retired push (the outbox created that folder).
It mirrored nothing, because nothing writes there: books reach the device by OPDS into a folder
Private Cloud never syncs, and the handwriting the server exists for lives in ``NOTE/Note`` and
``DOCUMENT/Document``. Listing from the root picks up every system folder the firmware seeds —
Note, Document, MyStyle, Export, Inbox, Screenshot — with no per-folder list to keep in step with
the device.

  * **Downloads.** Files the mirror lacks, or whose content differs, are ``download_content``ed in
    as REAL files: git-annex replicates real content and Stump indexes real files, neither of which
    works on the store's UUID blobs.
  * **Deletes.** Files in the mirror but absent from the store are removed, so deleting a document
    on the device propagates device -> store -> ``library/`` and *stays gone*.

**The one guard: an empty store deletes nothing.** If the store lists no files at all while the
mirror holds some, deletes are skipped wholesale. At this scope that is an honest signal rather
than a guess — an empty listing means the device's ENTIRE virtual filesystem is empty, which is
what a wiped or not-yet-re-seeded store looks like (the store is deliberately un-backed-up and
rebuildable, ADR-0031). It costs one stale sync in the case where someone really did delete
everything on the device, and it does NOT interfere with ordinary deletes: removing one document
among others leaves a non-empty store and propagates immediately.

No other state is needed, and none is kept. The unreachable case is free: login happens before any
library mutation, so a store that is not answering fails the unit having touched nothing.

Reads (all via env; secrets arrive as files from systemd LoadCredential, never argv/environ):
  SUPERNOTE_URL            base URL of the local Supernote server (e.g. http://127.0.0.1:8080)
  SUPERNOTE_USER_FILE      file holding the Supernote account email (the shared credential)
  SUPERNOTE_PASSWORD_FILE  file holding the account password
  MIRROR_DIR               the downward mirror (e.g. /var/cache/library/supernote)

Fail-loud (non-zero exit) so a broken run shows up as a failed unit. Emits a single
``supernote mirror: store=<n> downloaded=<a> deleted=<b>`` summary line the VM check asserts on;
``store=`` is the count the delete decision was made against, so the guard's branch is legible
rather than inferred.
"""

import asyncio
import hashlib
import os
import random
import sys
from pathlib import Path

from supernote.client import Supernote
from supernote.client.exceptions import UnauthorizedException

# ── Login retry (palimpsest#112, upstream gap #142) ──────────────────────────────────────────
# Upstream's login is a two-step challenge and the server stores ONE challenge per account
# (`challenge:{account}` — supernote/server/services/user.py generate_random_code), so two logins
# for the same account that interleave clobber each other and the loser gets a misleading 401
# "Invalid credentials".
#
# We are structurally exposed to that: ADR-0031 gives the device and this mirror ONE shared
# account, and the mirror is fired BY the device's sync — so its login runs exactly when the device
# is also authenticating. This is not a test artefact; it bites in production.
#
# Retrying is the honest fix at this layer: a lost challenge is transient and a fresh challenge
# succeeds, while a genuinely wrong credential 401s on every attempt and still fails the unit
# loudly. Jittered backoff so a retry does not re-collide with the same competing client.
LOGIN_ATTEMPTS = 5
LOGIN_BACKOFF_BASE = 0.7

URL = os.environ["SUPERNOTE_URL"].rstrip("/")
MIRROR_DIR = Path(os.environ["MIRROR_DIR"])

# The whole device VFS. `list_folder` strips the path and falls back to the root directory id when
# nothing is left (server/services/file.py: `clean_path = path_str.strip("/")`, `parent_id = 0`),
# so this never raises NotFound the way a named subfolder can — the root is not a path that has to
# exist, it is the absence of one. That is why there is no folder-missing branch below.
REMOTE_ROOT = "/"


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def md5(data):
    return hashlib.md5(data).hexdigest()


async def store_snapshot(sn):
    """``{rel: md5}`` for every file the device holds, anywhere in its VFS.

    The server's ``content_hash`` IS the file's md5 (``upload_content`` finishes with the same md5
    ``list_folder`` reads back — ADR-0031's "the md5 content_hash is exact"), so these compare
    directly against the locally-computed md5s in ``local_snapshot``. Folders carry no content_hash
    and are skipped; only files count. Any failure (auth, transient network, malformed response)
    propagates and fails the unit BEFORE any library mutation, so a flaky list can never trigger a
    spurious delete.
    """
    listing = await sn.device.list_folder(REMOTE_ROOT, recursive=True)
    return {
        e.path_display.lstrip("/"): e.content_hash
        for e in listing.entries
        if e.content_hash
    }


def local_snapshot():
    """``{rel: md5}`` for every real file currently under the mirror."""
    snap = {}
    if MIRROR_DIR.is_dir():
        for p in sorted(MIRROR_DIR.rglob("*")):
            if p.is_file():
                snap[p.relative_to(MIRROR_DIR).as_posix()] = md5(p.read_bytes())
    return snap


async def mirror_down(sn, store):
    """Materialise the store into the mirror: download what is new, remove what is gone."""
    local = local_snapshot()
    downloaded = 0
    deleted = 0

    for rel, digest in sorted(store.items()):
        if local.get(rel) == digest:
            continue
        content = await sn.device.download_content(f"/{rel}")
        dest = MIRROR_DIR / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        downloaded += 1
        print(f"supernote mirror: downloaded {rel}")

    # The guard — see the module header. An entirely empty device is store loss, not housekeeping.
    if not store and local:
        print(
            f"supernote mirror: the store lists NO files at all — keeping {len(local)} mirrored "
            "file(s); an empty device VFS is a wiped or not-yet-re-seeded store and must not "
            "delete from the backed-up tree"
        )
        return downloaded, deleted

    for rel in sorted(local):
        if rel not in store:
            (MIRROR_DIR / rel).unlink()
            deleted += 1
            print(f"supernote mirror: deleted {rel}")
    return downloaded, deleted


async def login(user, password):
    """Log in, retrying a 401 that is really a lost login challenge (see LOGIN_ATTEMPTS above).

    Only ``UnauthorizedException`` is retried: a genuinely bad credential 401s every time and still
    ends up raising, so the unit fails loudly. Any other error (unreachable store, malformed
    response) propagates on the first attempt — this must not soldier on into a library mutation
    when the store is not answering.
    """
    for attempt in range(1, LOGIN_ATTEMPTS + 1):
        try:
            return await Supernote.login(user, password, host=URL)
        except UnauthorizedException:
            if attempt == LOGIN_ATTEMPTS:
                raise
            delay = LOGIN_BACKOFF_BASE * attempt * (1 + random.random())
            print(
                f"supernote mirror: login 401 (attempt {attempt}/{LOGIN_ATTEMPTS}) — "
                f"probably a lost login challenge, retrying in {delay:.1f}s"
            )
            await asyncio.sleep(delay)
    raise AssertionError("unreachable")


async def run():
    user = read_file(os.environ["SUPERNOTE_USER_FILE"])
    password = read_file(os.environ["SUPERNOTE_PASSWORD_FILE"])

    # Login first: an unreachable store fails HERE, before any library mutation.
    async with await login(user, password) as sn:
        store = await store_snapshot(sn)
        downloaded, deleted = await mirror_down(sn, store)

    print(
        f"supernote mirror: store={len(store)} downloaded={downloaded} deleted={deleted}"
    )


def main():
    try:
        asyncio.run(run())
    except Exception as err:  # noqa: BLE001 — surface any failure as a failed unit.
        print(f"supernote mirror: FAILED: {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
