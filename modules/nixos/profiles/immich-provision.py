"""Provision Immich's admin account from sops, idempotently.

Immich has no declarative path for its first-run account: a fresh instance sits at
`isInitialized: false` and refuses everything until somebody completes the signup
form. That is the one manual step in an otherwise declarative stack, and it blocks
more than itself -- API keys cannot exist before the account does, so the CLI
importer has nothing to authenticate with either.

So drive Immich's own supported API instead, the same way ha-provision-voice.py
drives Home Assistant's config-flow API:

    GET  /api/server/config       -> isInitialized
    POST /api/auth/admin-sign-up  -> create the owner (only works once)
    POST /api/auth/login          -> session token
    POST /api/api-keys            -> a key for the CLI

Idempotent: a provisioned instance reports isInitialized and signup is skipped, so
this is safe on every boot. Fail-loud: a non-zero exit leaves the unit failed
rather than a half-configured server that looks fine.

The password never reaches argv or the environment of anything else -- systemd
hands it over via LoadCredential and it is read from CREDENTIALS_DIRECTORY here.
"""

import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT = 20


def call(base: str, path: str, payload=None, token: str | None = None):
    """POST when given a payload, else GET. Returns parsed JSON (or None)."""
    url = base.rstrip("/") + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        body = resp.read().decode()
    return json.loads(body) if body.strip() else None


def read_credential(name: str) -> str:
    d = os.environ.get("CREDENTIALS_DIRECTORY")
    if not d:
        print("immich-provision: CREDENTIALS_DIRECTORY unset", file=sys.stderr)
        raise SystemExit(1)
    with open(os.path.join(d, name), encoding="utf-8") as fh:
        # Only newlines, matching how the rest of the fleet strips sops values --
        # a password may legitimately begin or end with a space.
        return fh.read().replace("\n", "")


def main() -> int:
    base = os.environ["IMMICH_URL"]
    email = os.environ["IMMICH_ADMIN_EMAIL"]
    name = os.environ.get("IMMICH_ADMIN_NAME", "Administrator")
    key_out = os.environ.get("IMMICH_API_KEY_FILE")
    password = read_credential("admin_password")

    if not password:
        print("immich-provision: admin secret is empty, refusing", file=sys.stderr)
        return 1

    cfg = call(base, "/api/server/config")
    if cfg is None:
        print("immich-provision: no server config returned", file=sys.stderr)
        return 1

    if cfg.get("isInitialized"):
        print("immich-provision: already initialised, leaving the account alone")
    else:
        call(
            base,
            "/api/auth/admin-sign-up",
            {"email": email, "password": password, "name": name},
        )
        print(f"immich-provision: created the admin account for {email}")

    # An API key for the CLI importer. Minted only when we have nowhere to read one
    # from, so re-runs do not pile up keys in the account.
    if key_out and not os.path.exists(key_out):
        session = call(base, "/api/auth/login", {"email": email, "password": password})
        token = session.get("accessToken") if session else None
        if not token:
            print("immich-provision: login returned no token", file=sys.stderr)
            return 1
        made = call(
            base,
            "/api/api-keys",
            {"name": "declarative-cli", "permissions": ["all"]},
            token=token,
        )
        secret = (made or {}).get("secret")
        if not secret:
            print("immich-provision: no api key returned", file=sys.stderr)
            return 1
        os.makedirs(os.path.dirname(key_out), exist_ok=True)
        fd = os.open(key_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(secret + "\n")
        print(f"immich-provision: wrote a CLI api key to {key_out}")
    elif key_out:
        print("immich-provision: api key already present, not minting another")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:200]
        print(
            f"immich-provision: HTTP {exc.code} from {exc.url} — {detail}",
            file=sys.stderr,
        )
        sys.exit(1)
    except (urllib.error.URLError, OSError) as exc:
        print(f"immich-provision: {exc}", file=sys.stderr)
        sys.exit(1)
