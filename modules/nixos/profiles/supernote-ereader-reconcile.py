#!/usr/bin/env python3
"""Mirror the Supernote store's ``ereader/`` folder down into ``library/ereader/``.

ADR-0031's governing 2026-08-13 revision moved book delivery to an OPDS pull (the device fetches
from Stump), so nothing is injected into the store any more. What is left is the half that only the
Private Cloud can carry: the handwriting coming back. This reconciler is therefore a **pure
downward mirror** — ``library/ereader/`` is a materialisation of the store, never a source.

palimpsest#117 removed the upload half outright, and with it the two pieces of state that existed
only to serve it (see the "no baseline" note below): the one-shot outbox send, the last-synced
baseline, and the baseline-gated store-loss guard. The rule the guard expressed is not removed —
it is re-expressed below against the *existence of the remote folder*.

  * **Downloads.** Files the mirror lacks, or whose content differs from the store's, are
    ``download_content``ed in as REAL files — which is what the tree is for: git-annex replicates
    and backs up real content, and Stump (#93) indexes real files, not opaque store blobs.
  * **Deletes.** Files in the mirror but absent from the store are removed, so a document deleted
    on the device propagates device -> store -> ``library/`` and *stays gone*.

**Why there is no baseline any more.** The delete direction used to be ambiguous: a file present
in ``library/`` but absent from the store was *either* a fresh local add *or* a device-side delete,
and a remembered snapshot of the previous sync was what told them apart. With no upload path there
are no local adds — the mirror only ever contains what this script put there — so absence from the
store is unambiguous and the snapshot has nothing left to disambiguate.

**The store-loss guard, restated — and why it keys on the FOLDER, not on emptiness.** An empty or
unreachable store must never cause deletions in the backed-up tree. Both halves hold without any
persisted state:

  * *unreachable* — login happens before any library mutation, so an unreachable store fails the
    unit having touched nothing;
  * *lost* — the remote ``ereader`` folder does not exist at all. That is what a wiped or freshly
    rebuilt store looks like (the store is deliberately un-backed-up and rebuildable, ADR-0031):
    the folder is created by the device putting something there, so a store the device has not
    re-seeded has no such folder. Deletes are skipped wholesale in that case.

The discriminator is **folder-absent**, not **listing-empty**, and the difference is load-bearing.
Keying on emptiness looks safer and is actually wrong: the device deleting its *last* remaining
document leaves a live store whose listing is empty, and treating that as loss would swallow
precisely the delete this reconciler exists to propagate — permanently, since nothing would ever
distinguish the two afterwards. A live store the user emptied still HAS the folder, because
upstream's delete removes only the addressed node and never prunes its parents
(``server/services/file.py`` ``delete_item`` -> ``vfs.delete_node``). So an empty listing under an
existing folder is an honest "the device holds nothing", and deletes proceed.

Reads (all via env; secrets arrive as files from systemd LoadCredential, never argv/environ):
  SUPERNOTE_URL            base URL of the local Supernote server (e.g. http://127.0.0.1:8080)
  SUPERNOTE_USER_FILE      file holding the Supernote account email (the shared credential)
  SUPERNOTE_PASSWORD_FILE  file holding the account password
  EREADER_LOCAL_DIR        the downward mirror (e.g. /var/cache/library/ereader)
  EREADER_REMOTE_DIR       device VFS source (e.g. /DOCUMENT/Document/ereader)

Fail-loud (non-zero exit) so a broken reconcile shows up as a failed unit. Emits a single
``ereader reconcile: downloaded=<a> deleted=<b>`` summary line the VM check asserts on.
"""

import asyncio
import hashlib
import os
import random
import sys
from pathlib import Path

from supernote.client import Supernote
from supernote.client.exceptions import NotFoundException, UnauthorizedException

# ── Login retry (palimpsest#112, upstream gap #142) ──────────────────────────────────────────
# Upstream's login is a two-step challenge: GET /api/official/user/query/random/code makes the
# server store ONE challenge per account (`challenge:{account}` — supernote/server/services/
# user.py generate_random_code), then POST login submits a hash of it plus the issuing timestamp,
# which `verify_login_hash` requires to equal the STORED timestamp. There is one slot per account,
# so two logins for the same account that interleave clobber each other and the loser gets a
# misleading 401 "Invalid credentials".
#
# We are structurally exposed to that: ADR-0031 gives the device and this reconciler ONE shared
# account, and the reconciler is fired BY the device's sync — so its login runs exactly when the
# device is also authenticating. This is not a test artefact; it bites in production.
#
# Retrying is the honest fix at this layer: a lost challenge is transient and a fresh challenge
# succeeds, while a genuinely wrong credential 401s on every attempt and still fails the unit
# loudly (just a few seconds later). Jittered backoff so a retry does not re-collide with the
# same competing client.
LOGIN_ATTEMPTS = 5
LOGIN_BACKOFF_BASE = 0.7

URL = os.environ["SUPERNOTE_URL"].rstrip("/")
# The downward mirror (git-annex tree).
LOCAL_DIR = Path(os.environ["EREADER_LOCAL_DIR"])
# The device shows documents under DOCUMENT/Document (the firmware's two-level doc root —
# supernote/server/services/user.py seeds it); the trailing subfolder is created on the device.
REMOTE_DIR = os.environ["EREADER_REMOTE_DIR"].rstrip("/")


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def md5(data):
    return hashlib.md5(data).hexdigest()


def rel_of(entry):
    """The path of a remote entry relative to REMOTE_DIR (e.g. ``scifi/x.pdf``)."""
    prefix = f"{REMOTE_DIR}/"
    if entry.path_display and entry.path_display.startswith(prefix):
        return entry.path_display[len(prefix) :]
    return entry.name


async def store_snapshot(sn):
    """``(folder_exists, {rel: md5})`` for the remote ereader folder.

    The server's ``content_hash`` IS the file's md5 (``upload_content`` finishes with the same md5
    ``list_folder`` reads back — ADR-0031's "the md5 content_hash is exact"), so these values compare
    directly against the locally-computed md5s in ``local_snapshot``.

    ``folder_exists`` is returned separately from the snapshot because an empty snapshot has two
    very different meanings and only one of them is store loss — see the module header. A missing
    folder 404s as NotFoundException and is reported as ``(False, {})``; a folder that exists and
    holds nothing is ``(True, {})``. Every other failure (auth, transient network, malformed
    response) propagates and fails the unit *before* any library mutation, so a flaky list can never
    trigger a spurious delete. Folders carry no content_hash and are skipped; only files count.
    """
    try:
        listing = await sn.device.list_folder(REMOTE_DIR, recursive=True)
    except NotFoundException:
        return False, {}
    return True, {rel_of(e): e.content_hash for e in listing.entries if e.content_hash}


def local_snapshot():
    """``{rel: md5}`` for every real file currently under the mirror."""
    snap = {}
    if LOCAL_DIR.is_dir():
        for p in sorted(LOCAL_DIR.rglob("*")):
            if p.is_file():
                snap[p.relative_to(LOCAL_DIR).as_posix()] = md5(p.read_bytes())
    return snap


async def mirror_down(sn, folder_exists, store):
    """Materialise the store into ``library/ereader/``: download what is new, remove what is gone.

    The store is authoritative in both directions — the mirror holds only what this function put
    there, so a file it lacks is new and a file the store lacks was deleted on the device.

    The one exception is a store with NO remote ereader folder, which skips deletes entirely: that
    is what a wiped or not-yet-re-seeded store looks like, and the tree it would delete from is the
    backed-up one (see the module header for why this keys on the folder rather than on an empty
    listing). An unreachable store never reaches here — login fails first, before any mutation.
    """
    local = local_snapshot()
    downloaded = 0
    deleted = 0

    # Additions / content updates. `digest` is the store's content_hash, which the server sets to
    # the file's md5 (see store_snapshot), so it compares directly against the md5 in `local`.
    for rel, digest in sorted(store.items()):
        if local.get(rel) == digest:
            continue
        content = await sn.device.download_content(f"{REMOTE_DIR}/{rel}")
        dest = LOCAL_DIR / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        downloaded += 1
        print(f"ereader reconcile: downloaded {rel}")

    # Deletes — durable device-side deletes, unless the remote folder is gone entirely (the guard).
    if not folder_exists:
        if local:
            print(
                f"ereader reconcile: no {REMOTE_DIR} in the store — keeping "
                f"{len(local)} mirrored file(s); a store with no ereader folder is a wiped or "
                "not-yet-re-seeded one and must not delete from the backed-up tree"
            )
        return downloaded, deleted

    for rel in sorted(local):
        if rel not in store:
            (LOCAL_DIR / rel).unlink()
            deleted += 1
            print(f"ereader reconcile: deleted {rel}")
    return downloaded, deleted


async def login(user, password):
    """Log in, retrying a 401 that is really a lost login challenge (see LOGIN_ATTEMPTS above).

    Only ``UnauthorizedException`` is retried, and only up to ``LOGIN_ATTEMPTS``: a genuinely bad
    credential 401s every time and still ends up raising, so the unit fails loudly as before. Any
    other error (unreachable store, malformed response) propagates on the first attempt — the
    reconciler must not soldier on into the library mutation when the store is not answering.
    """
    for attempt in range(1, LOGIN_ATTEMPTS + 1):
        try:
            return await Supernote.login(user, password, host=URL)
        except UnauthorizedException:
            if attempt == LOGIN_ATTEMPTS:
                raise
            delay = LOGIN_BACKOFF_BASE * attempt * (1 + random.random())
            print(
                f"ereader reconcile: login 401 (attempt {attempt}/{LOGIN_ATTEMPTS}) — "
                f"probably a lost login challenge, retrying in {delay:.1f}s"
            )
            await asyncio.sleep(delay)
    raise AssertionError("unreachable")


async def run():
    user = read_file(os.environ["SUPERNOTE_USER_FILE"])
    password = read_file(os.environ["SUPERNOTE_PASSWORD_FILE"])

    # Login first: an unreachable store fails HERE, before any library mutation — the "unreachable"
    # half of the store-loss guard.
    async with await login(user, password) as sn:
        folder_exists, store = await store_snapshot(sn)
        downloaded, deleted = await mirror_down(sn, folder_exists, store)

    print(f"ereader reconcile: downloaded={downloaded} deleted={deleted}")


def main():
    try:
        asyncio.run(run())
    except Exception as err:  # noqa: BLE001 — surface any failure as a failed unit.
        print(f"ereader reconcile: FAILED: {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
