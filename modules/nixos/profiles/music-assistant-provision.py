#!/usr/bin/env python3
"""Fully declarative provisioning for Music Assistant + its Navidrome service account.

Three idempotent, create-only, fail-loud jobs (see ADR-0031). Pure stdlib (urllib) — MA's
schema-31 auth is handled entirely over its HTTP endpoints, so we need neither the
music-assistant-client library (which refuses to connect without a token) nor async.

1. Navidrome service account — create the dedicated `music-assistant` Navidrome account via
   Navidrome's native admin API (kept out of the friend `users` map on purpose).

2. Music Assistant admin + token — MA (schema >= 28) requires a JWT on every API call. Bootstrap
   it declaratively: `POST /setup` creates the first admin user (only works when none exist) and
   returns a token; on later runs that returns 400 "already completed", so fall back to
   `POST /auth/login`. Credentials come from sops, so this is reproducible from scratch. (Verified
   against the MA 2.9.6 source: controllers/webserver/controller.py `_handle_setup` /
   `_handle_auth_login`, and `_handle_jsonrpc_api_command` for the `/api` calls below.)

3. MA providers — with the token, `POST /api` (JSON-RPC, admin role) to ensure these exist:
     * opensubsonic — reads the Navidrome library as the `music-assistant` account.
     * snapcast     — external-server mode pointed at porcupineFish's snapserver.
     * party        — guest access (QR → add to the shared queue), bound to the auto player.

Config from the environment (non-secret) + credential files (passwords via systemd
LoadCredential, never argv/environ):
  ND_URL / ND_ADMIN_USER / ND_ADMIN_PASSWORD_FILE   Navidrome, to create the service account
  MA_SUBSONIC_USER / MA_SUBSONIC_PASSWORD_FILE       the `music-assistant` Navidrome account
  MA_URL                                             base URL of the local MA (http://127.0.0.1:8095)
  MA_ADMIN_USER / MA_ADMIN_PASSWORD_FILE             MA's own admin account (its own credential,
                                                     NOT a Navidrome user — MA has no external auth)
  MA_SUBSONIC_BASEURL / MA_SUBSONIC_PORT             Navidrome endpoint for MA's opensubsonic provider
  MA_SNAPCAST_HOST / MA_SNAPCAST_CONTROL_PORT        porcupineFish's snapserver control endpoint
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request


def env(name, default=None):
    val = os.environ.get(name, default)
    if not val:
        sys.exit(f"music-assistant-provision: missing required env {name}")
    return val


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def http(base, method, path, token=None, body=None, nd_token=None):
    """POST/GET JSON; return parsed body (or None). Raises urllib HTTPError on non-2xx."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:  # Music Assistant JWT
        req.add_header("Authorization", f"Bearer {token}")
    if nd_token:  # Navidrome native-API JWT
        req.add_header("x-nd-authorization", f"Bearer {nd_token}")
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


# --- 1. Navidrome service account (native admin API, mirrors navidrome-provision-users.py) ---


def ensure_navidrome_account():
    base = env("ND_URL").rstrip("/")
    admin_user = env("ND_ADMIN_USER", "admin")
    admin_pw = read_file(env("ND_ADMIN_PASSWORD_FILE"))
    username = env("MA_SUBSONIC_USER")
    password = read_file(env("MA_SUBSONIC_PASSWORD_FILE"))

    token = None
    last = None
    for _ in range(90):  # Navidrome takes a moment to accept logins on boot
        try:
            token = http(
                base,
                "POST",
                "/auth/login",
                body={"username": admin_user, "password": admin_pw},
            )["token"]
            break
        except urllib.error.HTTPError as exc:  # up but rejected us — a real error
            sys.exit(
                f"navidrome admin login failed: HTTP {exc.code} {exc.read().decode()[:200]}"
            )
        except urllib.error.URLError as exc:  # not listening yet — keep waiting
            last = exc
            time.sleep(2)
    if token is None:
        sys.exit(f"navidrome API never came up at {base}: {last}")

    existing = {u["userName"] for u in http(base, "GET", "/api/user", nd_token=token)}
    if username in existing:
        print(
            f"music-assistant-provision: navidrome account {username!r} already exists"
        )
        return
    http(
        base,
        "POST",
        "/api/user",
        nd_token=token,
        body={
            "userName": username,
            "name": username,
            "password": password,
            "isAdmin": False,
        },
    )
    print(f"music-assistant-provision: created navidrome account {username!r}")


# --- 2 + 3. Music Assistant admin bootstrap + provider config (all over MA's HTTP endpoints) ---


def ma_get_token(base, username, password):
    """Create the first admin via /setup, or log in if it already exists. Returns a JWT."""
    try:
        resp = http(
            base, "POST", "/setup", body={"username": username, "password": password}
        )
        if resp and resp.get("success"):
            print(
                f"music-assistant-provision: created MA admin {username!r} via /setup"
            )
            return resp["token"]
    except urllib.error.HTTPError as exc:
        if exc.code != 400:  # 400 == "Setup already completed" → fall through to login
            sys.exit(f"MA /setup failed: HTTP {exc.code} {exc.read().decode()[:200]}")

    resp = http(
        base,
        "POST",
        "/auth/login",
        body={
            "provider_id": "builtin",
            "credentials": {"username": username, "password": password},
        },
    )
    if not resp or not resp.get("success"):
        sys.exit(f"MA login failed for {username!r}: {resp}")
    return resp["token"]


def ma_command(base, token, command, args):
    """Run a JSON-RPC command via POST /api with the admin token."""
    return http(
        base,
        "POST",
        "/api",
        token=token,
        body={"command": command, "message_id": "prov", "args": args},
    )


def ensure_ma_provider(base, token, domain, values):
    existing = ma_command(base, token, "config/providers", {"provider_domain": domain})
    if existing:
        print(f"music-assistant-provision: MA {domain} provider already configured")
        return
    ma_command(
        base,
        token,
        "config/providers/save",
        {"provider_domain": domain, "values": values},
    )
    print(f"music-assistant-provision: created MA {domain} provider")


def configure_ma():
    base = env("MA_URL").rstrip("/")
    username = env("MA_ADMIN_USER")
    password = read_file(env("MA_ADMIN_PASSWORD_FILE"))

    # MA may still be opening its webserver when this oneshot fires; retry token acquisition.
    token = None
    last = None
    for _ in range(60):
        try:
            token = ma_get_token(base, username, password)
            break
        except urllib.error.URLError as exc:  # not listening yet
            last = exc
            time.sleep(2)
    if token is None:
        sys.exit(f"MA API never came up at {base}: {last}")

    ensure_ma_provider(
        base,
        token,
        "opensubsonic",
        {
            "baseURL": env("MA_SUBSONIC_BASEURL"),
            "port": int(env("MA_SUBSONIC_PORT")),
            "path": "",
            "username": env("MA_SUBSONIC_USER"),
            "password": read_file(env("MA_SUBSONIC_PASSWORD_FILE")),
        },
    )
    ensure_ma_provider(
        base,
        token,
        "snapcast",
        {
            "snapcast_use_external_server": True,
            "snapcast_server_host": env("MA_SNAPCAST_HOST"),
            "snapcast_server_control_port": int(env("MA_SNAPCAST_CONTROL_PORT")),
        },
    )
    # Party plugin: guest QR access to the shared queue, bound to the auto (last-active) player.
    ensure_ma_provider(
        base, token, "party", {"enable_guest_access": True, "player": "__auto__"}
    )


def main():
    ensure_navidrome_account()
    configure_ma()


if __name__ == "__main__":
    main()
