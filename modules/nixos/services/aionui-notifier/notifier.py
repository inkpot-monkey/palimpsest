#!/usr/bin/env python3
"""Poll aioncore's local API and post AionUi agent events to Matrix.

Two delivery modes (aioncore can't push, so a poller is needed either way —
see ADR-0008):

  - webhook mode (preferred): if MATRIX_WEBHOOK_URL_FILE points at a non-empty
    file, each event is POSTed as `{"text": …}` to that hookshot generic-webhook
    URL, and hookshot owns the Matrix side. No bot login, room, or token here.
  - matrix-direct mode (legacy): otherwise the notifier logs a bot in
    (registering it first if needed) and posts straight to a room/alias.

Self-bootstrapping (matrix-direct): given a bot password (and, for first run, the
homeserver's registration token), the notifier logs the bot in — registering it
first if needed — and ensures the target room exists, resolving a room *alias*
(creating the room if missing). So a deploy needs only secrets + a room alias in
config; no manual token/room-id copying.

Agent event signals (confirmed against aioncore 2.1.x):
  - finished   : conversation status == "finished" and modified_at advanced
                 (and no pending confirmation) — a turn just completed.
  - needs input: GET /api/conversations/{id}/confirmations gains an entry
                 (a pending tool/permission approval).
  - error      : conversation status in {failed, cancelled}.

aioncore runs in --local mode, so /api/* needs no auth on localhost.

Config via env: AIONUI_URL, STATE_DIR, POLL_INTERVAL, and either
MATRIX_WEBHOOK_URL_FILE (webhook mode) or the matrix-direct set: MATRIX_URL,
MATRIX_USER, MATRIX_PASSWORD_FILE, MATRIX_REGISTRATION_TOKEN_FILE (optional),
MATRIX_ROOM (alias or id), MATRIX_INVITE (optional).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

AIONUI_URL = os.environ.get("AIONUI_URL", "http://127.0.0.1:25808").rstrip("/")
MATRIX_URL = os.environ.get("MATRIX_URL", "http://127.0.0.1:6167").rstrip("/")
MATRIX_USER = os.environ.get("MATRIX_USER", "")
PASSWORD_FILE = os.environ.get("MATRIX_PASSWORD_FILE", "")
REG_TOKEN_FILE = os.environ.get("MATRIX_REGISTRATION_TOKEN_FILE", "")
MATRIX_ROOM = os.environ.get("MATRIX_ROOM", "")
MATRIX_INVITE = os.environ.get("MATRIX_INVITE", "")
WEBHOOK_URL_FILE = os.environ.get("MATRIX_WEBHOOK_URL_FILE", "")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/aionui-notifier")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "10"))

STATE_PATH = os.path.join(STATE_DIR, "state.json")
ERROR_STATUSES = {"failed", "error", "cancelled", "canceled"}


def log(msg):
    print(f"[aionui-notifier] {msg}", flush=True)


def read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


def http(url, method="GET", body=None, token=None, timeout=15):
    """Return (status, parsed_json). Does not raise on HTTP error status."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw}


class Matrix:
    def __init__(self, state):
        self.state = state
        self.token = state.get("token")
        self.room_id = state.get("room_id")

    # --- auth ---------------------------------------------------------------
    def _login(self):
        status, body = http(
            f"{MATRIX_URL}/_matrix/client/v3/login", "POST",
            {"type": "m.login.password",
             "identifier": {"type": "m.id.user", "user": MATRIX_USER},
             "password": read_file(PASSWORD_FILE)})
        if status == 200 and body.get("access_token"):
            return body["access_token"]
        return None

    def _register(self):
        if not REG_TOKEN_FILE or not os.path.exists(REG_TOKEN_FILE):
            return False
        reg = read_file(REG_TOKEN_FILE)
        url = f"{MATRIX_URL}/_matrix/client/v3/register"
        payload = {"username": MATRIX_USER,
                   "password": read_file(PASSWORD_FILE), "inhibit_login": True}
        status, body = http(url, "POST", payload)  # UIA challenge
        session = body.get("session")
        if status == 200:
            return True
        if not session:
            log(f"register: unexpected response {status} {body}")
            return False
        payload["auth"] = {"type": "m.login.registration_token",
                           "token": reg, "session": session}
        status, body = http(url, "POST", payload)
        if status == 200:
            log(f"registered bot {MATRIX_USER}")
            return True
        if body.get("errcode") == "M_USER_IN_USE":
            log("register: bot user exists but login failed — check the password")
            return False
        log(f"register failed: {status} {body}")
        return False

    def ensure_token(self, force=False):
        if self.token and not force:
            return True
        tok = self._login()
        if not tok:
            self._register()
            tok = self._login()
        if tok:
            self.token = tok
            self.state["token"] = tok
            return True
        log("could not obtain a Matrix access token")
        return False

    # --- room ---------------------------------------------------------------
    def ensure_room(self):
        if self.room_id:
            return True
        if MATRIX_ROOM.startswith("!"):
            self.room_id = MATRIX_ROOM
        else:  # treat as alias, resolve or create
            alias = MATRIX_ROOM
            status, body = http(
                f"{MATRIX_URL}/_matrix/client/v3/directory/room/"
                f"{urllib.parse.quote(alias)}")
            if status == 200:
                self.room_id = body["room_id"]
            else:
                localpart = alias.lstrip("#").split(":", 1)[0]
                req = {"room_alias_name": localpart, "name": "AionUi alerts",
                       "preset": "private_chat"}
                if MATRIX_INVITE:
                    req["invite"] = [MATRIX_INVITE]
                status, body = http(
                    f"{MATRIX_URL}/_matrix/client/v3/createRoom", "POST",
                    req, token=self.token)
                if status != 200:
                    log(f"createRoom failed: {status} {body}")
                    return False
                self.room_id = body["room_id"]
                log(f"created room {alias} -> {self.room_id}")
        self.state["room_id"] = self.room_id
        return True

    # --- send ---------------------------------------------------------------
    def send(self, text, html):
        room = urllib.parse.quote(self.room_id)
        txn = f"aionui-{time.time_ns()}"
        url = (f"{MATRIX_URL}/_matrix/client/v3/rooms/{room}"
               f"/send/m.room.message/{txn}")
        payload = {"msgtype": "m.text", "body": text,
                   "format": "org.matrix.custom.html", "formatted_body": html}
        status, body = http(url, "PUT", payload, token=self.token)
        if status == 401:  # token expired — re-login once
            if self.ensure_token(force=True):
                status, body = http(url, "PUT", payload, token=self.token)
        if status != 200:
            log(f"matrix send failed: {status} {body}")


class Webhook:
    """Webhook-mode sink: POST events to a hookshot generic webhook.

    hookshot renders a generic-webhook payload's `text`/`html` fields directly,
    so no per-connection JS transform is required. Exposes the same surface as
    Matrix (token/room_id/ensure_*) so the main loop is mode-agnostic.
    """

    def __init__(self, url):
        self.url = url
        # Always "ready" — there is no auth/room bootstrap in webhook mode.
        self.token = True
        self.room_id = True

    def ensure_token(self, force=False):
        return True

    def ensure_room(self):
        return True

    def send(self, text, html):
        status, body = http(self.url, "POST",
                            {"text": text, "html": html})
        if status not in (200, 201, 202):
            log(f"webhook send failed: {status} {body}")


def list_conversations():
    _s, d = http(f"{AIONUI_URL}/api/conversations")
    data = d.get("data", d)
    items = data.get("items", data) if isinstance(data, dict) else data
    return items or []


def confirmation_ids(conv_id):
    _s, d = http(f"{AIONUI_URL}/api/conversations/{conv_id}/confirmations")
    items = (d.get("data") or []) if isinstance(d, dict) else (d or [])
    ids, titles = [], {}
    for c in items:
        cid = c.get("call_id") or c.get("id")
        if cid:
            ids.append(cid)
            titles[cid] = c.get("title") or "approval requested"
    return ids, titles


def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_state(state):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE_PATH)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    prev = load_state()
    seeding = prev is None  # first run: record state, don't replay the backlog
    state = prev or {}
    state.setdefault("convs", {})
    convs_state = state["convs"]

    # MATRIX_WEBHOOK_URL_FILE being configured selects webhook mode; its content
    # may not exist yet (the hookshot generic webhook is created at runtime via a
    # bot command, then its URL written to the file), in which case we idle.
    webhook_mode = bool(WEBHOOK_URL_FILE)
    if webhook_mode:
        url = read_file(WEBHOOK_URL_FILE) if os.path.exists(WEBHOOK_URL_FILE) else ""
        mx = Webhook(url) if url else None
        if mx is None:
            log("webhook URL not set yet — create the hookshot generic webhook, "
                "write its URL to the URL file, then restart; idling until then")
        target = "hookshot generic webhook"
    else:
        mx = Matrix(state)
        if not mx.ensure_token() or not mx.ensure_room():
            log("Matrix bootstrap failed; will retry")
        target = MATRIX_ROOM
    save_state(state)
    log(f"watching {AIONUI_URL} -> {target} every {POLL_INTERVAL}s"
        + (" (seeding)" if seeding else ""))

    while True:
        try:
            if webhook_mode and mx is None:
                # Pick up the webhook URL once it's been written (no restart needed).
                url = read_file(WEBHOOK_URL_FILE) if os.path.exists(WEBHOOK_URL_FILE) else ""
                if not url:
                    time.sleep(POLL_INTERVAL)
                    continue
                mx = Webhook(url)
                log("webhook URL loaded; delivering events")
            if not mx.token and not mx.ensure_token():
                time.sleep(POLL_INTERVAL)
                continue
            if not mx.room_id and not mx.ensure_room():
                time.sleep(POLL_INTERVAL)
                continue
            convs = list_conversations()
        except urllib.error.URLError as e:
            log(f"poll failed: {e}")
            time.sleep(POLL_INTERVAL)
            continue

        seen = set()
        for c in convs:
            cid = c.get("id")
            if not cid:
                continue
            seen.add(cid)
            name = c.get("name") or cid
            status = (c.get("status") or "").lower()
            modified = c.get("modified_at") or 0
            conf_ids, conf_titles = confirmation_ids(cid)

            p = convs_state.get(cid, {})
            events = []
            new_confs = [i for i in conf_ids if i not in set(p.get("conf_ids", []))]
            if new_confs:
                titles = ", ".join(conf_titles[i] for i in new_confs)
                events.append(f"❓ needs input: {name} — {titles}")
            elif status == "finished" and modified > p.get("modified_at", 0) \
                    and not conf_ids and p:
                events.append(f"✅ finished: {name}")
            if status in ERROR_STATUSES and status != p.get("status"):
                events.append(f"⚠️ error ({status}): {name}")

            if not seeding:
                for msg in events:
                    log(msg)
                    mx.send(msg, msg)

            convs_state[cid] = {"modified_at": modified, "status": status,
                                "conf_ids": conf_ids}

        for cid in list(convs_state.keys()):
            if cid not in seen:
                del convs_state[cid]

        save_state(state)
        seeding = False
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
