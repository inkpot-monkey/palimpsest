#!/usr/bin/env python3
"""Push the `library/ereader/` folder onto the Supernote, over the client HTTP API only.

The outbound half of the Supernote round-trip (ADR-0031, palimpsest#94): a dedicated
`ereader/` folder in the git-annex library tree whose contents are uploaded to the device's
VFS. Drop a PDF/EPUB into `library/ereader/` = "put this on my Supernote". This is fired by
the sync-coupled watcher (supernote-ereader-watch) only while the device is actively syncing;
the book appears on the device on the *next* sync (the fork's realtime channel is connect-only).

Idempotent and one-directional by construction:
  * md5 loop-guard — each local file's md5 is checked against the `content_hash`es already
    under the remote ereader folder (via `device.list_folder`); a file whose content is
    already present is skipped, so a no-change run transfers nothing.
  * never deletes, never pulls, never converts — this only ever *adds* local files the device
    lacks. Annotations flowing back (device -> library) are a separate, deferred ticket.

Reads (all via env; secrets arrive as files from systemd LoadCredential, never argv/environ):
  SUPERNOTE_URL            base URL of the local fork server (e.g. http://127.0.0.1:8080)
  SUPERNOTE_USER_FILE      file holding the Supernote account email (the shared credential)
  SUPERNOTE_PASSWORD_FILE  file holding the account password
  EREADER_LOCAL_DIR        local folder to push (e.g. /var/cache/library/ereader)
  EREADER_REMOTE_DIR       device VFS destination (e.g. /DOCUMENT/Document/ereader)

Fail-loud (non-zero exit) so a broken push shows up as a failed unit. Emits a single
`ereader push: uploaded=<n> skipped=<m>` summary line the VM check asserts on.
"""

import asyncio
import hashlib
import os
import sys
from pathlib import Path

from supernote.client import Supernote
from supernote.client.exceptions import NotFoundException

URL = os.environ["SUPERNOTE_URL"].rstrip("/")
LOCAL_DIR = Path(os.environ["EREADER_LOCAL_DIR"])
# The device shows uploaded documents under DOCUMENT/Document (the firmware's two-level doc
# root — supernote/server/services/user.py seeds it); the trailing subfolder is auto-created
# by the server on first upload (finish_upload -> ensure_directory_path).
REMOTE_DIR = os.environ["EREADER_REMOTE_DIR"].rstrip("/")


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def md5(data):
    return hashlib.md5(data).hexdigest()


async def remote_hashes(sn):
    """The set of md5 content-hashes already under the remote ereader folder.

    Only a *missing* folder (first-ever push, before any upload created it) lists as empty:
    the server 404s an absent path, surfaced as NotFoundException, which means "nothing there
    yet". Every other failure (auth, transient network, a malformed response) propagates and
    fails the unit — swallowing those would silently re-upload the whole tree on a flaky list,
    which is exactly the non-idempotent behaviour this guard exists to prevent.
    """
    try:
        listing = await sn.device.list_folder(REMOTE_DIR, recursive=True)
    except NotFoundException:
        return set()
    return {e.content_hash for e in listing.entries if e.content_hash}


async def run():
    if not LOCAL_DIR.is_dir():
        # Nothing to push (the folder has not been populated yet) — a no-op success, not a
        # failure: the watcher fires on every device sync whether or not books are queued.
        print("ereader push: uploaded=0 skipped=0 (no local ereader folder)")
        return

    # Every regular file under the tree, so subfolders (library/ereader/scifi/…) map onto the
    # device 1:1. Sorted for a deterministic, readable log order.
    local_files = sorted(p for p in LOCAL_DIR.rglob("*") if p.is_file())

    user = read_file(os.environ["SUPERNOTE_USER_FILE"])
    password = read_file(os.environ["SUPERNOTE_PASSWORD_FILE"])

    uploaded = 0
    skipped = 0
    async with await Supernote.login(user, password, host=URL) as sn:
        present = await remote_hashes(sn)
        for path in local_files:
            content = path.read_bytes()
            digest = md5(content)
            rel = path.relative_to(LOCAL_DIR).as_posix()
            if digest in present:
                skipped += 1
                continue
            remote_path = f"{REMOTE_DIR}/{rel}"
            await sn.device.upload_content(remote_path, content)
            # Guard the loop within a single run too: two local copies of the same bytes
            # upload once, and a re-list is unnecessary.
            present.add(digest)
            uploaded += 1
            print(f"ereader push: uploaded {rel}")

    print(f"ereader push: uploaded={uploaded} skipped={skipped}")


def main():
    try:
        asyncio.run(run())
    except Exception as err:  # noqa: BLE001 — surface any failure as a failed unit.
        print(f"ereader push: FAILED: {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
