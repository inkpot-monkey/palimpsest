#!/usr/bin/env python3
"""Poll aioncore's local API and post AionUi agent events to a Matrix room.

Signals (discovered empirically against aioncore 2.1.x):
  - finished   : conversation status == "finished" and modified_at advanced
                 (and no pending confirmation), i.e. a turn just completed.
  - needs input: GET /api/conversations/{id}/confirmations returns a new
                 pending tool/permission approval.
  - error      : conversation status in {failed, error, cancelled}.

aioncore runs in --local mode, so /api/* needs no auth on localhost. Matrix
delivery uses the Conduit client-server API with a bot access token.

Config via env: AIONUI_URL, MATRIX_URL, MATRIX_ROOM, MATRIX_TOKEN_FILE,
STATE_DIR, POLL_INTERVAL.
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
MATRIX_ROOM = os.environ["MATRIX_ROOM"]
TOKEN_FILE = os.environ["MATRIX_TOKEN_FILE"]
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/aionui-notifier")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "10"))

STATE_PATH = os.path.join(STATE_DIR, "state.json")
ERROR_STATUSES = {"failed", "error", "cancelled", "canceled"}


def log(msg):
    print(f"[aionui-notifier] {msg}", flush=True)


def read_token():
    with open(TOKEN_FILE, "r", encoding="utf-8") as f:
        return f.read().strip()


def http_json(url, method="GET", body=None, headers=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw else {}


def list_conversations():
    d = http_json(f"{AIONUI_URL}/api/conversations")
    data = d.get("data", d)
    items = data.get("items", data) if isinstance(data, dict) else data
    return items or []


def confirmation_ids(conv_id):
    try:
        d = http_json(f"{AIONUI_URL}/api/conversations/{conv_id}/confirmations")
    except urllib.error.URLError:
        return [], {}
    items = (d.get("data") or []) if isinstance(d, dict) else (d or [])
    ids, titles = [], {}
    for c in items:
        cid = c.get("call_id") or c.get("id")
        if cid:
            ids.append(cid)
            titles[cid] = c.get("title") or "approval requested"
    return ids, titles


def send_matrix(token, text, html):
    txn = f"aionui-{time.time_ns()}"
    room = urllib.parse.quote(MATRIX_ROOM)
    url = f"{MATRIX_URL}/_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}"
    body = {
        "msgtype": "m.text",
        "body": text,
        "format": "org.matrix.custom.html",
        "formatted_body": html,
    }
    try:
        http_json(url, method="PUT", body=body,
                  headers={"Authorization": f"Bearer {token}"})
    except urllib.error.HTTPError as e:
        log(f"matrix send failed: HTTP {e.code} {e.read().decode()[:200]}")
    except urllib.error.URLError as e:
        log(f"matrix send failed: {e}")


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
    os.replace(tmp, STATE_PATH)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    token = read_token()
    prev = load_state()
    seeding = prev is None  # first ever run: record state, don't notify the backlog
    state = prev or {}
    log(f"watching {AIONUI_URL} -> {MATRIX_ROOM} every {POLL_INTERVAL}s"
        + (" (seeding, no backlog notifications)" if seeding else ""))

    while True:
        try:
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

            p = state.get(cid, {})
            events = []
            new_confs = [i for i in conf_ids if i not in set(p.get("conf_ids", []))]
            if new_confs:
                titles = ", ".join(conf_titles[i] for i in new_confs)
                events.append(("needs input", f"❓ needs input: {name} — {titles}"))
            elif status == "finished" and modified > p.get("modified_at", 0) \
                    and not conf_ids and p:
                events.append(("finished", f"✅ finished: {name}"))
            if status in ERROR_STATUSES and status != p.get("status"):
                events.append(("error", f"⚠️ error ({status}): {name}"))

            if not seeding:
                for _kind, msg in events:
                    log(msg)
                    send_matrix(token, msg, msg)

            state[cid] = {"modified_at": modified, "status": status,
                          "conf_ids": conf_ids}

        for cid in list(state.keys()):
            if cid not in seen:
                del state[cid]

        save_state(state)
        seeding = False
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
