"""Complete Jellyfin's startup wizard and declare its libraries, idempotently.

Jellyfin ships no declarative path for either: a fresh server sits at
`StartupWizardCompleted: false` and serves nothing until somebody clicks through
the wizard, and libraries are UI state thereafter. Moving the media stack to rk1b
produced exactly that — a running Jellyfin with 15G of media beside it and no way
to see any of it.

So drive Jellyfin's own API, as ha-provision-voice.py does for Home Assistant:

    GET  /System/Info/Public        -> StartupWizardCompleted
    POST /Startup/Configuration     -> locale
    POST /Startup/User              -> the admin account
    POST /Startup/RemoteAccess      -> remote access + UPnP off
    POST /Startup/Complete          -> finish the wizard
    POST /Users/AuthenticateByName  -> session token
    GET/POST /Library/VirtualFolders-> declare the libraries

Idempotent in both halves: a completed wizard is skipped, and a library whose name
already exists is left alone, so this is safe on every boot. Fail-loud: a non-zero
exit leaves the unit failed rather than a server that quietly shows nothing.

The password reaches us through systemd's LoadCredential, never argv or a shared
environment.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30
# Jellyfin rejects requests without this; the values are cosmetic but the header
# must parse.
AUTH_HEADER = (
    'MediaBrowser Client="nixos-provision", Device="provisioner", '
    'DeviceId="nixos-provision", Version="1.0.0"'
)


def call(base, path, payload=None, token=None, method=None):
    url = base.rstrip("/") + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method=method or ("POST" if data else "GET")
    )
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    auth = AUTH_HEADER
    if token:
        auth += f', Token="{token}"'
    req.add_header("Authorization", auth)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        body = resp.read().decode()
    return json.loads(body) if body.strip() else None


def read_credential(name: str) -> str:
    d = os.environ.get("CREDENTIALS_DIRECTORY")
    if not d:
        print("jellyfin-provision: CREDENTIALS_DIRECTORY unset", file=sys.stderr)
        raise SystemExit(1)
    with open(os.path.join(d, name), encoding="utf-8") as fh:
        return fh.read().replace("\n", "")


def main() -> int:
    base = os.environ["JELLYFIN_URL"]
    user = os.environ["JELLYFIN_ADMIN_USER"]
    libraries = json.loads(os.environ.get("JELLYFIN_LIBRARIES", "[]"))
    password = read_credential("admin_password")

    if not password:
        print("jellyfin-provision: admin secret is empty, refusing", file=sys.stderr)
        return 1

    info = call(base, "/System/Info/Public")
    if info is None:
        print("jellyfin-provision: no public info returned", file=sys.stderr)
        return 1

    # A mid-start Jellyfin answers /System/Info/Public with 200 while still 503-ing the
    # startup endpoints, and it reported StartupWizardCompleted=false on a server that
    # had been provisioned days earlier -- so this ran the wizard again and only failed
    # safely because the POST 503'd. Acting on that reading is the hazard: a moment
    # later and it would have re-run the wizard against a live server.
    #
    # So a `false` here is not believed on sight. Re-read after a pause and require two
    # consecutive agreeing answers; a genuinely fresh server keeps saying false, while a
    # starting one flips to true and is left alone. A disagreement means "still coming
    # up" -- exit non-zero and let the unit's retry handle it, rather than guessing.
    if not info.get("StartupWizardCompleted"):
        time.sleep(15)
        second = call(base, "/System/Info/Public")
        if second is None or second.get("StartupWizardCompleted"):
            print(
                "jellyfin-provision: server still starting (wizard state changed between "
                "reads) — retrying later rather than acting on it",
                file=sys.stderr,
            )
            return 1
        info = second

    if info.get("StartupWizardCompleted"):
        print("jellyfin-provision: wizard already completed, leaving it alone")
    else:
        call(
            base,
            "/Startup/Configuration",
            {
                "UICulture": os.environ.get("JELLYFIN_UI_CULTURE", "en-GB"),
                "MetadataCountryCode": os.environ.get("JELLYFIN_COUNTRY", "GB"),
                "PreferredMetadataLanguage": os.environ.get("JELLYFIN_LANGUAGE", "en"),
            },
        )
        # Jellyfin wants the wizard's user read before it is written.
        call(base, "/Startup/User")
        call(base, "/Startup/User", {"Name": user, "Password": password})
        # No remote access and no UPnP: kelpy's Caddy fronts this over the tailnet,
        # so the server must never punch its own hole in the router.
        call(
            base,
            "/Startup/RemoteAccess",
            {"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False},
        )
        call(base, "/Startup/Complete", {})
        print(f"jellyfin-provision: completed the wizard as {user}")

    if not libraries:
        return 0

    session = call(
        base, "/Users/AuthenticateByName", {"Username": user, "Pw": password}
    )
    token = (session or {}).get("AccessToken")
    if not token:
        print("jellyfin-provision: authentication returned no token", file=sys.stderr)
        return 1

    existing = {
        f.get("Name")
        for f in (call(base, "/Library/VirtualFolders", token=token) or [])
    }

    for lib in libraries:
        if lib["name"] in existing:
            print(f"jellyfin-provision: library {lib['name']!r} already present")
            continue
        query = urllib.parse.urlencode(
            {
                "name": lib["name"],
                "collectionType": lib["type"],
                "paths": lib["path"],
                "refreshLibrary": "true",
            }
        )
        call(base, f"/Library/VirtualFolders?{query}", {}, token=token)
        print(f"jellyfin-provision: added library {lib['name']!r} -> {lib['path']}")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:200]
        print(
            f"jellyfin-provision: HTTP {exc.code} from {exc.url} — {detail}",
            file=sys.stderr,
        )
        sys.exit(1)
    except (urllib.error.URLError, OSError) as exc:
        print(f"jellyfin-provision: {exc}", file=sys.stderr)
        sys.exit(1)
