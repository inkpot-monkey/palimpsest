#!/usr/bin/env python3
"""Bootstrap the Stump owner account, the three series-priority libraries, and the OPDS credential.

Stump has no declarative configuration for any of it: the first account is claimed through
`POST /api/v2/auth/register` (the server grants owner rights to the first user on an empty
database, then refuses unauthenticated registration), libraries are created through the GraphQL
`createLibrary` mutation, and accounts through `createUser`. This codifies all three, the same
way navidrome-provision-users.py codifies Navidrome's admin-UI clicking.

The reason the LIBRARIES must be codified rather than clicked: a library's scan pattern
(`libraryPattern: SERIES_BASED`) is immutable after creation. Getting it wrong means deleting the
library — and its reading progress — to fix it.

The reason the OPDS CREDENTIAL must be codified rather than clicked: it has to belong to a
non-owner account and resolve to exactly one permission, and an account clicked together in the UI
gets neither by default (see ensure_opds_credential below).

Reads (paths via env, populated from systemd LoadCredential so secrets never hit argv/environ):
  STUMP_USER_FILE           the owner account's username
  STUMP_PASSWORD_FILE       the owner account's password
  STUMP_OPDS_PASSWORD_FILE  the dedicated OPDS reader account's password
  STUMP_URL                 base URL of the local Stump (e.g. http://127.0.0.1:10001)
  STUMP_LIBRARIES           JSON list of {"name": ..., "path": ...} — the libraries to ensure
  STUMP_OPDS_USER           username of the dedicated, non-owner OPDS reader account
  STUMP_PUBLIC_URL          the edge origin the catalog URL is built from (https://library.<domain>)

Writes nothing outside the server. Every credential it needs is declared before it runs, so there
is no value to hand back to the operator and no state to keep between runs.

Create-only by design where curation could be lost: a library that already exists is left
completely untouched (name, pattern, ignore rules, curation), so this can run on every deploy.
The OPDS reader account is machine-owned instead, so it is converged rather than left alone.
Fail-loud (non-zero exit) so a broken run shows up as a failed unit instead of an empty catalog.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

BASE = os.environ["STUMP_URL"].rstrip("/")
LIBRARIES = json.loads(os.environ["STUMP_LIBRARIES"])
PUBLIC_URL = os.environ["STUMP_PUBLIC_URL"].rstrip("/")


def new_opener():
    """A cookie jar of its own. Sessions are per-identity here: the owner's session must never
    leak into a request made as the reader, and neither must reach an API-key request — Stump's
    auth middleware prefers a session cookie over the Authorization header, so a stray cookie
    would make a key look valid that is not."""
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))


# Session cookies: Stump's GraphQL endpoint accepts the same session the REST login mints, which
# avoids minting a long-lived JWT just to run a provisioner. This one is the OWNER's.
OPENER = new_opener()


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def api(method, path, body=None, opener=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    for name, value in (headers or {}).items():
        req.add_header(name, value)
    with (opener or OPENER).open(req, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def graphql(query, variables=None, opener=None):
    payload = {"query": query, "variables": variables or {}}
    result = api("POST", "/api/graphql", payload, opener=opener)
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


# ── THE OPDS CREDENTIAL (palimpsest#114) ────────────────────────────────────────────────────
# THE CATALOG CREDENTIAL. Stump serves OPDS 1.2 at `/opds/v1.2/...` and accepts HTTP Basic auth
# there — and ONLY there. `apps/server/src/middleware/auth.rs` gates the `Basic ` branch on
# `is_opds`, and answers an unauthenticated OPDS request with a
# `WWW-Authenticate: Basic realm="stump OPDS v1.2"` challenge, which is how a reader app knows to
# prompt. So the credential the device needs is just this account's username and password, both of
# which are declared — the username as a module option, the password in sops.
#
# WHY NOT AN API KEY. Stump also serves `/opds/{api_key}/v1.2/...`, carrying the credential in the
# path for clients that cannot set a header. That route cannot be provisioned declaratively: keys
# are minted server-side by `create_prefixed_key` -> `generate_key_and_hash`, and `ApikeyInput` has
# no field to supply one, so the value can only be learned after the first deploy and hand-carried
# back into sops. Basic auth needs no such round trip. If palimpsest#115 finds the device's reader
# cannot do Basic auth, the key path is in git history — but it is not carried on spec.
#
# WHY A DEDICATED, NON-OWNER ACCOUNT. The credential must not be the owner's:
# `AuthContext::enforce_permissions` returns Ok unconditionally when `is_server_owner`, so an
# owner credential is unscopeable by construction. A second, machine-owned account is what makes
# the permission set below mean anything.
#
# THE PERMISSION SET. `DOWNLOAD_FILE` alone — the only permission any OPDS 1.2 route enforces
# (`serve_media_file` gates the acquisition link on it; browsing enforces nothing beyond
# authentication). `ACCESS_API_KEYS` is deliberately absent: it was only ever needed so the account
# could hold an API key, and without a key there is nothing for it to authorise. Note upstream's
# 0.1.3/0.1.4 tightening — new accounts get NO permissions by default — which is why the health
# check below asserts the exact set the server RESOLVES rather than just a 200.
OPDS_ACCOUNT_PERMISSIONS = ["DOWNLOAD_FILE"]

CREATE_USER = """
mutation CreateUser($input: CreateUserInput!) { createUser(input: $input) { id username } }
"""
UPDATE_USER = """
mutation UpdateUser($id: ID!, $input: UpdateUserInput!) {
  updateUser(id: $id, input: $input) { id username }
}
"""


def catalog_url():
    """The URL the device is pointed at. It carries no credential — the username and password go
    in the Basic auth prompt — so unlike the API-key form it is safe to log."""
    return f"{PUBLIC_URL}/opds/v1.2/catalog"


def basic_auth(reader, password):
    token = base64.b64encode(f"{reader}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


def find_user(username):
    """The user node with this username, as the owner sees it, or None."""
    nodes = graphql("query { users { nodes { id username } } }")["users"]["nodes"]
    return next((node for node in nodes if node["username"] == username), None)


def ensure_reader_account(reader, password):
    """Create the dedicated OPDS reader account if it is missing. Create-only: converging it on
    every run would fight an operator who has narrowed its library access by hand (Stump hides
    libraries per user via exclusions), and the password is only re-set on the drift path below,
    where the alternative is a permanently red unit."""
    if find_user(reader):
        return
    graphql(
        CREATE_USER,
        {
            "input": {
                "username": reader,
                "password": password,
                "permissions": OPDS_ACCOUNT_PERMISSIONS,
            }
        },
    )
    print(
        f"stump: created the OPDS reader account {reader!r} with "
        f"{OPDS_ACCOUNT_PERMISSIONS} — it is not the server owner, which is what makes that "
        "scope enforceable"
    )


def reader_session(reader, password):
    """Log in as the reader. If the account rejects the password from the secret store, reset it
    (as the owner) to match and retry: the account is machine-owned, so the sops file is its
    source of truth, and the alternative — failing until someone deletes the user in the UI —
    leaves the catalog unreachable for no good reason."""
    opener = new_opener()
    body = {"username": reader, "password": password}
    try:
        api("POST", "/api/v2/auth/login", body, opener=opener)
        return opener
    except urllib.error.HTTPError as err:
        if err.code not in (400, 401):
            raise
    print(
        f"stump: the {reader!r} account rejected the password from the secret store — "
        "resetting the account to match it",
        file=sys.stderr,
    )
    node = find_user(reader)
    if node is None:
        raise SystemExit(
            f"stump: the {reader!r} account vanished between creation and login"
        )
    graphql(
        UPDATE_USER,
        {
            "id": node["id"],
            "input": {
                "username": reader,
                "password": password,
                "permissions": OPDS_ACCOUNT_PERMISSIONS,
            },
        },
    )
    opener = new_opener()
    api("POST", "/api/v2/auth/login", body, opener=opener)
    return opener


def ensure_opds_credential():
    """Make the declared credential work, and prove it does.

    Nothing is minted and nothing is handed back to the operator: the username is a module option
    and the password is in sops, so the credential is fully determined before this runs. All this
    does is converge the server onto it and then verify, which is worth doing at provision time
    because every failure mode here is otherwise silent until the device 401s in someone's hand.
    """
    reader = os.environ["STUMP_OPDS_USER"]
    password = read_file(os.environ["STUMP_OPDS_PASSWORD_FILE"])

    ensure_reader_account(reader, password)

    # The scope as the SERVER resolves it, not as we asked for it. A session login is used rather
    # than Basic auth because Basic is confined to the OPDS routes, and `/api/v2/auth/me` is not
    # one — that confinement is itself part of why this credential is safe to put in a reader app.
    viewer = api("GET", "/api/v2/auth/me", opener=reader_session(reader, password))
    if viewer.get("isServerOwner"):
        raise SystemExit(
            f"stump: the OPDS account {reader!r} is the server owner — its permissions would "
            "never be enforced"
        )
    granted = sorted(viewer.get("permissions") or [])
    if granted != sorted(OPDS_ACCOUNT_PERMISSIONS):
        raise SystemExit(
            f"stump: the OPDS account {reader!r} resolves to {granted}, not "
            f"{sorted(OPDS_ACCOUNT_PERMISSIONS)}"
        )

    # The actual route the device will use, with the actual credential, over Basic auth. Not
    # `api()`: an OPDS feed is XML, so there is nothing to decode as JSON.
    bare = (
        urllib.request.build_opener()
    )  # no cookie jar: a session would mask a bad password
    request = urllib.request.Request(
        BASE + "/opds/v1.2/catalog", headers=basic_auth(reader, password)
    )
    try:
        with bare.open(request, timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as err:
        raise SystemExit(
            f"stump: the OPDS 1.2 catalog refused the {reader!r} credential "
            f"({err.code} {err.reason})"
        ) from err
    except (urllib.error.URLError, OSError) as err:
        raise SystemExit(
            f"stump: the OPDS 1.2 catalog could not be reached ({err})"
        ) from err

    print(
        f"stump: the OPDS 1.2 catalog at {catalog_url()} serves {reader!r} over Basic auth, "
        f"scoped to {granted}"
    )


def main():
    wait_for_server()
    ensure_owner(
        read_file(os.environ["STUMP_USER_FILE"]),
        read_file(os.environ["STUMP_PASSWORD_FILE"]),
    )
    ensure_libraries()
    ensure_opds_credential()


if __name__ == "__main__":
    main()
