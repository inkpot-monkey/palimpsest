#!/usr/bin/env python3
"""Bootstrap the Stump owner account and the three series-priority libraries.

Stump has no declarative configuration for either: the first account is claimed through
`POST /api/v2/auth/register` (the server grants owner rights to the first user on an empty
database, then refuses unauthenticated registration), and libraries are created through the
GraphQL `createLibrary` mutation. This codifies both, the same way navidrome-provision-users.py
codifies Navidrome's admin-UI clicking.

The reason it MUST be codified rather than clicked: a library's scan pattern
(`libraryPattern: SERIES_BASED`) is immutable after creation. Getting it wrong means deleting the
library — and its reading progress — to fix it.

Reads (paths via env, populated from systemd LoadCredential so secrets never hit argv/environ):
  STUMP_USER_FILE      the owner account's username
  STUMP_PASSWORD_FILE  the owner account's password
  STUMP_URL            base URL of the local Stump (e.g. http://127.0.0.1:10001)
  STUMP_LIBRARIES      JSON list of {"name": ..., "path": ...} — the libraries to ensure

Create-only by design: a library that already exists is left completely untouched (name, pattern,
ignore rules, curation), so this can run on every deploy. Fail-loud (non-zero exit) so a broken
run shows up as a failed unit instead of an empty catalog.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

BASE = os.environ["STUMP_URL"].rstrip("/")
LIBRARIES = json.loads(os.environ["STUMP_LIBRARIES"])

# Session cookies: Stump's GraphQL endpoint accepts the same session the REST login mints, which
# avoids minting a long-lived JWT just to run a provisioner.
OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    with OPENER.open(req, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def graphql(query, variables=None):
    payload = {"query": query, "variables": variables or {}}
    result = api("POST", "/api/graphql", payload)
    # GraphQL reports failures in-band with HTTP 200, so an unchecked call would silently
    # "succeed" while creating nothing.
    if result.get("errors"):
        raise SystemExit(f"stump: GraphQL error: {json.dumps(result['errors'])}")
    return result["data"]


def wait_for_server(timeout=180):
    """Block until the server answers. First start runs schema migrations, which take a while."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE}/api/v2/ping", timeout=5) as resp:
                if resp.status == 200:
                    return
        except (urllib.error.URLError, OSError, TimeoutError) as err:  # noqa: PERF203
            last = err
        time.sleep(2)
    raise SystemExit(f"stump: server never answered {BASE}/api/v2/ping ({last})")


def ensure_owner(username, password):
    """Register the single owner account if the server is unclaimed, then log in."""
    if not api("GET", "/api/v2/claim")["isClaimed"]:
        print(
            "stump: server unclaimed — registering the owner from the credential secret"
        )
        api(
            "POST",
            "/api/v2/auth/register",
            {"username": username, "password": password},
        )

    # Always log in, including right after registering: a login failure here means a mis-set
    # credential, and it should fail the unit now rather than at catalog-browse time.
    api("POST", "/api/v2/auth/login", {"username": username, "password": password})
    print(f"stump: logged in as {username}")


def existing_libraries():
    data = graphql(
        "query { libraries { nodes { id name path config { libraryPattern } } } }"
    )
    return {node["path"]: node for node in data["libraries"]["nodes"]}


# Every non-optional field of Stump's LibraryConfigInput has to be supplied — async-graphql has no
# defaults for them. The values below are the deliberate ones for a document library:
#   libraryPattern SERIES_BASED  the immutable decision this whole script exists for
#   watch          true          a file dropped in a root shows up without a manual rescan
#   convertRarToZip/hardDeleteConversions false  Stump must never write into the annex tree
#   processMetadata true         so titles/authors come from the files, not the filenames alone
#   generateKoreaderHashes true  KOReader identifies books by hash for progress sync (ADR-0031)
#   ignoreRules    []            `_originals/` is excluded by PHYSICAL PLACEMENT — it is a sibling
#                                of the roots, not a child. Globs live in the DB and would have to
#                                be re-added by hand after a rebuild; a sibling directory cannot be
#                                forgotten.
LIBRARY_CONFIG = {
    "convertRarToZip": False,
    "hardDeleteConversions": False,
    "generateFileHashes": True,
    "generateKoreaderHashes": True,
    "processMetadata": True,
    "watch": True,
    "libraryPattern": "SERIES_BASED",
    "libraryType": "BOOK",
    "defaultLibraryViewMode": "SERIES",
    "hideSeriesView": False,
    "skipBookOverview": False,
    "processThumbnailColorsEvenWithoutConfig": False,
    "defaultReadingDir": "LTR",
    "defaultReadingMode": "PAGED",
    "defaultReadingImageScaleFit": "HEIGHT",
    "ignoreRules": [],
}

CREATE_LIBRARY = """
mutation CreateLibrary($input: CreateOrUpdateLibraryInput!) {
  createLibrary(input: $input) { id name path config { libraryPattern } }
}
"""


def ensure_libraries():
    present = existing_libraries()
    for wanted in LIBRARIES:
        found = present.get(wanted["path"])
        if found:
            pattern = found["config"]["libraryPattern"]
            # Loud but non-fatal: the pattern is immutable, so this can only be fixed by deleting
            # the library (and its reading progress). That is an operator decision, not ours.
            if pattern != "SERIES_BASED":
                print(
                    f"stump: WARNING {found['name']} ({wanted['path']}) has pattern {pattern}, "
                    "not SERIES_BASED. The pattern is immutable — recreate the library to change it.",
                    file=sys.stderr,
                )
            print(f"stump: library {found['name']} already present at {wanted['path']}")
            continue

        created = graphql(
            CREATE_LIBRARY,
            {
                "input": {
                    "name": wanted["name"],
                    "path": wanted["path"],
                    "config": LIBRARY_CONFIG,
                    "scanAfterPersist": True,
                }
            },
        )["createLibrary"]
        print(
            f"stump: created library {created['name']} at {created['path']} "
            f"({created['config']['libraryPattern']})"
        )


def main():
    wait_for_server()
    ensure_owner(
        read_file(os.environ["STUMP_USER_FILE"]),
        read_file(os.environ["STUMP_PASSWORD_FILE"]),
    )
    ensure_libraries()


if __name__ == "__main__":
    main()
