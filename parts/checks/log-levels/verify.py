"""Run the fleet's real VRL program over a corpus of real journal lines.

Each case is turned into the event shape Vector's journald source produces — the raw
message plus `PRIORITY` and `_SYSTEMD_UNIT` — pushed through `vector vrl`, and the
resulting `level` compared with what the case says it must be.

PRIORITY is 6 (journald's `info`) on every case on purpose: that is what a service
logging to stdout actually gets, and it is the whole reason these patterns exist. A case
expecting anything other than `info` is therefore asserting that the pattern did the work.
"""

from __future__ import annotations

import json
import subprocess
import sys


def run_vrl(program: str, events: list[dict]) -> list[dict]:
    """Feed every event through one `vector vrl` invocation, in order."""
    stdin = "".join(json.dumps(e) + "\n" for e in events)
    with open("vrl-in.jsonl", "w", encoding="utf-8") as handle:
        handle.write(stdin)

    proc = subprocess.run(
        [
            "vector",
            "vrl",
            "--program",
            program,
            "--input",
            "vrl-in.jsonl",
            "--print-object",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.exit(
            "FAIL: the generated VRL program did not compile or run.\n"
            "  This is the compiler refusing the program the fleet would ship —\n"
            "  read it before touching the corpus.\n" + proc.stdout + proc.stderr
        )

    out = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        # strict=False: real journal lines carry raw ANSI escapes, which Vector echoes
        # back unescaped and json's strict mode rejects as control characters.
        out.append(json.loads(line, strict=False))
    return out


def main() -> None:
    program_file, cases_file = sys.argv[1:3]
    with open(cases_file, encoding="utf-8") as handle:
        cases = json.load(handle)

    events = [
        {"PRIORITY": "6", "_SYSTEMD_UNIT": c["unit"], "message": c["msg"]}
        for c in cases
    ]
    results = run_vrl(program_file, events)

    if len(results) != len(cases):
        sys.exit(
            f"FAIL: fed {len(cases)} events to the program and got {len(results)} back.\n"
            "  A dropped event means the program aborted on it, which in production would\n"
            "  mean that line never reaching VictoriaLogs at all."
        )

    failures = []
    for case, got in zip(cases, results, strict=True):
        level = got.get("level")
        status = "ok " if level == case["expect"] else "FAIL"
        if level != case["expect"]:
            failures.append((case, level))
        print(f"  {status} {case['unit']:34s} -> {level!r} (want {case['expect']!r})")
        print(f"       {case['why']}")

    if failures:
        print(file=sys.stderr)
        for case, level in failures:
            print(
                f"FAIL: {case['unit']}: got level {level!r}, expected {case['expect']!r}\n"
                f"  line: {case['msg'][:160]!r}\n"
                f"  why this case exists: {case['why']}",
                file=sys.stderr,
            )
        sys.exit(1)

    print(
        f"SUCCESS: {len(cases)} real journal lines classify as expected through the "
        "fleet's own VRL — every service's own severity promoted, continuation lines and "
        "look-alike substrings left alone, and the known-benign flood demoted."
    )


if __name__ == "__main__":
    main()
