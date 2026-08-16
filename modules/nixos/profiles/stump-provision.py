#!/usr/bin/env python3
"""Bootstrap the Stump owner account, the three series-priority libraries, and the OPDS credential.

Stump has no declarative configuration for any of it: the first account is claimed through
`POST /api/v2/auth/register` (the server grants owner rights to the first user on an empty
database, then refuses unauthenticated registration), libraries are created through the GraphQL
`createLibrary` mutation, and API keys through `createApiKey`. This codifies all three, the same
way navidrome-provision-users.py codifies Navidrome's admin-UI clicking.

The reason the LIBRARIES must be codified rather than clicked: a library's scan pattern
(`libraryPattern: SERIES_BASED`) is immutable after creation. Getting it wrong means deleting the
library — and its reading progress — to fix it.

The reason the OPDS CREDENTIAL must be codified rather than clicked: it has to be minimally
scoped, and the only way to get a genuinely scoped key out of Stump is a chain of three steps that
is easy to get subtly wrong by hand (see ensure_opds_credential below).

Reads (paths via env, populated from systemd LoadCredential so secrets never hit argv/environ):
  STUMP_USER_FILE           the owner account's username
  STUMP_PASSWORD_FILE       the owner account's password
  STUMP_OPDS_PASSWORD_FILE  the dedicated OPDS reader account's password
  STUMP_OPDS_URL_FILE       the banked OPDS catalog URL (may be empty before it is minted)
  STUMP_URL                 base URL of the local Stump (e.g. http://127.0.0.1:10001)
  STUMP_LIBRARIES           JSON list of {"name": ..., "path": ...} — the libraries to ensure
  STUMP_OPDS_USER           username of the dedicated, non-owner OPDS reader account
  STUMP_PUBLIC_URL          the edge origin the catalog URL is built from (https://library.<domain>)
  STUMP_OPDS_HANDOFF        where a freshly minted catalog URL is written for the operator

Create-only by design where curation could be lost: a library that already exists is left
completely untouched (name, pattern, ignore rules, curation), so this can run on every deploy.
The OPDS reader account is machine-owned instead, so it is converged rather than left alone.
Fail-loud (non-zero exit) so a broken run shows up as a failed unit instead of an empty catalog.
"""

import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path

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
# Stump serves OPDS 1.2 twice: at `/opds/v1.2/...`, which needs an Authorization header, and at
# `/opds/{api_key}/v1.2/...`, which carries the credential in the path instead — the route
# upstream added for clients that cannot send auth headers, and the one the Supernote's sideloaded
# reader uses (#115). Everything below exists to make that second route's key MINIMALLY scoped,
# which is not what you get by clicking "new API key" in the UI.
#
# WHY A DEDICATED, NON-OWNER ACCOUNT. A key carries either its owner's permissions ("inherit") or
# an explicit custom subset. The subset looks like scoping and, on the server owner, is not:
# `AuthContext::enforce_permissions` returns Ok unconditionally when `is_server_owner`, and
# `validate_api_key` preserves that flag when it applies the key's custom permissions
# (apps/server/src/middleware/auth.rs). So a "read-only" key minted by the owner can still create
# libraries and manage users — the scope is recorded and never consulted. The only way the subset
# is enforced is for the key to belong to an account that is not the owner. Hence a second,
# machine-owned account whose whole purpose is to hold this key.
#
# THE TWO PERMISSION SETS, AND WHY THEY DIFFER.
#   * The ACCOUNT needs `DOWNLOAD_FILE` (the only permission any OPDS 1.2 route enforces —
#     `serve_media_file` gates the acquisition link on it; browsing enforces nothing beyond
#     authentication) and `ACCESS_API_KEYS` (without it `validate_api_key` rejects every key the
#     account holds, and `createApiKey` refuses to mint one). Neither implies anything else:
#     `AssociatedPermission` maps both to the empty set.
#   * The KEY gets `DOWNLOAD_FILE` only. Dropping `ACCESS_API_KEYS` from the key means the
#     credential that leaves this host cannot mint further credentials — the account can, but the
#     account's password never leaves the sops file.
# Note the tightening upstream made in 0.1.3/0.1.4: new accounts get NO permissions by default and
# key permission matching was fixed. A key that works in the UI but 403s on OPDS is this, not the
# endpoint — which is why the health check below asserts the exact resolved permission set rather
# than just "the request returned 200".
OPDS_KEY_NAME = "opds-catalog"
OPDS_KEY_PERMISSIONS = ["DOWNLOAD_FILE"]
OPDS_ACCOUNT_PERMISSIONS = ["ACCESS_API_KEYS", "DOWNLOAD_FILE"]

# The shape of the credential the device is given. Everything but `<key>` is public repo content
# (the `library` service entry in parts/settings.nix); the key is the whole secret.
CATALOG_URL = re.compile(r"^https?://[^/]+/opds/(?P<key>[^/]+)/v1\.2/catalog/?$")

CREATE_USER = """
mutation CreateUser($input: CreateUserInput!) { createUser(input: $input) { id username } }
"""
UPDATE_USER = """
mutation UpdateUser($id: ID!, $input: UpdateUserInput!) {
  updateUser(id: $id, input: $input) { id username }
}
"""
# `ApikeyInput`, not `APIKeyInput`: async-graphql folds a run of leading capitals to title case when
# it derives the SDL name, so the Rust `APIKeyInput` is published as `ApikeyInput` (and the object as
# `Apikey`) while `CreatedAPIKey` — named by a different derive — keeps its capitals. Reading the
# Rust struct is therefore not enough to know the wire name; crates/graphql/schema.graphql is the
# only authority. Getting it wrong fails at request time, not at startup: the server answers
# `Unknown type "APIKeyInput"` and provisioning dies after the account already exists.
CREATE_API_KEY = """
mutation CreateApiKey($input: ApikeyInput!) {
  createApiKey(input: $input) { secret apiKey { id name } }
}
"""
DELETE_API_KEY = "mutation DeleteApiKey($id: Int!) { deleteApiKey(id: $id) { id } }"


def catalog_url(secret):
    return f"{PUBLIC_URL}/opds/{secret}/v1.2/catalog"


def key_from_url(url):
    """The key embedded in a catalog URL, or None if the URL is not one."""
    match = CATALOG_URL.match(url)
    return match.group("key") if match else None


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
        f"{OPDS_ACCOUNT_PERMISSIONS} — it is not the server owner, which is what makes the "
        "key's scope enforceable"
    )


def reader_session(reader, password):
    """Log in as the reader. If the account rejects the password from the secret store, reset it
    (as the owner) to match and retry: the account is machine-owned, so the sops file is its
    source of truth, and the alternative — failing until someone deletes the user in the UI —
    leaves the catalog credential unmintable for no good reason."""
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


def key_complaint(key, reader):
    """None if `key` is a live, minimally scoped credential for `reader`; otherwise why it is not.

    Both halves matter. `/api/v2/auth/me` reports the permission set the server RESOLVED for the
    key, which is the only way to tell a scoped key from one that merely records a scope (see the
    server-owner note above). The catalog fetch then proves the actual route the device will use,
    rather than inferring it from the permission set."""
    bare = (
        urllib.request.build_opener()
    )  # no cookie jar: a session would mask a dead key
    try:
        viewer = api(
            "GET",
            "/api/v2/auth/me",
            opener=bare,
            headers={"Authorization": f"Bearer {key}"},
        )
    except urllib.error.HTTPError as err:
        return f"the server rejected it ({err.code} {err.reason})"
    except (urllib.error.URLError, OSError) as err:
        return f"the server could not be asked about it ({err})"

    if viewer.get("username") != reader:
        return f"it belongs to {viewer.get('username')!r}, not the reader account {reader!r}"
    if viewer.get("isServerOwner"):
        return "it belongs to the server owner, whose permissions are never enforced"
    granted = sorted(viewer.get("permissions") or [])
    if granted != sorted(OPDS_KEY_PERMISSIONS):
        return f"it resolves to {granted}, not {sorted(OPDS_KEY_PERMISSIONS)}"

    try:
        # Not `api()`: an OPDS feed is XML, so there is nothing to decode as JSON. Reaching a
        # 200 with no Authorization header at all is the whole assertion.
        with bare.open(BASE + f"/opds/{key}/v1.2/catalog", timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as err:
        return f"the catalog route refused it ({err.code} {err.reason})"
    except (urllib.error.URLError, OSError) as err:
        return f"the catalog route could not be reached ({err})"
    return None


def mint_key(reader, password):
    """Mint a fresh minimally scoped key for the reader and return its secret."""
    opener = reader_session(reader, password)
    # Stump stores only a hash of a key, so a same-named key left over from an earlier run is
    # unrecoverable dead weight — and leaving it would quietly keep a second live credential in
    # existence. Drop it before minting.
    for existing in graphql("query { apiKeys { id name } }", opener=opener)["apiKeys"]:
        if existing["name"] == OPDS_KEY_NAME:
            graphql(DELETE_API_KEY, {"id": existing["id"]}, opener=opener)
            print(
                f"stump: revoked the previous, unrecoverable {OPDS_KEY_NAME!r} API key"
            )
    created = graphql(
        CREATE_API_KEY,
        {
            "input": {
                "name": OPDS_KEY_NAME,
                "permissions": {"custom": OPDS_KEY_PERMISSIONS},
            }
        },
        opener=opener,
    )["createApiKey"]
    print(
        f"stump: minted the {OPDS_KEY_NAME!r} API key for {reader!r}, scoped to "
        f"{OPDS_KEY_PERMISSIONS}"
    )
    return created["secret"]


def bank_it(handoff, minted):
    """Tell the operator to move the credential into the secret store. Deliberately without the
    URL: this host ships its journal to VictoriaLogs, and a credential printed once is a
    credential stored forever in the log store."""
    lead = "minted a new OPDS catalog URL" if minted else "has an OPDS catalog URL"
    print(
        f"stump: {lead} that is NOT in the secret store. It is a credential — whoever holds it "
        f"can browse and download the whole library. Read it from {handoff} (as root or the "
        "stump user), add it to the `library` sops file as `stump/opds_url`, commit + push the "
        "secrets repo, `nix flake update secrets` here, and redeploy.",
        file=sys.stderr,
    )


def ensure_opds_credential():
    """Reconcile the catalog credential against the secret store.

    Resolution order, and why: the URL banked in sops is authoritative because it is the copy the
    device was given, so if it is live there is nothing to do. Falling back to the handoff file
    before minting is what stops a credential rotation on every single deploy while the operator
    has not banked it yet — otherwise an un-banked URL would be silently invalidated the next
    time this ran, and the device would 401 with nothing having visibly changed."""
    reader = os.environ["STUMP_OPDS_USER"]
    password = read_file(os.environ["STUMP_OPDS_PASSWORD_FILE"])
    handoff = Path(os.environ["STUMP_OPDS_HANDOFF"])
    banked = read_file(os.environ["STUMP_OPDS_URL_FILE"])

    ensure_reader_account(reader, password)

    if banked:
        key = key_from_url(banked)
        if key is None:
            raise SystemExit(
                "stump: `stump/opds_url` in the secret store is not a catalog URL — expected "
                "https://<host>/opds/<key>/v1.2/catalog"
            )
        complaint = key_complaint(key, reader)
        if complaint is None:
            print("stump: the OPDS catalog URL from the secret store is live")
            return
        print(
            f"stump: WARNING the banked OPDS catalog URL no longer works — {complaint}",
            file=sys.stderr,
        )

    if handoff.exists():
        key = key_from_url(read_file(handoff))
        if key and key_complaint(key, reader) is None:
            bank_it(handoff, minted=False)
            return

    secret = mint_key(reader, password)
    # 0600 before the bytes land: the file must never exist world-readable, not even briefly.
    with os.fdopen(
        os.open(
            handoff, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR
        ),
        "w",
        encoding="utf-8",
    ) as fh:
        fh.write(catalog_url(secret) + "\n")
    bank_it(handoff, minted=True)


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
