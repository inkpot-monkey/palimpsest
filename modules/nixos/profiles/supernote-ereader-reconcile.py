#!/usr/bin/env python3
"""Reconcile the Supernote store's ``ereader/`` folder with ``library/ereader/``.

The `ereader` round-trip flipped to lean on the server's own 2-way sync (ADR-0031 v2,
palimpsest#107, superseding the outbound-only push of #94). `library/ereader/` is now a
**downward mirror** of the server store, not a source that pushes up:

  * **One-shot send (outbox).** Files dropped in ``library/ereader-outbox/`` are a deliberate
    inject: each is uploaded once to the store, then *cleared* from the outbox
    (uploads-once-then-clears). After it lands, the server owns its device lifecycle — the outbox
    never re-applies it, so a later device-side delete is durable.
  * **Store -> library mirror.** The store's ``ereader/`` folder is materialised down into the
    git-annex tree: files the tree lacks (or whose content changed) are ``download_content``ed in,
    and files the device deleted are removed — so a device delete propagates
    device -> store -> ``library/`` and *stays gone*. This real-file materialisation is also what
    Stump (#93) indexes.

The delete direction turns on one ambiguity: a file present in ``library/`` but absent from the
store is *either* a fresh local add *or* a device-side delete. We disambiguate with a **last-synced
baseline** — the previous sync's store snapshot (``{rel: md5}``). "Was in the baseline, now gone" =
a real delete -> remove from ``library/``; otherwise it is a fresh add -> leave it. The baseline
lives *inside* the server store's state dir, so it shares the store's fate: a wiped/rebuilt store
loses the baseline too, which is exactly the signal the **store-loss guard** needs (an empty store
with no baseline = "no device sync has completed for this store" -> never delete from the
backed-up tree).

Reads (all via env; secrets arrive as files from systemd LoadCredential, never argv/environ):
  SUPERNOTE_URL            base URL of the local Supernote server (e.g. http://127.0.0.1:8080)
  SUPERNOTE_USER_FILE      file holding the Supernote account email (the shared credential)
  SUPERNOTE_PASSWORD_FILE  file holding the account password
  EREADER_LOCAL_DIR        the downward mirror (e.g. /var/cache/library/ereader)
  EREADER_OUTBOX_DIR       the one-shot send inbox (e.g. /var/cache/library/ereader-outbox)
  EREADER_REMOTE_DIR       device VFS destination (e.g. /DOCUMENT/Document/ereader)
  EREADER_BASELINE         the persisted last-synced snapshot (JSON, inside the server store dir)

Fail-loud (non-zero exit) so a broken reconcile shows up as a failed unit. An unreachable store
fails at login *before* any library mutation, so the guard against nuking the backup holds for the
"unreachable" case too. Emits a single ``ereader reconcile: sent=<a> downloaded=<b> deleted=<c>``
summary line the VM check asserts on.
"""

import asyncio
import hashlib
import json
import os
import sys
from pathlib import Path

from supernote.client import Supernote
from supernote.client.exceptions import NotFoundException

URL = os.environ["SUPERNOTE_URL"].rstrip("/")
# The downward mirror (git-annex tree) and the one-shot send inbox.
LOCAL_DIR = Path(os.environ["EREADER_LOCAL_DIR"])
OUTBOX_DIR = Path(os.environ["EREADER_OUTBOX_DIR"])
# The device shows uploaded documents under DOCUMENT/Document (the firmware's two-level doc root —
# supernote/server/services/user.py seeds it); the trailing subfolder is auto-created by the server
# on first upload (finish_upload -> ensure_directory_path).
REMOTE_DIR = os.environ["EREADER_REMOTE_DIR"].rstrip("/")
BASELINE = Path(os.environ["EREADER_BASELINE"])


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


def load_baseline():
    """The previous sync's store snapshot ``{rel: md5}``.

    Absent or corrupt reads as ``{}`` — which the store-loss guard treats as "no device sync has
    completed for this store incarnation". Since the baseline lives inside the server store dir, a
    wiped store leaves no baseline, so an empty read is the honest signal there.
    """
    try:
        data = json.loads(BASELINE.read_text())
    except (FileNotFoundError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_baseline(snapshot):
    """Persist the post-send store snapshot as the next run's baseline (atomic replace)."""
    BASELINE.parent.mkdir(parents=True, exist_ok=True)
    tmp = BASELINE.with_suffix(".tmp")
    tmp.write_text(json.dumps(snapshot, sort_keys=True))
    tmp.replace(BASELINE)


async def store_snapshot(sn):
    """``{rel: md5}`` for every file under the remote ereader folder.

    The server's ``content_hash`` IS the file's md5 (``upload_content`` finishes with the same md5
    ``list_folder`` reads back — ADR-0031's "the md5 content_hash is exact"), so these values compare
    directly against the locally-computed md5s in ``local_snapshot`` / the outbox.

    A *missing* folder (nothing ever uploaded, before the server auto-creates it) 404s as
    NotFoundException, which means an empty store — not an error. Every other failure (auth,
    transient network, malformed response) propagates and fails the unit *before* any library
    mutation, so a flaky list can never trigger a spurious delete. Folders carry no content_hash
    and are skipped; only files count.
    """
    try:
        listing = await sn.device.list_folder(REMOTE_DIR, recursive=True)
    except NotFoundException:
        return {}
    return {rel_of(e): e.content_hash for e in listing.entries if e.content_hash}


def local_snapshot():
    """``{rel: md5}`` for every real file currently under the mirror."""
    snap = {}
    if LOCAL_DIR.is_dir():
        for p in sorted(LOCAL_DIR.rglob("*")):
            if p.is_file():
                snap[p.relative_to(LOCAL_DIR).as_posix()] = md5(p.read_bytes())
    return snap


async def send_outbox(sn, store):
    """One-shot send: upload each outbox file into the store, then clear it.

    md5-guarded so a file already present in the store (same content) is not re-uploaded — but it is
    *always* removed from the outbox, because the outbox is a one-shot inject, not a mirror. Mutates
    ``store`` in place to include what was sent, so the mirror pass materialises it into
    ``library/ereader/`` in the same run.
    """
    sent = 0
    if not OUTBOX_DIR.is_dir():
        return sent
    for path in sorted(OUTBOX_DIR.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(OUTBOX_DIR).as_posix()
        content = path.read_bytes()
        digest = md5(content)
        if store.get(rel) != digest:
            await sn.device.upload_content(f"{REMOTE_DIR}/{rel}", content)
            store[rel] = digest
            sent += 1
            print(f"ereader reconcile: sent {rel}")
        path.unlink()
    return sent


async def mirror_down(sn, store, baseline):
    """Materialise the store into ``library/ereader/``.

    Downloads files the mirror lacks or whose content changed (the store is authoritative for what
    the device holds), and removes files the device deleted.

    A file in the mirror but absent from the store is deleted ONLY if it was in the baseline
    (present last sync) — a durable device-side delete. A file never in the baseline is a fresh
    local add and is left alone. This baseline gate IS the store-loss guard: the baseline lives
    inside the server store dir (see the module header), so a wiped/rebuilt store comes up with an
    EMPTY baseline too — nothing is "in the baseline", so nothing is deleted and the backed-up tree
    is safe. (An unreachable store never reaches here — login fails first, before any mutation.)
    """
    local = local_snapshot()
    downloaded = 0
    deleted = 0

    # Additions / content updates — the store is authoritative for what the device holds. `digest`
    # is the store's content_hash, which the server sets to the file's md5 (see store_snapshot), so it
    # compares directly against the locally-computed md5 in `local`.
    for rel, digest in sorted(store.items()):
        if local.get(rel) == digest:
            continue
        content = await sn.device.download_content(f"{REMOTE_DIR}/{rel}")
        dest = LOCAL_DIR / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        downloaded += 1
        print(f"ereader reconcile: downloaded {rel}")

    # Deletes — a durable device-side delete: was in the baseline (present last sync), now gone from
    # the store. The `rel in baseline` gate doubles as the store-loss guard (see the docstring).
    for rel in sorted(local):
        if rel not in store and rel in baseline:
            (LOCAL_DIR / rel).unlink()
            deleted += 1
            print(f"ereader reconcile: deleted {rel}")
    return downloaded, deleted


async def run():
    user = read_file(os.environ["SUPERNOTE_USER_FILE"])
    password = read_file(os.environ["SUPERNOTE_PASSWORD_FILE"])
    baseline = load_baseline()

    # Login first: an unreachable store fails HERE, before any library mutation — the "unreachable"
    # half of the store-loss guard.
    async with await Supernote.login(user, password, host=URL) as sn:
        store = await store_snapshot(sn)
        sent = await send_outbox(sn, store)
        downloaded, deleted = await mirror_down(sn, store, baseline)
        # The new baseline is the post-send store snapshot: the durable memory of "what the store
        # held after this sync", so the next run can tell a device delete from a fresh local add.
        save_baseline(store)

    print(f"ereader reconcile: sent={sent} downloaded={downloaded} deleted={deleted}")


def main():
    try:
        asyncio.run(run())
    except Exception as err:  # noqa: BLE001 — surface any failure as a failed unit.
        print(f"ereader reconcile: FAILED: {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
