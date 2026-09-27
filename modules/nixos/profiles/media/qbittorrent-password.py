"""Seed qBittorrent's WebUI credentials from sops, idempotently.

qBittorrent has no way to take a WebUI password from a file or an environment
variable: it stores only a PBKDF2 hash, and the container mints a RANDOM one on
first run and prints it to its log. That left the password as the one hand step in
an otherwise declarative stack -- and until somebody did it, the preferences and
port-forward reconcilers could not authenticate, so both failed on every timer.

So compute the hash ourselves. The format is qBittorrent's own (see
src/base/utils/password.cpp): PBKDF2-HMAC-SHA512, 100000 iterations, a 16-byte
salt and a 64-byte derived key, stored as

    WebUI\\Password_PBKDF2="@ByteArray(<base64 salt>:<base64 key>)"

Idempotent on purpose: if the stored hash already verifies against the desired
password we exit without touching the file. A fresh salt every boot would rewrite
the config on each start and make any real drift impossible to spot.

Must run while the container is STOPPED -- qBittorrent rewrites this file when it
exits, so a write underneath a running instance is simply lost.
"""

import base64
import hashlib
import os
import sys

ITERATIONS = 100000
SALT_BYTES = 16
KEY_BYTES = 64
KEY = "WebUI\\Password_PBKDF2"
USER_KEY = "WebUI\\Username"


def derive(password: bytes, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha512", password, salt, ITERATIONS, KEY_BYTES)


def parse_stored(value: str):
    """Pull (salt, key) out of '@ByteArray(<b64>:<b64>)', or None if unparseable."""
    v = value.strip().strip('"')
    if not v.startswith("@ByteArray(") or not v.endswith(")"):
        return None
    inner = v[len("@ByteArray(") : -1]
    if ":" not in inner:
        return None
    s, k = inner.split(":", 1)
    try:
        return base64.b64decode(s), base64.b64decode(k)
    except (ValueError, TypeError):
        # Corrupt or hand-edited value — treat as absent and rewrite it.
        return None


def main() -> int:
    conf_path, secret_path, username = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(secret_path, "rb") as fh:
        password = fh.read().strip()
    if not password:
        print("qbittorrent-password: secret is empty, refusing to set a blank password")
        return 1

    lines = []
    if os.path.exists(conf_path):
        with open(conf_path, "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()

    # Already correct? Then leave the file alone.
    for line in lines:
        if line.startswith(KEY + "="):
            parsed = parse_stored(line.split("=", 1)[1])
            if parsed and derive(password, parsed[0]) == parsed[1]:
                print("qbittorrent-password: stored hash already matches, no change")
                return 0
            break

    salt = os.urandom(SALT_BYTES)
    encoded = f"{base64.b64encode(salt).decode()}:{base64.b64encode(derive(password, salt)).decode()}"
    new = {KEY: '"@ByteArray(' + encoded + ')"', USER_KEY: username}

    out, seen, in_prefs, prefs_seen = [], set(), False, False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            # Leaving [Preferences]: flush anything that section was missing.
            if in_prefs:
                for k, v in new.items():
                    if k not in seen:
                        out.append(k + "=" + v)
                in_prefs = False
            if stripped == "[Preferences]":
                in_prefs, prefs_seen = True, True
            out.append(line)
            continue
        key = line.split("=", 1)[0] if "=" in line else None
        if in_prefs and key in new:
            out.append(key + "=" + new[key])
            seen.add(key)
        else:
            out.append(line)

    if in_prefs:
        for k, v in new.items():
            if k not in seen:
                out.append(k + "=" + v)
    elif not prefs_seen:
        out.append("[Preferences]")
        for k, v in new.items():
            out.append(k + "=" + v)

    os.makedirs(os.path.dirname(conf_path), exist_ok=True)
    tmp = conf_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    os.replace(tmp, conf_path)
    print("qbittorrent-password: wrote a new WebUI credential hash")
    return 0


if __name__ == "__main__":
    sys.exit(main())
