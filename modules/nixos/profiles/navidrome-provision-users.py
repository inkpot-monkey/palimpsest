#!/usr/bin/env python3
"""Idempotently ensure Navidrome accounts exist for every user in the sops `users` map.

Navidrome has no declarative user provisioning, and its Subsonic `createUser` endpoint
returns 501 (Not Implemented) — the only path is its *native* REST API (the web-UI backend:
`POST /auth/login` for a JWT, then `POST /api/user`). This codifies what would otherwise be
manual admin-UI clicking, the same way ha-provision-voice.py codifies HA's config-flow wiring.

Reads (paths via env, populated from systemd LoadCredential so secrets never hit argv/environ):
  ND_ADMIN_PASSWORD_FILE  the `admin` account password (to log into the native API)
  ND_USERS_FILE           the decrypted sops `users` map — JSON object or YAML `name: password`
  ND_URL                  base URL of the local Navidrome (e.g. http://127.0.0.1:4533)

Create-only by design: existing users are left untouched, so a password later changed in the
UI is never clobbered. Fail-loud (non-zero exit) so a broken run shows up as a failed unit.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ["ND_URL"].rstrip("/")
ADMIN_USER = os.environ.get("ND_ADMIN_USER", "admin")


def read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def api(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("x-nd-authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def parse_users(raw):
    """The map may arrive as JSON ({"name": "pw"}) or as sops' YAML extract (name: pw lines)."""
    try:
        return dict(json.loads(raw))
    except (json.JSONDecodeError, ValueError):
        pass
    users = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, sep, pw = line.partition(":")
        if sep:
            users[name.strip()] = pw.strip()
    return users


def wait_for_login(admin_pw):
    """Poll the native API until it accepts the admin login (Navidrome takes a moment on boot)."""
    last = None
    for _ in range(90):
        try:
            return api(
                "POST",
                "/auth/login",
                body={"username": ADMIN_USER, "password": admin_pw},
            )["token"]
        except (
            urllib.error.HTTPError
        ) as exc:  # server up but rejected us — a real error
            raise SystemExit(
                f"admin login failed: HTTP {exc.code} {exc.read().decode()[:200]}"
            )
        except urllib.error.URLError as exc:  # not listening yet — keep waiting
            last = exc
            time.sleep(2)
    raise SystemExit(f"Navidrome API never came up at {BASE}: {last}")


def main():
    users = parse_users(read_file(os.environ["ND_USERS_FILE"]))
    if not users:
        print("no users in the map; nothing to provision")
        return

    token = wait_for_login(read_file(os.environ["ND_ADMIN_PASSWORD_FILE"]))
    existing = {u["userName"] for u in api("GET", "/api/user", token=token)}

    created = 0
    for name, password in users.items():
        if name in existing:
            print(f"user {name!r} already exists — leaving untouched")
            continue
        api(
            "POST",
            "/api/user",
            token=token,
            body={
                "userName": name,
                "name": name,
                "password": password,
                "isAdmin": False,
            },
        )
        print(f"created user {name!r}")
        created += 1
    print(f"done: {created} user(s) created, {len(users) - created} already present")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as exc:  # any unexpected API error → fail the unit
        sys.exit(f"FAIL: HTTP {exc.code} {exc.read().decode()[:200]}")
