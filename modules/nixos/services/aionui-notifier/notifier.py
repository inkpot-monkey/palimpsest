"""Poll aioncore's local API and post AionUi agent events to a hookshot webhook.

aioncore can't push (extension channels run metadata-only on the headless
backend — see ADR-0008), so this poller watches the local /api and POSTs a
message on three transitions. Delivery is a matrix-hookshot generic webhook:
each event is sent as `{"text": …}` and hookshot owns the Matrix side (room,
formatting, posting). The webhook URL is provisioned declaratively and written
to MATRIX_WEBHOOK_URL_FILE by the aionui-hookshot-provision service; until that
file has content the notifier idles, then picks it up without a restart.

Agent event signals (confirmed against aioncore 2.1.x):
  - finished   : conversation status == "finished" and modified_at advanced
                 (and no pending confirmation) — a turn just completed.
  - needs input: GET /api/conversations/{id}/confirmations gains an entry
                 (a pending tool/permission approval).
  - error      : conversation status in {failed, cancelled}.

aioncore runs in --local mode, so /api/* needs no auth on localhost.

Config via env: AIONUI_URL, MATRIX_WEBHOOK_URL_FILE, STATE_DIR, POLL_INTERVAL.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

AIONUI_URL = os.environ.get("AIONUI_URL", "http://127.0.0.1:25808").rstrip("/")
WEBHOOK_URL_FILE = os.environ["MATRIX_WEBHOOK_URL_FILE"]
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/aionui-notifier")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "10"))

STATE_PATH = os.path.join(STATE_DIR, "state.json")
ERROR_STATUSES = {"failed", "error", "cancelled", "canceled"}


def log(msg):
    print(f"[aionui-notifier] {msg}", flush=True)


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def http(url, method="GET", body=None, timeout=15):
    """Return (status, parsed_json). Does not raise on HTTP error status."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
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


def post_event(url, text):
    """POST one event to the hookshot generic webhook (renders `text`/`html`)."""
    status, body = http(url, "POST", {"text": text, "html": text})
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
    save_state(state)
    log(f"watching {AIONUI_URL} every {POLL_INTERVAL}s"
        + (" (seeding)" if seeding else ""))

    while True:
        try:
            url = read_file(WEBHOOK_URL_FILE)
            if not url:
                # Provisioner hasn't written the webhook URL yet — idle.
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
                    post_event(url, msg)

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
