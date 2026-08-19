#!/usr/bin/env python3
"""Bootstrap the Stump owner account, the three libraries, and one account per person who reads.

Stump has no declarative configuration for any of it: the first account is claimed through
`POST /api/v2/auth/register` (the server grants owner rights to the first user on an empty
database, then refuses unauthenticated registration), libraries are created through the GraphQL
`createLibrary` mutation, accounts through `createUser` and API keys through `createApiKey`. This
codifies all of it, the same way navidrome-provision-users.py codifies Navidrome's admin-UI
clicking — and, like that one, it takes the people from a sops map, so adding someone is a secret
edit and a redeploy rather than a code change.

The reason the LIBRARIES must be codified rather than clicked: a library's scan pattern
(`libraryPattern: SERIES_BASED`) is immutable after creation. Getting it wrong means deleting the
library — and its reading progress — to fix it.

The reason the READERS must be codified rather than clicked: each one carries two credentials that
a hand-made account gets wrong by default. The catalog credential has to belong to a non-owner
account resolving to exactly three permissions; the KOReader sync credential is an API key, and a
key clicked into being in the UI inherits its owner's whole permission set. Neither mistake is
visible by eye — both look exactly like a working setup.

Reads (paths via env, populated from systemd LoadCredential so secrets never hit argv/environ):
  STUMP_USER_FILE            the owner account's username
  STUMP_PASSWORD_FILE        the owner account's password
  STUMP_READERS_FILE         JSON {name: {password, koreader_key}} — the people who read
  STUMP_URL                  base URL of the local Stump (e.g. http://127.0.0.1:10001)
  STUMP_DB                   path to Stump's SQLite database (see `impose_key`)
  STUMP_LIBRARIES            JSON list of {"name": ..., "path": ...} — the libraries to ensure
  STUMP_PUBLIC_URL           the edge origin device URLs are built from (https://library.<domain>)

Writes nothing outside the server, and hands nothing back. Every credential is declared before
this runs — the passwords and the sync keys are all sops values — so there is no state between
runs, no handoff file, and no second deploy.

Create-only by design where curation could be lost: a library that already exists is left
completely untouched (name, pattern, ignore rules, curation), so this can run on every deploy.
Reader accounts are machine-owned instead, so their password and permissions are converged.
Fail-loud (non-zero exit) so a broken run shows up as a failed unit instead of an empty catalog.
"""

import base64
import hashlib
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

BASE = os.environ["STUMP_URL"].rstrip("/")
DB_PATH = os.environ["STUMP_DB"]
LIBRARIES = json.loads(os.environ["STUMP_LIBRARIES"])
PUBLIC_URL = os.environ["STUMP_PUBLIC_URL"].rstrip("/")

# Stump's API-key prefix (`API_KEY_PREFIX` in crates/models/src/shared/api_key.rs). Declared keys
# must carry it: `handle_bearer_auth` refuses to treat a bearer token as an API key without it.
API_KEY_PREFIX = "stump"

with open(os.environ["STUMP_READERS_FILE"], encoding="utf-8") as _readers:
    READERS = json.load(_readers)


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


# ── KOREADER BOOK IDENTITY (palimpsest#116) ─────────────────────────────────────────────────
# KOReader's sync protocol identifies a book by a hash of its bytes and by NOTHING else: Stump
# does not implement the protocol's filename strategy, and both sync routes look the book up with
# `media::Column::KoreaderHash.eq(document)`. So a book with no `koreaderHash` is invisible to
# sync — the device's PUT answers 404 and nothing on either end says why.
#
# `generateKoreaderHashes` is set at creation (LIBRARY_CONFIG above), but a library config only
# governs books indexed AFTER it, so content already in the catalog needs a scan that RECOMPUTES
# hashes. That is what this does, and once every hashable book has a hash it costs one query per
# deploy and nothing else.
#
# Only PDF and EPUB count as hashable. Upstream's zip and rar processors have the
# koreader-hash call commented out (core/src/filesystem/media/format/{zip,rar}.rs), so a comic can
# never acquire one — counting those would enqueue a rescan on every deploy, forever.
#
# THE FORMAT FILTER IS NOT A COMPLETE GUARD. A PDF or EPUB that the hasher cannot read at all —
# truncated, or a file the `stump` user has lost access to — stays null and is re-scanned on every
# deploy. That is a scan per deploy, not a timer loop, and each book costs about 12 KiB of reads,
# so it is slow rather than dangerous; the names are printed precisely so a book stuck in that
# state is visible in the journal rather than being an invisible tax.
KOREADER_HASHABLE = {"pdf", "epub"}

# ScanConfig is an untagged enum; `{"regenHashes": true}` is its `Custom(CustomVisit)` variant.
# Without it a scan is `BuildChanged`, which visits nothing whose mtime has not moved — so a book
# already in the catalog would keep its missing hash and this would loop forever doing nothing.
REGEN_HASHES = {"config": {"regenHashes": True}}

SCAN_LIBRARY = """
mutation ScanLibrary($id: ID!, $options: JSON) { scanLibrary(id: $id, options: $options) }
"""


def ensure_koreader_hashes():
    """Rescan any library holding hashable books that have no KOReader hash yet.

    A library whose `generateKoreaderHashes` is OFF is reported, not corrected. `updateLibrary`
    replaces the whole config from the input — description, emoji, ignore rules, thumbnail config
    and all — so converging one boolean means echoing every other field back perfectly or silently
    erasing hand curation. The flag is one toggle in the library's settings page, and unlike the
    scan pattern it is not immutable, so this is an operator action rather than a rewrite.
    """
    data = graphql(
        "query { libraries { nodes { id name config { generateKoreaderHashes } "
        "media { name extension koreaderHash } } } }"
    )
    for node in data["libraries"]["nodes"]:
        if not node["config"]["generateKoreaderHashes"]:
            print(
                f"stump: WARNING library {node['name']} does not generate KOReader hashes, so "
                "reading progress from the device can never match its books. Turn on "
                "'KoReader-compatible hashes' in the library's settings, then restart "
                "stump-provision to rescan.",
                file=sys.stderr,
            )
            continue

        missing = [
            book
            for book in node["media"]
            if book["koreaderHash"] is None
            and (book["extension"] or "").lower() in KOREADER_HASHABLE
        ]
        if not missing:
            continue

        graphql(SCAN_LIBRARY, {"id": node["id"], "options": REGEN_HASHES})
        # Named, not just counted: the same names on run after run mean a book the hasher cannot
        # read, which no further scanning will fix — see the note on KOREADER_HASHABLE.
        listed = ", ".join(sorted(book["name"] for book in missing)[:10])
        more = "" if len(missing) <= 10 else f" (+{len(missing) - 10} more)"
        print(
            f"stump: {len(missing)} book(s) in {node['name']} have no KOReader hash — "
            f"enqueued a hash-regenerating scan for: {listed}{more}"
        )


# ── THE READERS (palimpsest#114/#116) ───────────────────────────────────────────────────────
# THE PEOPLE WHO READ. Each reader is a Stump account that is deliberately NOT the server owner,
# and it is the whole of a person's identity here: it browses the OPDS catalog over Basic auth,
# it holds the KOReader sync key, it owns the reading progress, and it is what a human logs into
# the web UI with. The owner account (`stump/user`) is administrative only — the provisioner uses
# it and nothing else does.
#
# WHY NOT JUST USE THE OWNER, when there is only one person in the house. Because the owner cannot
# hold a device credential safely and cannot generalise:
#   * `AuthContext::enforce_permissions` returns `Ok(())` unconditionally when `is_server_owner`
#     (crates/graphql/src/data.rs), and `validate_api_key` preserves that flag when it applies a
#     key's custom permissions. An API key is accepted as a bearer token on EVERY route, so an
#     owner's key is a full administrative credential however it is scoped — and this one lives in
#     a plaintext Lua file on a sideloaded Android tablet.
#   * There is exactly one owner. A design in which the primary human IS the owner has no second
#     step; a design in which every human is a reader adds the next person by adding a map entry.
#
# THE PERMISSION SET, AND WHY IT IS THREE THINGS. Browsing, reading and recording progress are
# enforced by nothing beyond authentication — `updateMediaProgress` carries no `PermissionGuard` at
# all — so a reader needs only what the two credentialled paths check:
#   * DOWNLOAD_FILE       the only permission any OPDS 1.2 route enforces (`serve_media_file`
#                         gates the acquisition link on it).
#   * ACCESS_API_KEYS     without it `validate_api_key` rejects every key the account holds, and
#                         `createApiKey` refuses to mint one. It authorises key *management*, not
#                         anything a key can then do — and the account's password never leaves the
#                         sops file, so nothing on the device can exercise it.
#   * ACCESS_KOREADER_SYNC what the sync routes enforce, and what the key is scoped to. A key's
#                         custom permissions REPLACE the account's rather than intersecting them,
#                         but `check_permissions` on mint refuses a scope the account lacks — so
#                         the account needs it too.
# Deliberately absent: CHANGE_PASSWORD and CHANGE_USERNAME. Both halves of the account are
# declared in sops, so letting the browser edit them would only create drift for the next deploy
# to undo. Note upstream's 0.1.3/0.1.4 tightening — new accounts get NO permissions by default —
# which is why the health checks below assert the set the server RESOLVES rather than just a 200.
READER_PERMISSIONS = [
    "ACCESS_API_KEYS",
    "ACCESS_KOREADER_SYNC",
    "DOWNLOAD_FILE",
]

CREATE_USER = """
mutation CreateUser($input: CreateUserInput!) { createUser(input: $input) { id username } }
"""
UPDATE_USER = """
mutation UpdateUser($id: ID!, $input: UpdateUserInput!) {
  updateUser(id: $id, input: $input) { id username }
}
"""


def catalog_url():
    """The URL a reader points an OPDS client at. It carries no credential — the username and
    password go in the Basic auth prompt — so it is safe to log."""
    return f"{PUBLIC_URL}/opds/v1.2/catalog"


def basic_auth(reader, password):
    token = base64.b64encode(f"{reader}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


def find_user(username):
    """The user node with this username, as the owner sees it, or None."""
    nodes = graphql("query { users { nodes { id username } } }")["users"]["nodes"]
    return next((node for node in nodes if node["username"] == username), None)


def ensure_reader_account(reader, password):
    """Create the reader's account if it is missing. Create-only: converging it wholesale on every
    run would fight an operator who has narrowed its library access by hand (Stump hides libraries
    per user via exclusions). The two fields this file DOES own — the password and the permission
    set — are converged individually below, where the alternative is a permanently red unit."""
    if find_user(reader):
        return
    graphql(
        CREATE_USER,
        {
            "input": {
                "username": reader,
                "password": password,
                "permissions": READER_PERMISSIONS,
            }
        },
    )
    print(
        f"stump: created the reader account {reader!r} with {READER_PERMISSIONS} — it is not "
        "the server owner, which is what makes that scope enforceable"
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
                "permissions": READER_PERMISSIONS,
            },
        },
    )
    opener = new_opener()
    api("POST", "/api/v2/auth/login", body, opener=opener)
    return opener


def converge_reader_permissions(reader, opener):
    """Make the account resolve to exactly READER_PERMISSIONS, and prove it did.

    The scope as the SERVER resolves it, not as we asked for it — the assertion that separates a
    scoped account from one that merely records a scope. Converged rather than merely checked
    because the set has grown before (KOReader sync added two of the three) and will again, so an
    account from an older deploy is a normal state, not an error. Only `permissions` is sent;
    `password` is optional on UpdateUserInput and is left alone."""
    viewer = api("GET", "/api/v2/auth/me", opener=opener)
    if viewer.get("isServerOwner"):
        raise SystemExit(
            f"stump: the reader account {reader!r} is the server owner — its permissions would "
            "never be enforced, and neither would its API key's"
        )
    if sorted(viewer.get("permissions") or []) == sorted(READER_PERMISSIONS):
        return

    print(
        f"stump: the {reader!r} account resolves to "
        f"{sorted(viewer.get('permissions') or [])}, not {sorted(READER_PERMISSIONS)} — "
        "converging it",
        file=sys.stderr,
    )
    node = find_user(reader)
    if node is None:
        raise SystemExit(f"stump: the {reader!r} account vanished mid-run")
    graphql(
        UPDATE_USER,
        {
            "id": node["id"],
            "input": {"username": reader, "permissions": READER_PERMISSIONS},
        },
    )
    granted = sorted(
        api("GET", "/api/v2/auth/me", opener=opener).get("permissions") or []
    )
    if granted != sorted(READER_PERMISSIONS):
        raise SystemExit(
            f"stump: the reader account {reader!r} still resolves to {granted}, not "
            f"{sorted(READER_PERMISSIONS)}"
        )


def verify_opds(reader, password):
    """Fetch the actual route an OPDS client will use, with the actual credential, over Basic
    auth. Not `api()`: an OPDS feed is XML, so there is nothing to decode as JSON."""
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


# ── THE KOREADER SYNC KEY, DECLARED (palimpsest#116) ────────────────────────────────────────
# Reading position round-trips over Stump's own implementation of KOReader's sync protocol, at
# `/koreader/{api_key}/...`. The credential is an API KEY IN THE PATH and cannot be anything else:
# `api_key_middleware` is the only auth on that router, and it reads the key from the URL. Basic
# auth — the answer for OPDS — is gated on `is_opds` and does not reach here.
#
# THE KEY IS DECLARED IN SOPS, NOT MINTED. Stump has no way to be handed a key: `ApikeyInput` has
# no field for one, `createApiKey` always calls `create_prefixed_key()`, and only a hash is kept.
# Taken at face value that forces a value to be learned after the first deploy and hand-carried
# back into the secret store — a two-phase deploy for every fresh database, and a device that has
# to be re-typed whenever the catalog DB is rebuilt.
#
# It is avoidable, because a key is not opaque. `stump_<short>_<long>` is three `_`-delimited
# parts (prefixed-api-key 0.3.0), and validation compares exactly two stored columns: `short_token`
# verbatim, and `long_token_hash`, which `long_token_hashed` computes as
# `hex(sha256(<long>))` under the crate's `seam_defaults()`. So a key WE choose can be made valid
# by writing those two columns — and then the device's URL is fully determined before anything
# runs, exactly like the OPDS password.
#
# WHY IT IS A DATABASE WRITE, AND WHY THAT IS THE SMALL VERSION. Stump still creates the row
# through `createApiKey`, so IT writes every column whose format we would otherwise have to guess
# — the timestamps, the JSON permission set, the primary key. This only rewrites two TEXT columns
# afterwards. The coupling is real (two column names and one hash function) and it is the price of
# not carrying a value by hand; it is bounded by failing LOUDLY at deploy, because the health check
# below then authenticates with the declared key over the real sync route. A schema or hash change
# upstream reddens the unit here rather than silently stopping the device from syncing.
#
# THE KEY'S OWN SCOPE. `ACCESS_KOREADER_SYNC` alone — what the router's `authorize` middleware
# enforces, and nothing more. Custom key permissions REPLACE the account's rather than intersecting
# them, so the key cannot download books or manage keys even though the account that owns it can.
KOREADER_KEY_NAME = "koreader-sync"
KOREADER_KEY_PERMISSIONS = ["ACCESS_KOREADER_SYNC"]

# `ApikeyInput`, not `APIKeyInput`: async-graphql folds a run of leading capitals to title case
# when it derives the SDL name, so the Rust `APIKeyInput` is published as `ApikeyInput` (and the
# object as `Apikey`) while `CreatedAPIKey` — named by a different derive — keeps its capitals.
# Reading the Rust struct is not enough to know the wire name; crates/graphql/schema.graphql is the
# only authority. Getting it wrong fails at request time, not at startup.
CREATE_API_KEY = """
mutation CreateApiKey($input: ApikeyInput!) {
  createApiKey(input: $input) { apiKey { id name } }
}
"""
UPDATE_API_KEY = """
mutation UpdateApiKey($id: Int!, $input: ApikeyInput!) {
  updateApiKey(id: $id, input: $input) { id name }
}
"""


def key_columns(key, reader):
    """The two `api_keys` columns that make `key` valid, or exit explaining what is wrong with it.

    The prefix matters even though the path route ignores it: `handle_bearer_auth` requires
    `stump` before it will treat a bearer token as an API key, and the health check below
    authenticates that way."""
    parts = key.split("_")
    if len(parts) != 3 or parts[0] != API_KEY_PREFIX or not parts[1] or not parts[2]:
        raise SystemExit(
            f"stump: the KOReader sync key for {reader!r} is not a Stump API key. It must look "
            f"like `{API_KEY_PREFIX}_<short>_<long>` — three parts, no other underscores. "
            "Generate one with:  "
            "printf '%s_%s_%s\\n' "
            f'{API_KEY_PREFIX} "$(openssl rand -hex 8)" "$(openssl rand -hex 24)"'
        )
    _, short_token, long_token = parts
    return short_token, hashlib.sha256(long_token.encode()).hexdigest()


def key_row_id(reader, opener):
    """The id of this reader's `koreader-sync` key row, creating or converging it as needed. Only
    the row is managed here — its secret is imposed by `impose_key` below."""
    scope = {
        "name": KOREADER_KEY_NAME,
        "permissions": {"custom": KOREADER_KEY_PERMISSIONS},
    }
    existing = next(
        (
            row
            for row in graphql("query { apiKeys { id name } }", opener=opener)[
                "apiKeys"
            ]
            if row["name"] == KOREADER_KEY_NAME
        ),
        None,
    )
    if existing is None:
        created = graphql(CREATE_API_KEY, {"input": scope}, opener=opener)[
            "createApiKey"
        ]
        print(f"stump: created the {KOREADER_KEY_NAME!r} API key row for {reader!r}")
        # The secret Stump generated is DELIBERATELY discarded and never logged: `impose_key`
        # overwrites the hash a moment later, so it is dead on arrival.
        return created["apiKey"]["id"]

    # Converge name/scope on the row that is already there — cheap, and it means a key edited in
    # the UI cannot quietly widen what the device holds.
    graphql(UPDATE_API_KEY, {"id": existing["id"], "input": scope}, opener=opener)
    return existing["id"]


def impose_key(row_id, reader, key):
    """Make `key` — the value declared in sops — be the secret for this reader's key row.

    Idempotent by comparison, so a steady-state deploy touches the database not at all. A row
    count other than one is fatal: silently patching nothing would leave the device on a key the
    server has never heard of."""
    short_token, long_token_hash = key_columns(key, reader)
    with sqlite3.connect(DB_PATH, timeout=30) as conn:
        current = conn.execute(
            "SELECT short_token, long_token_hash FROM api_keys WHERE id = ?", (row_id,)
        ).fetchone()
        if current is None:
            raise SystemExit(
                f"stump: the {KOREADER_KEY_NAME!r} key row {row_id} for {reader!r} is not in "
                "the database"
            )
        if current == (short_token, long_token_hash):
            return
        changed = conn.execute(
            "UPDATE api_keys SET short_token = ?, long_token_hash = ? WHERE id = ?",
            (short_token, long_token_hash, row_id),
        ).rowcount
    if changed != 1:
        raise SystemExit(
            f"stump: expected to rewrite one api_keys row for {reader!r}, rewrote {changed}"
        )
    print(f"stump: installed the declared KOReader sync key for {reader!r}")


def verify_koreader_key(key, reader):
    """Prove the declared key is live and sync-only, or exit saying why it is not.

    Both halves matter. `/api/v2/auth/me` reports the permission set the server RESOLVED for the
    key, which is the only way to tell a scoped key from one that merely records a scope. The
    `users/auth` fetch then proves the actual router the device will talk to — which also fails if
    `ENABLE_KOREADER_SYNC` is unset, since the router is only mounted when it is true."""
    bare = (
        urllib.request.build_opener()
    )  # no cookie jar: a session would mask a dead key

    def dead(why):
        return SystemExit(
            f"stump: the declared KOReader sync key for {reader!r} does not work — {why}. It is "
            "`stump/readers/<name>/koreader_key` in the `library` sops file."
        )

    try:
        viewer = api(
            "GET",
            "/api/v2/auth/me",
            opener=bare,
            headers={"Authorization": f"Bearer {key}"},
        )
    except urllib.error.HTTPError as err:
        raise dead(f"the server rejected it ({err.code} {err.reason})") from err
    except (urllib.error.URLError, OSError) as err:
        raise dead(f"the server could not be asked about it ({err})") from err

    if viewer.get("username") != reader:
        raise dead(f"it belongs to {viewer.get('username')!r}, not {reader!r}")
    if viewer.get("isServerOwner"):
        raise dead(
            "it belongs to the server owner, whose permissions are never enforced"
        )
    granted = sorted(viewer.get("permissions") or [])
    if granted != sorted(KOREADER_KEY_PERMISSIONS):
        raise dead(f"it resolves to {granted}, not {sorted(KOREADER_KEY_PERMISSIONS)}")

    try:
        answer = api("GET", f"/koreader/{key}/users/auth", opener=bare)
    except urllib.error.HTTPError as err:
        if err.code == 404:
            raise dead(
                "the sync router answered 404, so ENABLE_KOREADER_SYNC is not set on the server "
                "and the routes are not mounted at all"
            ) from err
        raise dead(f"the sync router refused it ({err.code} {err.reason})") from err
    except (urllib.error.URLError, OSError) as err:
        raise dead(f"the sync router could not be reached ({err})") from err
    if (answer or {}).get("authorized") != "OK":
        raise dead(f"the sync router answered {answer!r}")


def ensure_reader(reader, spec):
    """Converge one person's account, catalog credential and sync key, and verify all three.

    Nothing is minted and nothing is handed back: both credentials are fully determined before
    this runs, so there is no state between runs and no second deploy. What this does is make the
    server agree with what was declared, and then check it from the outside — which is worth doing
    here because every failure mode is otherwise silent until a device 401s in someone's hand.
    """
    password = spec.get("password")
    key = spec.get("koreader_key")
    if not password or not key:
        raise SystemExit(
            f"stump: the reader {reader!r} needs both `password` and `koreader_key` under "
            "`stump.readers` in the `library` sops file"
        )

    ensure_reader_account(reader, password)
    opener = reader_session(reader, password)
    converge_reader_permissions(reader, opener)
    verify_opds(reader, password)
    impose_key(key_row_id(reader, opener), reader, key)
    verify_koreader_key(key, reader)

    # The key is never logged — this host ships its journal to VictoriaLogs — so the sync URL is
    # described rather than printed. Its value is already in the operator's hands: they chose it.
    print(
        f"stump: {reader!r} can browse {catalog_url()} over Basic auth and sync reading progress "
        f"at {PUBLIC_URL}/koreader/<stump/readers/{reader}/koreader_key>"
    )


def main():
    wait_for_server()
    ensure_owner(
        read_file(os.environ["STUMP_USER_FILE"]),
        read_file(os.environ["STUMP_PASSWORD_FILE"]),
    )
    ensure_libraries()
    ensure_koreader_hashes()
    if not READERS:
        print(
            "stump: no readers declared — nothing can browse the catalog or sync progress. Add a "
            "`stump.readers` map to the `library` sops file.",
            file=sys.stderr,
        )
    for reader in sorted(READERS):
        ensure_reader(reader, READERS[reader])


if __name__ == "__main__":
    main()
