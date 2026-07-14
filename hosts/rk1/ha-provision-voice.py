#!/usr/bin/env python3
"""Codify the one-time UI wiring of Home Assistant's local voice stack on rk1a.

Home Assistant has no declarative path for config-entry integrations (Wyoming)
or Assist pipelines — they are created by config flows and live in HA's mutable
`.storage`. Rather than seed that private state (version-fragile), this script
drives HA's *supported* config-flow + assist_pipeline APIs — the exact calls the
UI buttons make underneath — so the action is documented in code, re-runnable,
and fails loudly if anything is wrong.

It is idempotent: existing Wyoming entries / an already-wired pipeline are left
alone, so it is safe to re-run (e.g. as a post-deploy check).

What it wires (matches modules/nixos/profiles/homeassistant.nix):
  - Wyoming STT  -> tcp://127.0.0.1:10300 (wyoming-faster-whisper)
  - Wyoming TTS  -> tcp://127.0.0.1:10200 (wyoming-piper, en_US-lessac-medium)
  - The preferred Assist pipeline's stt_engine / tts_engine / tts_voice.

Auth (pick one):
  - HA_TOKEN=<long-lived access token>            (preferred; revocable)
  - HA_OWNER_USERNAME + HA_OWNER_PASSWORD          (logs in each run)
  - HA_OWNER_NAME + HA_OWNER_USERNAME + HA_OWNER_PASSWORD, on a *fresh* HA,
    completes onboarding first (creates the owner account).

Config via env: HA_URL (default http://127.0.0.1:8123). Run on rk1a against
loopback, or remotely against https://home.<domain> with a token.

Exit non-zero on any failure. Stdlib only (no third-party deps on the node).
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, NoReturn

# Wyoming loopback endpoints + piper voice — fixed by the homeassistant profile.
STT_PORT = 10300
TTS_PORT = 10200
TTS_VOICE = "en_US-lessac-medium"
STT_LANG = TTS_LANG = "en"

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
    steps = rest("GET", "/api/onboarding")
    user_done = any(s["step"] == "user" and s["done"] for s in steps)
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

    def cmd(self, msg: dict[str, Any]) -> Any:
        self._id += 1
        msg = {**msg, "id": self._id}
        self._send_raw(msg)
        while True:
            res = self.recv()
            if res.get("id") == self._id and res.get("type") == "result":
                if not res.get("success", False):
                    die(f"WS command {msg['type']} failed: {res.get('error')}")
                return res["result"]

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


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
    already = (
        target.get("stt_engine") == stt_engine
        and target.get("tts_engine") == tts_engine
    )
    if already and target.get("tts_voice") == TTS_VOICE:
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
    log(
        f"[verify] pipeline {p['name']!r} confirmed: "
        f"stt={p['stt_engine']} tts={p['tts_engine']} voice={p['tts_voice']}"
    )


def main() -> None:
    token = get_token()
    ws = WS(BASE, token)
    try:
        stt_engine, tts_engine = ensure_voice(token, ws)
        pipeline_id = wire_pipeline(ws, stt_engine, tts_engine)
        verify(ws, pipeline_id, stt_engine, tts_engine)
    finally:
        ws.close()
    log("PASS: Home Assistant voice pipeline is wired for local Wyoming STT/TTS")


if __name__ == "__main__":
    main()
