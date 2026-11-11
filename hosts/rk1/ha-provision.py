#!/usr/bin/env python3
"""Codify the Home Assistant state that has no declarative path, on rk1a.

Home Assistant keeps config entries, Assist pipelines and (since 2026.9) its own
HTTP settings in mutable `.storage`, with no way to declare them in nix. Rather
than seed that private state (version-fragile), this script drives HA's
*supported* APIs — the exact calls the UI buttons make underneath — so each
action is documented in code, re-runnable, and fails loudly if anything is wrong.

It is idempotent throughout: everything already in the desired state is left
alone, so it is safe to re-run (e.g. as a post-deploy check). That matters most
for the HTTP section, where applying a config restarts HA — a non-idempotent
check there would restart Home Assistant on every boot.

What it provisions (all of it mirrors modules/nixos/profiles/homeassistant.nix):
  - HTTP: server_port / use_x_forwarded_for / trusted_proxies. HA 2026.9 migrated
    `http` out of configuration.yaml and now *ignores* that block, so without this
    the module's declared trusted proxies would silently stop taking effect and
    the edge host's reverse proxy would break on the next address change.
  - Wyoming STT  -> tcp://127.0.0.1:10300 (wyoming-faster-whisper)
  - Wyoming TTS  -> tcp://127.0.0.1:10200 (wyoming-piper, en_US-lessac-medium)
  - The preferred Assist pipeline's stt_engine / tts_engine / tts_voice.
  - tuya_local bulbs from HA_BULBS, each placed in its Area so Assist can address
    it by room. Local keys come from the systemd credentials directory.

Auth (pick one):
  - HA_TOKEN=<long-lived access token>            (preferred; revocable)
  - HA_OWNER_USERNAME + HA_OWNER_PASSWORD          (logs in each run)
  - HA_OWNER_NAME + HA_OWNER_USERNAME + HA_OWNER_PASSWORD, on a *fresh* HA,
    completes onboarding first (creates the owner account).

Config via env:
  - HA_URL       (default http://127.0.0.1:8123)
  - HA_HTTP_CONFIG  JSON object of declared HTTP settings; skipped when unset
  - HA_BULBS        JSON list of tuya_local bulbs; skipped when unset. Each entry:
                    {slug, title, device_id, host, type, protocol_version,
                     poll_only, area}. The local key is read from
                    $CREDENTIALS_DIRECTORY/local_key_<slug>.

Run on rk1a against loopback, or remotely against https://home.<domain> with a
token.

Exit non-zero on any failure. Stdlib only (no third-party deps on the node).
"""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import os
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, NoReturn

# Wyoming loopback endpoints + piper voice — fixed by the homeassistant profile.
STT_PORT = 10300
TTS_PORT = 10200
TTS_VOICE = "en_GB-northern_english_male-medium"
# The two engines do NOT agree on how a language is spelled, so they get their own
# constants. piper advertises only region-qualified codes (en_GB, en_US, ...) and
# rejects a bare "en" with `tts-not-supported`, which surfaces in the companion app
# as nothing more useful than "Oops, an error has occurred". faster-whisper is the
# other way round: it advertises bare "en" and no en_US. assert_engine_language()
# checks both against what the engines actually report, so a mismatch fails the unit
# instead of the user's Assist. Keep TTS_LANG consistent with TTS_VOICE's locale.
STT_LANG = "en"
TTS_LANG = "en_GB"

BASE = os.environ.get("HA_URL", "http://127.0.0.1:8123").rstrip("/")
CLIENT_ID = BASE + "/"


def die(msg: str) -> NoReturn:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg: str) -> None:
    print(msg, flush=True)


# --------------------------------------------------------------------------- #
# REST helpers                                                                #
# --------------------------------------------------------------------------- #
def rest(method, path, data=None, token=None, form=False, allow=(200,)) -> Any:
    url = BASE + path
    headers = {}
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read().decode()
            status, payload = resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        status, payload = e.code, e.read().decode()
    if status not in allow:
        die(f"{method} {path} -> HTTP {status}: {payload}")
    return payload


# --------------------------------------------------------------------------- #
# Auth: onboarding / login -> access token                                    #
# --------------------------------------------------------------------------- #
def token_from_auth_code(code: str) -> str:
    tok = rest(
        "POST",
        "/auth/token",
        {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": CLIENT_ID,
        },
        form=True,
    )
    return tok["access_token"]


def onboard(name, username, password) -> str:
    resp = rest(
        "POST",
        "/api/onboarding/users",
        {
            "client_id": CLIENT_ID,
            "name": name,
            "username": username,
            "password": password,
            "language": "en",
        },
    )
    token = token_from_auth_code(resp["auth_code"])
    for step in ("core_config", "analytics"):
        rest("POST", f"/api/onboarding/{step}", {}, token=token, allow=(200,))
    log(f"[auth] onboarded owner {username!r}")
    return token


def login(username, password) -> str:
    flow = rest(
        "POST",
        "/auth/login_flow",
        {
            "client_id": CLIENT_ID,
            "handler": ["homeassistant", None],
            "redirect_uri": CLIENT_ID,
        },
    )
    result = rest(
        "POST",
        f"/auth/login_flow/{flow['flow_id']}",
        {
            "client_id": CLIENT_ID,
            "username": username,
            "password": password,
        },
    )
    if result.get("type") != "create_entry":
        die(f"login did not succeed: {result}")
    log(f"[auth] logged in as {username!r}")
    return token_from_auth_code(result["result"])


def get_token() -> str:
    if os.environ.get("HA_TOKEN"):
        log("[auth] using HA_TOKEN")
        return os.environ["HA_TOKEN"]
    user = os.environ.get("HA_OWNER_USERNAME")
    pw = os.environ.get("HA_OWNER_PASSWORD")
    if not (user and pw):
        die("no auth: set HA_TOKEN, or HA_OWNER_USERNAME + HA_OWNER_PASSWORD")
    # HA serves /api/onboarding only while onboarding is still possible and drops it
    # once complete — 2026.10 answers 404 on a long-onboarded instance. So a missing
    # endpoint is not a failure, it is the answer: there is nothing to onboard, log in.
    steps = rest("GET", "/api/onboarding", allow=(200, 404))
    user_done = not isinstance(steps, list) or any(
        s["step"] == "user" and s["done"] for s in steps
    )
    if not user_done:
        name = os.environ.get("HA_OWNER_NAME", user)
        return onboard(name, user, pw)
    return login(user, pw)


# --------------------------------------------------------------------------- #
# Minimal RFC 6455 WebSocket client (text frames only) for the HA WS API      #
# --------------------------------------------------------------------------- #
class WS:
    def __init__(self, url: str, token: str):
        u = urllib.parse.urlparse(url)
        secure = u.scheme in ("https", "wss")
        host = u.hostname
        port = u.port or (443 if secure else 80)
        path = "/api/websocket"
        sock = socket.create_connection((host, port), timeout=30)
        if secure:
            ctx = ssl.create_default_context()
            sock = ctx.wrap_socket(sock, server_hostname=host)
        self.sock = sock
        key = base64.b64encode(os.urandom(16)).decode()
        handshake = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        sock.sendall(handshake.encode())
        resp = self._read_http_headers()
        accept = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()
        ).decode()
        if f"sec-websocket-accept: {accept}".lower() not in resp.lower():
            die(f"WebSocket handshake failed: {resp[:200]}")
        self._buf = b""
        self._id = 0
        # HA auth handshake.
        first = self.recv()
        if first.get("type") != "auth_required":
            die(f"unexpected first WS message: {first}")
        self._send_raw({"type": "auth", "access_token": token})
        res = self.recv()
        if res.get("type") != "auth_ok":
            die(f"WS auth failed: {res}")

    def _read_http_headers(self) -> str:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                die("WS closed during handshake")
            data += chunk
        return data.decode("latin-1")

    def _send_raw(self, obj: dict[str, Any]) -> None:
        payload = json.dumps(obj).encode()
        header = bytearray([0x81])  # FIN + text opcode
        n = len(payload)
        mask_bit = 0x80
        if n < 126:
            header.append(mask_bit | n)
        elif n < 65536:
            header.append(mask_bit | 126)
            header += struct.pack(">H", n)
        else:
            header.append(mask_bit | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv(self) -> dict[str, Any]:
        while True:
            frame, self._buf = self._read_frame(self._buf)
            if frame is not None:
                return json.loads(frame.decode())

    def _read_frame(self, buf: bytes):
        while len(buf) < 2:
            buf += self._recv_some()
        b0, b1 = buf[0], buf[1]
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        idx = 2
        if length == 126:
            while len(buf) < 4:
                buf += self._recv_some()
            length = struct.unpack(">H", buf[2:4])[0]
            idx = 4
        elif length == 127:
            while len(buf) < 10:
                buf += self._recv_some()
            length = struct.unpack(">Q", buf[2:10])[0]
            idx = 10
        while len(buf) < idx + length:
            buf += self._recv_some()
        payload = buf[idx : idx + length]
        buf = buf[idx + length :]
        if opcode == 0x8:  # close
            die("WS closed by server")
        if opcode in (0x9, 0xA):  # ping/pong — ignore, keep reading
            return None, buf
        return payload, buf

    def _recv_some(self) -> bytes:
        chunk = self.sock.recv(65536)
        if not chunk:
            die("WS connection closed unexpectedly")
        return chunk

    def try_cmd(self, msg: dict[str, Any]) -> dict[str, Any]:
        """Send a command and return its raw `result` message without dying on
        failure — the caller inspects `success`/`error`. Use for commands that
        may legitimately fail while HA is still warming up (see wait_for_ws_api)."""
        self._id += 1
        msg = {**msg, "id": self._id}
        self._send_raw(msg)
        while True:
            res = self.recv()
            if res.get("id") == self._id and res.get("type") == "result":
                return res

    def cmd(self, msg: dict[str, Any]) -> Any:
        res = self.try_cmd(msg)
        if not res.get("success", False):
            die(f"WS command {msg['type']} failed: {res.get('error')}")
        return res["result"]

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# Readiness                                                                   #
# --------------------------------------------------------------------------- #
def wait_for_ws_api(ws, attempts=45, delay=2) -> None:
    """Block until the assist_pipeline WS API is registered.

    Our shell wrapper's readiness gate polls `manifest.json` for HTTP 200, but
    the HTTP server comes up *before* the assist_pipeline integration finishes
    async_setup and registers its WS commands. On a slow/contended boot that
    gap can outlast the gate, so `assist_pipeline/pipeline/list` returns
    `unknown_command` and provisioning dies. Poll it here — treating
    `unknown_command` as "still loading" — so we wait for the real precondition
    rather than the HTTP-server proxy. Fail loud on any other error or timeout.
    """
    for _ in range(attempts):
        res = ws.try_cmd({"type": "assist_pipeline/pipeline/list"})
        if res.get("success", False):
            return
        err = res.get("error") or {}
        if err.get("code") != "unknown_command":
            die(f"WS command assist_pipeline/pipeline/list failed: {err}")
        time.sleep(delay)
    die(
        f"assist_pipeline WS API not ready after {attempts * delay}s "
        "(pipeline/list kept returning unknown_command)"
    )


# --------------------------------------------------------------------------- #
# HTTP configuration                                                          #
# --------------------------------------------------------------------------- #
# HA 2026.9 moved `http` out of configuration.yaml into its own store and now
# ignores the YAML block (`yaml_migration_done`), so the homeassistant profile
# declares these values here instead and this section pushes them in.
HTTP_META = ("created_at", "error", "error_message")


def _normalise_http(cfg: dict[str, Any]) -> dict[str, Any]:
    """Put a config into the shape HA stores, so comparison cannot false-positive.

    HA runs every trusted proxy through `str(ip_network(...))`, so a declared
    `100.81.190.9` comes back as `100.81.190.9/32`. Compare normalised and
    order-independent, or we would "differ" on every run — and since applying a
    config restarts Home Assistant, that would mean a restart on every boot.
    Store metadata (created_at / error) is dropped: it is not ours to compare.
    """
    out = {k: v for k, v in cfg.items() if k not in HTTP_META}
    if "trusted_proxies" in out:
        out["trusted_proxies"] = sorted(
            str(ipaddress.ip_network(p)) for p in out["trusted_proxies"]
        )
    return out


def _http_declared_matches(have: dict[str, Any] | None, want: dict[str, Any]) -> bool:
    """True when every value we declare is already the stored value.

    Only the declared subset is compared. Keys we do not manage (ssl_profile,
    cors_allowed_origins, ...) belong to whoever set them, and HA fills them from
    schema defaults regardless — claiming them here would mean reverting a
    deliberate UI change on every boot.
    """
    if not have:
        return False
    have_n = _normalise_http(have)
    return all(have_n.get(k) == v for k, v in _normalise_http(want).items())


def _api_up() -> bool:
    # OSError covers the lot while HA is down or still starting: connection
    # refused, timeouts, and urllib's URLError/HTTPError, which subclass it.
    try:
        req = urllib.request.Request(BASE + "/manifest.json")
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except OSError:
        return False


def wait_for_rest_api(attempts=90, delay=2) -> None:
    """Block until HA answers HTTP again, after a restart we triggered."""
    for _ in range(attempts):
        if _api_up():
            return
        time.sleep(delay)
    die(f"Home Assistant HTTP API did not come back after {attempts * delay}s")


def _verify_http(ws: WS, want: dict[str, Any]) -> None:
    cur = ws.cmd({"type": "http/config"})
    if not _http_declared_matches(cur.get("stable"), want):
        die(
            "HTTP config did not stick: "
            f"stable={_normalise_http(cur.get('stable') or {})} "
            f"want={_normalise_http(want)}"
        )
    log("[verify] HTTP stable config confirmed")


def ensure_http(ws: WS, token: str, want: dict[str, Any]) -> tuple[WS, str]:
    """Idempotently make HA's stored HTTP config match the declared values.

    Mirrors what Settings > System > Network does. Two HA behaviours shape the
    order of operations: applying a config *restarts* Home Assistant, and a
    pending config that is never promoted *auto-reverts* to stable. So the
    sequence is configure -> wait for HA to return -> promote, all in one run;
    deferring the promote to a later run would race the revert.

    Returns the websocket and token to keep using — both are replaced when a
    restart happens.
    """
    cur = ws.cmd({"type": "http/config"})
    if _http_declared_matches(cur.get("stable"), want):
        log("[http] stable config already matches the declared values")
        return ws, token

    pending = cur.get("pending") or {}
    if pending and _http_declared_matches(pending, want) and not pending.get("error"):
        ws.cmd({"type": "http/config/promote"})
        log("[http] promoted the already-matching pending config to stable")
        _verify_http(ws, want)
        return ws, token

    # A pending config that failed its trial is kept with the failure recorded and
    # is never applied again. Re-pushing it blind would just fail the same way.
    err = pending.get("error")
    if err and err != "not_promoted":
        die(
            f"a pending HTTP config failed its trial ({err}: "
            f"{pending.get('error_message')}); fix it in the UI before re-running"
        )

    log(f"[http] applying declared config {_normalise_http(want)}")
    result = None
    for _ in range(10):
        res = ws.try_cmd({"type": "http/config/configure", "config": want})
        if res.get("success"):
            result = res["result"]
            break
        # HA refuses the change until it has finished starting.
        if (res.get("error") or {}).get("code") != "not_running":
            die(f"http/config/configure failed: {res.get('error')}")
        time.sleep(3)
    if result is None:
        die("http/config/configure kept reporting Home Assistant as not running")

    if not result.get("restart"):
        _verify_http(ws, want)
        return ws, token

    log("[http] stored as pending; Home Assistant is restarting to apply it")
    ws.close()
    time.sleep(5)
    wait_for_rest_api()
    token = get_token()
    ws = WS(BASE, token)
    wait_for_ws_api(ws)
    ws.cmd({"type": "http/config/promote"})
    log("[http] promoted to stable after the restart")
    _verify_http(ws, want)
    return ws, token


# --------------------------------------------------------------------------- #
# tuya_local bulbs                                                            #
# --------------------------------------------------------------------------- #
def bulb_local_key(slug: str) -> str:
    """A bulb's Tuya local key, from the per-service systemd credentials dir."""
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    if not creds:
        die("CREDENTIALS_DIRECTORY is unset, so bulb local keys cannot be read")
    path = os.path.join(creds, f"local_key_{slug}")
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as e:
        die(f"cannot read the local key for bulb {slug!r} at {path}: {e}")


def tuya_devices(ws: WS) -> dict[str, dict[str, Any]]:
    """Tuya device id -> that bulb's device-registry entry.

    Keyed on the registry identifier, which tuya_local sets to the Tuya device id.
    Not on the config entry's unique_id: neither the REST nor the websocket entry
    listing exposes it. Not on the title either, which anyone can rename in the UI
    — and a key that a rename invalidates would have us adopt the bulb twice.
    """
    found: dict[str, dict[str, Any]] = {}
    for dev in ws.cmd({"type": "config/device_registry/list"}):
        for ident in dev.get("identifiers") or []:
            if len(ident) == 2 and ident[0] == "tuya_local":
                found[ident[1]] = dev
    return found


def _select_options(step: dict[str, Any], field: str) -> list[Any]:
    """A select field's options, out of a flow step's serialised schema."""
    for spec in step.get("data_schema") or []:
        if spec.get("name") == field:
            return ((spec.get("selector") or {}).get("select") or {}).get(
                "options"
            ) or []
    return []


def _type_key_for(step: dict[str, Any], config_type: str) -> str:
    """tuya_local's device-type option for a config type.

    The select's values are compound — `config_type||manufacturer||model` — and
    which manufacturer/model a config advertises depends on the device's product
    ids, so the key is matched on its first field rather than reconstructed.
    """
    values = [
        o["value"] if isinstance(o, dict) else o for o in _select_options(step, "type")
    ]
    for value in values:
        if value.split("||", 1)[0] == config_type:
            return value
    die(f"tuya_local offered no device type {config_type!r}; it offered: {values}")


def create_bulb(token, bulb: dict[str, Any]) -> bool:
    """Drive tuya_local's manual config flow: user -> local -> type -> name.

    The `local` step connects to the bulb to confirm the key and protocol, so a
    bulb that is unplugged fails here — loudly, which is correct: on a host being
    rebuilt from scratch a silently missing light is worse than a red unit.
    """
    slug = bulb["slug"]
    flow = rest(
        "POST",
        "/api/config/config_entries/flow",
        {"handler": "tuya_local", "show_advanced_options": False},
        token=token,
    )

    def submit(payload):
        return rest(
            "POST",
            f"/api/config/config_entries/flow/{flow['flow_id']}",
            payload,
            token=token,
        )

    submit({"setup_mode": "manual"})
    step = submit(
        {
            "device_id": bulb["device_id"],
            "host": bulb["host"],
            "local_key": bulb_local_key(slug),
            "protocol_version": str(bulb["protocol_version"]),
            "poll_only": bool(bulb.get("poll_only", False)),
        }
    )
    if step.get("type") == "abort":
        # tuya_local aborts on a device id it already holds. Reaching this means HA
        # has the config entry but no device in the registry for it, so there is
        # nothing to adopt and nothing to place in an Area.
        if step.get("reason") == "already_configured":
            log(f"[bulb] {slug!r} is already configured (no device registered)")
            return False
        die(f"bulb {slug!r} flow aborted: {step.get('reason')}")
    if step.get("errors"):
        die(f"bulb {slug!r} did not answer at {bulb['host']}: {step['errors']}")
    submit({"type": _type_key_for(step, bulb["type"])})
    result = submit({"name": bulb["title"]})
    if result.get("type") != "create_entry":
        die(f"bulb {slug!r} flow did not create an entry: {result}")
    log(f"[bulb] created {bulb['title']!r} ({bulb['type']}) at {bulb['host']}")
    return True


def ensure_area(ws: WS, name: str) -> str:
    for area in ws.cmd({"type": "config/area_registry/list"}):
        if area["name"].casefold() == name.casefold():
            return area["area_id"]
    log(f"[area] created {name!r}")
    return ws.cmd({"type": "config/area_registry/create", "name": name})["area_id"]


def ensure_bulb_area(ws: WS, dev: dict[str, Any], area_name: str) -> None:
    """Place a bulb's device in its Area — what lets Assist address it by room."""
    area_id = ensure_area(ws, area_name)
    if dev.get("area_id") == area_id:
        log(f"[area] {dev.get('name')!r} is already in {area_name!r}")
        return
    ws.cmd(
        {
            "type": "config/device_registry/update",
            "device_id": dev["id"],
            "area_id": area_id,
        }
    )
    log(f"[area] placed {dev.get('name')!r} in {area_name!r}")


def ensure_bulbs(token, ws: WS, bulbs: list[dict[str, Any]]) -> None:
    known = tuya_devices(ws)
    for bulb in bulbs:
        dev = known.get(bulb["device_id"])
        if dev:
            log(f"[bulb] {bulb['title']!r} already configured")
        else:
            if not create_bulb(token, bulb):
                continue
            dev = tuya_devices(ws).get(bulb["device_id"])
            if not dev:
                die(f"bulb {bulb['slug']!r} registered no device after adoption")
        if bulb.get("area"):
            ensure_bulb_area(ws, dev, bulb["area"])


# --------------------------------------------------------------------------- #
# Provisioning                                                                #
# --------------------------------------------------------------------------- #
def wyoming_entry_ids(token) -> set[str]:
    """entry_ids of all Wyoming config entries. The list endpoint omits each
    entry's `data`, so roles are derived from the entities (below), not the port."""
    entries = rest("GET", "/api/config/config_entries/entry", token=token)
    return {e["entry_id"] for e in entries if e.get("domain") == "wyoming"}


def create_wyoming_entry(token, port):
    flow = rest(
        "POST",
        "/api/config/config_entries/flow",
        {"handler": "wyoming", "show_advanced_options": False},
        token=token,
    )
    result = rest(
        "POST",
        f"/api/config/config_entries/flow/{flow['flow_id']}",
        {"host": "127.0.0.1", "port": port},
        token=token,
    )
    if result.get("type") != "create_entry":
        die(f"wyoming flow for port {port} did not create an entry: {result}")
    return result["result"]["entry_id"]


def engines_by_role(ws, wy_ids):
    """Find the stt.* / tts.* engine entity_ids that belong to a Wyoming entry.
    A whisper server surfaces an stt.* entity, a piper server a tts.* entity, so
    the entity domain — not the port — tells STT from TTS. Idempotency-safe."""
    reg = ws.cmd({"type": "config/entity_registry/list"})
    stt = tts = None
    for ent in reg:
        if ent.get("config_entry_id") not in wy_ids:
            continue
        eid = ent.get("entity_id", "")
        if eid.startswith("stt."):
            stt = eid
        elif eid.startswith("tts."):
            tts = eid
    return stt, tts


# Config-entry domains to remove if HA ever creates them. Onboarding sets up a
# Google Translate TTS entry unconditionally, but google_translate is deliberately
# not in extraComponents — this host speaks through local piper — so its `gtts`
# dependency is absent and the entry fails to set up on every single start,
# printing a traceback that buries real errors. A cloud TTS is against the point of
# the host anyway, so the entry is removed rather than made to work.
UNWANTED_DOMAINS = ("google_translate",)


def prune_unwanted_entries(token) -> None:
    """Remove config entries for domains this host deliberately does not serve."""
    entries = rest("GET", "/api/config/config_entries/entry", token=token)
    for e in entries:
        if e.get("domain") not in UNWANTED_DOMAINS:
            continue
        rest(
            "DELETE",
            f"/api/config/config_entries/entry/{e['entry_id']}",
            token=token,
            allow=(200, 404),
        )
        log(f"[prune] removed the {e['domain']} entry {e.get('title')!r}")


def assert_engine_language(ws: WS, kind: str, engine_id: str, lang: str) -> None:
    """Fail loudly if an engine does not advertise the language we are about to set.

    This is the check whose absence let a stale `tts_language` sit in the pipeline
    for weeks: HA accepts the pipeline update, and the mismatch only shows up when
    someone actually talks to Assist. Reading the engine's own supported_languages
    moves the failure to provision time, where a red unit is the whole point.
    """
    res = ws.try_cmd({"type": f"{kind}/engine/list"})
    if not res.get("success"):
        # Not fatal: an HA version that does not expose the listing should not block
        # provisioning. The pipeline update below still validates engine + language.
        log(
            f"[{kind}] cannot list engines ({(res.get('error') or {}).get('code')}), skipping check"
        )
        return
    result = res["result"]
    providers = result.get("providers", result) if isinstance(result, dict) else result
    for e in providers:
        if e.get("engine_id") != engine_id:
            continue
        supported = e.get("supported_languages")
        if supported is None:
            return
        if lang not in supported:
            die(
                f"{engine_id} does not support language {lang!r}. It advertises "
                f"{sorted(supported)}. Fix the language constant in this script — "
                f"piper wants a region-qualified code (en_US), faster-whisper a bare one (en)."
            )
        log(f"[{kind}] {engine_id} supports {lang!r}")
        return
    die(f"{engine_id} is not in the {kind} engine list; cannot verify its languages")


def ensure_voice(token, ws):
    """Idempotently ensure a Wyoming STT + TTS entry exists; return their engines.
    Re-runnable: existing entries are detected via their entities and reused."""
    stt, tts = engines_by_role(ws, wyoming_entry_ids(token))
    if stt and tts:
        log(f"[wyoming] STT {stt} + TTS {tts} already present")
        return stt, tts
    if not stt:
        create_wyoming_entry(token, STT_PORT)
        log(f"[wyoming] created STT entry for :{STT_PORT}")
    if not tts:
        create_wyoming_entry(token, TTS_PORT)
        log(f"[wyoming] created TTS entry for :{TTS_PORT}")
    stt, tts = engines_by_role(ws, wyoming_entry_ids(token))
    if not stt:
        die(f"no stt.* entity after ensuring a Wyoming STT server on :{STT_PORT}")
    if not tts:
        die(f"no tts.* entity after ensuring a Wyoming TTS server on :{TTS_PORT}")
    return stt, tts


def wire_pipeline(ws, stt_engine, tts_engine):
    listing = ws.cmd({"type": "assist_pipeline/pipeline/list"})
    pipelines = listing["pipelines"]
    pref = listing.get("preferred_pipeline")
    target = next((p for p in pipelines if p["id"] == pref), pipelines[0])
    # Compare the languages too. Leaving them out is what let a pipeline carrying
    # tts_language="en" survive every run while piper rejected it at speak time.
    already = all(
        target.get(k) == v
        for k, v in (
            ("stt_engine", stt_engine),
            ("tts_engine", tts_engine),
            ("tts_voice", TTS_VOICE),
            ("stt_language", STT_LANG),
            ("tts_language", TTS_LANG),
        )
    )
    if already:
        log(f"[pipeline] {target['name']!r} already wired for local voice")
        return target["id"]
    updated = ws.cmd(
        {
            "type": "assist_pipeline/pipeline/update",
            "pipeline_id": target["id"],
            "name": target["name"],
            "language": target.get("language", "en"),
            "conversation_engine": target["conversation_engine"],
            "conversation_language": target.get("conversation_language", "en"),
            "stt_engine": stt_engine,
            "stt_language": STT_LANG,
            "tts_engine": tts_engine,
            "tts_language": TTS_LANG,
            "tts_voice": TTS_VOICE,
            "wake_word_entity": target.get("wake_word_entity"),
            "wake_word_id": target.get("wake_word_id"),
        }
    )
    log(
        f"[pipeline] wired {target['name']!r}: stt={stt_engine} tts={tts_engine} voice={TTS_VOICE}"
    )
    return (
        updated["id"] if isinstance(updated, dict) and "id" in updated else target["id"]
    )


def verify(ws, pipeline_id, stt_engine, tts_engine):
    """Re-read the pipeline from HA and assert it stuck — fail loud otherwise."""
    listing = ws.cmd({"type": "assist_pipeline/pipeline/list"})
    p = next((p for p in listing["pipelines"] if p["id"] == pipeline_id), None)
    if not p:
        die(f"pipeline {pipeline_id} vanished after update")
    if p.get("stt_engine") != stt_engine:
        die(f"stt_engine not persisted: {p.get('stt_engine')!r} != {stt_engine!r}")
    if p.get("tts_engine") != tts_engine:
        die(f"tts_engine not persisted: {p.get('tts_engine')!r} != {tts_engine!r}")
    if p.get("tts_voice") != TTS_VOICE:
        die(f"tts_voice not persisted: {p.get('tts_voice')!r} != {TTS_VOICE!r}")
    if p.get("stt_language") != STT_LANG:
        die(f"stt_language not persisted: {p.get('stt_language')!r} != {STT_LANG!r}")
    if p.get("tts_language") != TTS_LANG:
        die(f"tts_language not persisted: {p.get('tts_language')!r} != {TTS_LANG!r}")
    log(
        f"[verify] pipeline {p['name']!r} confirmed: "
        f"stt={p['stt_engine']}/{p['stt_language']} "
        f"tts={p['tts_engine']}/{p['tts_language']} voice={p['tts_voice']}"
    )


def _env_json(name: str, default):
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        die(f"{name} is not valid JSON: {e}")


def main() -> None:
    token = get_token()
    ws = WS(BASE, token)
    try:
        wait_for_ws_api(ws)
        # HTTP first: applying it restarts HA, so everything after should run on
        # the connection that comes back rather than be interrupted mid-way.
        want_http = _env_json("HA_HTTP_CONFIG", None)
        if want_http:
            ws, token = ensure_http(ws, token, want_http)
        prune_unwanted_entries(token)
        stt_engine, tts_engine = ensure_voice(token, ws)
        assert_engine_language(ws, "stt", stt_engine, STT_LANG)
        assert_engine_language(ws, "tts", tts_engine, TTS_LANG)
        pipeline_id = wire_pipeline(ws, stt_engine, tts_engine)
        verify(ws, pipeline_id, stt_engine, tts_engine)
        bulbs = _env_json("HA_BULBS", [])
        if bulbs:
            ensure_bulbs(token, ws, bulbs)
    finally:
        ws.close()
    log("PASS: Home Assistant HTTP config, local voice pipeline and bulbs provisioned")


if __name__ == "__main__":
    main()
