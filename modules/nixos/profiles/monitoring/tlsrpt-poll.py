#!/usr/bin/env python3
"""TLSRPT (SMTP TLS Reporting, RFC 8460) → node-exporter textfile metrics.

The DMARC-pipeline analogue for TLS reports. DMARC aggregate reports are XML and
drained by dmarc-metrics-exporter; TLS reports are JSON (application/tlsrpt+gzip)
and nothing in nixpkgs consumes them, so this small poller does it directly:

  IMAP-poll the `tlsrpt` mailbox → parse each report → accumulate cumulative
  counters in $TLSRPT_STATE_DIR → write a *.prom textfile the node-exporter
  textfile collector already scrapes on rk1b.

Counters are cumulative (like a real exporter) so Grafana `increase()` works over
any range, and the failure-session counter can drive the #infra-alerts watcher.
State survives across runs; messages are de-duplicated by report-id (belt-and-
suspenders on top of IMAP's \\Seen flag) so a re-delivered report is never double
counted.

Config is entirely via environment (set by the systemd unit) — no secrets on the
command line:

  TLSRPT_IMAP_HOST            IMAP server (Stalwart), e.g. mail.palebluebytes.space
  TLSRPT_IMAP_PORT            implicit-TLS port (993)
  TLSRPT_IMAP_USER            Stalwart account NAME (login by name, not address)
  TLSRPT_IMAP_PASSWORD_FILE   file holding the IMAP password (sops secret)
  TLSRPT_MAILBOX              folder to poll (default INBOX)
  TLSRPT_STATE_DIR            cumulative-counter state ($STATE_DIRECTORY)
  TLSRPT_METRICS_FILE         final .prom path in the textfile collector dir

Stdlib only (imaplib/email/gzip/zipfile/json) — no third-party deps, so the unit
needs nothing but python3.
"""

from __future__ import annotations

import email
import gzip
import imaplib
import json
import os
import sys
import tempfile
import zipfile
from datetime import datetime
from typing import Any

# A parsed JSON object (report doc or state). Kept loose on purpose: TLSRPT
# documents are external input whose shape we validate at use, not by type.
JsonObj = dict[str, Any]

STATE_VERSION = 1
# Cap the remembered report-id set so state can't grow without bound. TLS reports
# arrive ~once/day per reporter; a few thousand ids is years of history.
MAX_REPORT_IDS = 4096


def log(msg: str) -> None:
    print(f"tlsrpt-poll: {msg}", file=sys.stderr)


def env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None:
        log(f"missing required env {name}")
        sys.exit(1)
    return v


def parse_iso8601(s: str) -> int | None:
    """RFC 8460 date-time (ISO 8601, e.g. '2026-07-09T23:59:59Z') → unix epoch."""
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except (ValueError, AttributeError):
        return None


def decode_report_bytes(data: bytes) -> JsonObj | None:
    """A TLS report attachment is gzip (application/tlsrpt+gzip), occasionally
    zip, or rarely bare JSON. Try each, then confirm it parses as a TLSRPT doc."""
    candidates: list[bytes] = []
    # gzip (the common case: `*.json.gz`)
    try:
        candidates.append(gzip.decompress(data))
    except (OSError, EOFError):
        pass
    # zip (older/DMARC-style packaging some MTAs reuse)
    if not candidates:
        try:
            import io

            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                for n in zf.namelist():
                    candidates.append(zf.read(n))
        except (zipfile.BadZipFile, OSError):
            pass
    # bare JSON
    candidates.append(data)

    for raw in candidates:
        try:
            doc = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(doc, dict) and "policies" in doc:
            return doc
    return None


def iter_reports(raw_message: bytes):
    """Yield every TLSRPT JSON doc found in an email's MIME parts."""
    msg = email.message_from_bytes(raw_message)
    for part in msg.walk():
        if part.get_content_maintype() == "multipart":
            continue
        payload = part.get_payload(decode=True)
        if not isinstance(payload, (bytes, bytearray)):
            continue
        doc = decode_report_bytes(bytes(payload))
        if doc is not None:
            yield doc


def load_state(path: str) -> JsonObj:
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        if st.get("version") == STATE_VERSION:
            return st
        log(
            f"state version mismatch ({st.get('version')} != {STATE_VERSION}); resetting"
        )
    except FileNotFoundError:
        pass
    except (ValueError, OSError) as e:
        log(f"unreadable state ({e}); resetting")
    return {
        "version": STATE_VERSION,
        "report_ids": [],
        "success": {},  # policy_domain -> cumulative successful sessions
        "failure": {},  # policy_domain -> cumulative failed sessions
        "failure_by_type": {},  # "domain\x00result_type" -> cumulative failed sessions
        "reports": {},  # policy_domain -> cumulative report count
        "last_seen": 0,  # max report end-datetime epoch
    }


def save_state(path: str, state: JsonObj) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def ingest(doc: JsonObj, state: JsonObj) -> bool:
    """Fold one report into cumulative state. Returns False if already seen."""
    rid = str(doc.get("report-id", ""))
    if rid and rid in state["report_ids"]:
        return False
    if rid:
        state["report_ids"].append(rid)
        if len(state["report_ids"]) > MAX_REPORT_IDS:
            state["report_ids"] = state["report_ids"][-MAX_REPORT_IDS:]

    end = (doc.get("date-range") or {}).get("end-datetime")
    if end:
        epoch = parse_iso8601(end)
        if epoch:
            state["last_seen"] = max(state["last_seen"], epoch)

    for policy in doc.get("policies", []):
        domain = (policy.get("policy") or {}).get("policy-domain") or "unknown"
        summary = policy.get("summary") or {}
        ok = int(summary.get("total-successful-session-count", 0) or 0)
        bad = int(summary.get("total-failure-session-count", 0) or 0)

        state["success"][domain] = state["success"].get(domain, 0) + ok
        state["failure"][domain] = state["failure"].get(domain, 0) + bad
        state["reports"][domain] = state["reports"].get(domain, 0) + 1

        for fd in policy.get("failure-details", []) or []:
            rtype = str(fd.get("result-type", "unknown"))
            n = int(fd.get("failed-session-count", 0) or 0)
            key = f"{domain}\x00{rtype}"
            state["failure_by_type"][key] = state["failure_by_type"].get(key, 0) + n
    return True


def prom_label(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def write_metrics(metrics_file: str, state: JsonObj) -> None:
    lines: list[str] = []

    def gauge(name: str, help_text: str, samples: list[tuple[str, float]]) -> None:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} counter")
        for labels, value in samples:
            lines.append(f"{name}{labels} {value}")

    gauge(
        "smtp_tls_report_success_sessions_total",
        "Cumulative successful TLS sessions reported via TLSRPT (RFC 8460).",
        [
            (f'{{policy_domain="{prom_label(d)}"}}', n)
            for d, n in sorted(state["success"].items())
        ],
    )
    gauge(
        "smtp_tls_report_failure_sessions_total",
        "Cumulative failed TLS sessions reported via TLSRPT (someone could not "
        "negotiate secure TLS to the MX: downgrade or cert problem).",
        [
            (f'{{policy_domain="{prom_label(d)}"}}', n)
            for d, n in sorted(state["failure"].items())
        ],
    )
    gauge(
        "smtp_tls_report_failures_total",
        "Cumulative failed TLS sessions by failure result-type (TLSRPT "
        "failure-details).",
        [
            (
                f'{{policy_domain="{prom_label(d)}",result_type="{prom_label(t)}"}}',
                n,
            )
            for (dt, n) in sorted(state["failure_by_type"].items())
            for (d, t) in [dt.split("\x00", 1)]
        ],
    )
    gauge(
        "smtp_tls_reports_total",
        "Cumulative count of TLSRPT reports ingested per policy domain.",
        [
            (f'{{policy_domain="{prom_label(d)}"}}', n)
            for d, n in sorted(state["reports"].items())
        ],
    )
    lines.append(
        "# HELP smtp_tls_report_last_seen_timestamp_seconds Unix time of the most "
        "recent TLSRPT report's coverage window end."
    )
    lines.append("# TYPE smtp_tls_report_last_seen_timestamp_seconds gauge")
    lines.append(f"smtp_tls_report_last_seen_timestamp_seconds {state['last_seen']}")

    body = "\n".join(lines) + "\n"
    metrics_dir = os.path.dirname(metrics_file)
    fd, tmp = tempfile.mkstemp(dir=metrics_dir, prefix=".tlsrpt.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        # node-exporter runs as its own user and must READ the published .prom.
        os.chmod(tmp, 0o644)
        os.replace(tmp, metrics_file)
    except BaseException:
        os.unlink(tmp)
        raise


def poll_mailbox() -> list[bytes]:
    host = env("TLSRPT_IMAP_HOST")
    port = int(env("TLSRPT_IMAP_PORT", "993"))
    user = env("TLSRPT_IMAP_USER")
    mailbox = os.environ.get("TLSRPT_MAILBOX", "INBOX")
    with open(env("TLSRPT_IMAP_PASSWORD_FILE"), encoding="utf-8") as f:
        password = f.read().strip()

    messages: list[bytes] = []
    imap = imaplib.IMAP4_SSL(host, port)
    try:
        imap.login(user, password)
        imap.select(mailbox)
        # UNSEEN so we only ever process a report once; the RFC822 fetch below
        # sets \Seen, and report-id dedup guards the rest.
        typ, data = imap.search(None, "UNSEEN")
        if typ != "OK":
            log(f"IMAP search failed: {typ}")
            return messages
        for num in data[0].split():
            typ, msgdata = imap.fetch(num, "(RFC822)")
            if typ != "OK" or not msgdata or not msgdata[0]:
                log(f"IMAP fetch failed for {num!r}: {typ}")
                continue
            messages.append(msgdata[0][1])
    finally:
        try:
            imap.logout()
        except Exception:
            pass
    return messages


def main() -> int:
    state_dir = env("TLSRPT_STATE_DIR")
    metrics_file = env("TLSRPT_METRICS_FILE")
    state_path = os.path.join(state_dir, "state.json")

    state = load_state(state_path)

    try:
        messages = poll_mailbox()
    except (imaplib.IMAP4.error, OSError) as e:
        # A transient IMAP/network error must not wipe metrics: re-publish the
        # last known counters from state and exit non-zero so the unit logs it.
        log(f"IMAP poll failed: {e}")
        write_metrics(metrics_file, state)
        return 1

    new = 0
    for raw in messages:
        for doc in iter_reports(raw):
            if ingest(doc, state):
                new += 1
    log(f"ingested {new} new report policy-set(s) from {len(messages)} message(s)")

    save_state(state_path, state)
    write_metrics(metrics_file, state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
