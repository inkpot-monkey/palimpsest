#!/usr/bin/env python3
"""Re-derive the disk-space alert thresholds from real fleet history.

This is the working shown for the numbers in `parts/settings.nix` (`diskFloorGiB`) and
`monitoring/disk-space.nix` (`warnMultiplier`, `failureThreshold`). Re-run it before
changing any of them, and paste the summary into the commit — thresholds picked without
measuring are how alerting becomes noise nobody reads.

It replays every candidate threshold against the `node_filesystem_*` series already in
VictoriaMetrics and reports, per candidate, how many distinct alert EPISODES it would
have produced and how many hours each device would have spent in alarm. Episode count is
the number that matters: hours-in-alarm tells you whether a threshold is a siren.

Usage, from anywhere that can reach rk1b over the tailnet:

    ssh rk1b 'curl -s http://127.0.0.1:8428/...'   # not needed; the script does it
    python3 disk-space-backtest.py                 # defaults to 90 days via ssh rk1b
    python3 disk-space-backtest.py --days 30
    python3 disk-space-backtest.py --vm http://127.0.0.1:8428   # when run ON rk1b

Note that VictoriaMetrics retains 3 months (ADR-0021) but a host only has history for the
hours it was actually up: on-demand hosts yield much shorter windows than always-on ones,
and a host that was off for the whole window yields nothing at all. The script prints the
observed window per device so a short one is visible rather than silently averaged away.
"""

from __future__ import annotations

import argparse
import json
import shlex
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

GIB = 1024**3

# Kept in step with the module's defaults and the fleet-overview dashboard panel.
EXCLUDE_FSTYPES = "tmpfs|ramfs|overlay|squashfs|vfat"
EXCLUDE_DEVICES = ".*impermanence.*"

# What the fleet currently declares. Only used to label the "as configured" run; the
# candidate sweep below is independent of it.
CONFIGURED_FLOORS = {"sawtoothShark": 20}
DEFAULT_FLOOR = 5


def selector() -> str:
    return f'fstype!~"{EXCLUDE_FSTYPES}",device!~"{EXCLUDE_DEVICES}"'


def queries() -> tuple[str, str]:
    sel = selector()
    host = '"host", "$1", "instance", "([^.:]+).*"'
    avail = f"max by (host, device) (label_replace(node_filesystem_avail_bytes{{{sel}}}, {host}))"
    pct = (
        f"max by (host, device) (label_replace(100 * (1 - node_filesystem_avail_bytes{{{sel}}}"
        f" / node_filesystem_size_bytes{{{sel}}}), {host}))"
    )
    return avail, pct


def fetch(
    vm: str, ssh_host: str | None, query: str, start: int, end: int, step: int
) -> list[dict[str, object]]:
    """Run a query_range against VictoriaMetrics, directly or via ssh."""
    params = urllib.parse.urlencode(
        {"query": query, "start": start, "end": end, "step": step}
    )
    url = f"{vm}/api/v1/query_range?{params}"
    if ssh_host:
        if not shutil.which("ssh"):
            sys.exit("ssh not found and --vm was not given")
        # ssh ALWAYS joins its command arguments and runs them through the REMOTE shell,
        # so the URL must be quoted for that shell. Passing it as bare argv looks like it
        # works and does not: the query string's `&` separators are read as job-control
        # operators, curl receives only the text up to the first one, and VictoriaMetrics
        # answers a query with no start/end/step — a single sample, silently.
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", ssh_host, f"curl -sS {shlex.quote(url)}"],
            capture_output=True,
        )
        if proc.returncode != 0:
            sys.exit(f"ssh/curl failed: {proc.stderr.decode()[:400]}")
        raw = proc.stdout
    else:
        with urllib.request.urlopen(url, timeout=60) as fh:
            raw = fh.read()
    try:
        return json.loads(raw)["data"]["result"]
    except Exception as exc:  # noqa: BLE001 - surface the body, it explains the failure
        sys.exit(f"could not parse VictoriaMetrics response ({exc}): {raw[:400]!r}")


def series_map(
    result: list[dict[str, object]], scale: float = 1.0
) -> dict[tuple[str, str], list[tuple[int, float]]]:
    out: dict[tuple[str, str], list[tuple[int, float]]] = {}
    for r in result:
        m = r["metric"]
        key = (m.get("host", "?"), m.get("device", "?"))
        out[key] = [
            (int(float(t)), float(v) * scale)
            for t, v in r["values"]
            if v not in ("NaN",)
        ]
    return out


def episodes(series: list[tuple[int, float]], bad, sustain: int) -> tuple[int, int]:
    """(distinct episodes, hours in alarm) for a predicate held `sustain` samples."""
    count = run = hours = 0
    firing = False
    for _, v in series:
        if bad(v):
            hours += 1
            run += 1
            if run >= sustain and not firing:
                count += 1
                firing = True
        else:
            run = 0
            firing = False
    return count, hours


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--days", type=int, default=90, help="window to replay (default 90)"
    )
    ap.add_argument(
        "--step", type=int, default=3600, help="sample step in seconds (default 3600)"
    )
    ap.add_argument(
        "--vm", default="http://127.0.0.1:8428", help="VictoriaMetrics base URL"
    )
    ap.add_argument(
        "--ssh",
        default="rk1b",
        help="host to reach VictoriaMetrics through (default rk1b; pass '' when running on it)",
    )
    args = ap.parse_args()

    end = int(time.time())
    start = end - args.days * 86400
    ssh_host = args.ssh or None

    q_avail, q_pct = queries()
    avail = series_map(
        fetch(args.vm, ssh_host, q_avail, start, end, args.step), 1 / GIB
    )
    pct = series_map(fetch(args.vm, ssh_host, q_pct, start, end, args.step))
    if not avail:
        sys.exit("no node_filesystem series returned — is the window before retention?")

    keys = sorted(avail)
    sample_h = args.step / 3600

    print(f"=== observed window (step {args.step}s) ===")
    print(
        f"{'host':16} {'device':22} {'days':>5} {'now GiB':>8} {'min GiB':>8} {'max %':>7}"
    )
    for k in keys:
        a = avail[k]
        p = pct.get(k, [])
        days = (a[-1][0] - a[0][0]) / 86400 if len(a) > 1 else 0
        print(
            f"{k[0]:16} {k[1]:22} {days:5.0f} {a[-1][1]:8.1f} {min(v for _, v in a):8.1f} "
            f"{(max(v for _, v in p) if p else float('nan')):7.1f}"
        )

    print("\n=== MODEL A: flat percentage (rejected — see disk-space.nix) ===")
    for thr in (75, 80, 85, 90):
        tot = sum(
            episodes(pct[k], lambda v, t=thr: v >= t, 1)[0] for k in keys if k in pct
        )
        worst = max(
            (
                (episodes(pct[k], lambda v, t=thr: v >= t, 1)[1], k[0])
                for k in keys
                if k in pct
            ),
            default=(0, "-"),
        )
        print(
            f"  >={thr}%  -> {tot:3} episodes; worst host in alarm {worst[0]:5.0f}h ({worst[1]})"
        )

    print("\n=== MODEL B: flat free-space floor ===")
    for thr in (5, 10, 15, 20):
        tot = sum(episodes(avail[k], lambda v, t=thr: v < t, 1)[0] for k in keys)
        worst = max(
            ((episodes(avail[k], lambda v, t=thr: v < t, 1)[1], k[0]) for k in keys),
            default=(0, "-"),
        )
        print(
            f"  <{thr:2}GiB -> {tot:3} episodes; worst host in alarm {worst[0]:5.0f}h ({worst[1]})"
        )

    print("\n=== MODEL C: per-host floor from the registry (what is deployed) ===")
    for mult, label in ((1, "CRITICAL (1x floor)"), (2, "WARN (2x)"), (3, "WARN (3x)")):
        print(f"  -- {label} --")
        tot = 0
        for k in keys:
            thr = CONFIGURED_FLOORS.get(k[0], DEFAULT_FLOOR) * mult
            e, h = episodes(avail[k], lambda v, t=thr: v < t, 1)
            tot += e
            if e or h:
                print(
                    f"     {k[0]:16} {k[1]:22} thr={thr:3}GiB  episodes={e:2}  hours={h:4}"
                )
        print(f"     total episodes: {tot}")

    print("\n=== debounce sensitivity (per-host floors, CRITICAL + WARN 2x) ===")
    print(f"{'sustain':>9}  {'CRIT':>5}  {'WARN':>5}  {'total':>6}")
    for sustain_h in (1, 2, 3, 6, 12):
        sus = max(1, int(sustain_h / sample_h))
        c = sum(
            episodes(
                avail[k],
                lambda v, t=CONFIGURED_FLOORS.get(k[0], DEFAULT_FLOOR): v < t,
                sus,
            )[0]
            for k in keys
        )
        w = sum(
            episodes(
                avail[k],
                lambda v, t=CONFIGURED_FLOORS.get(k[0], DEFAULT_FLOOR) * 2: v < t,
                sus,
            )[0]
            for k in keys
        )
        print(f"{sustain_h:8}h  {c:5}  {w:5}  {c + w:6}")


if __name__ == "__main__":
    main()
