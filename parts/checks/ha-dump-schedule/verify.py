"""Assert rk1a's recorder dump lands shortly before every restic run.

Reads `systemd-analyze calendar` output (the NORMALISED form only — "Next elapse" depends
on the build clock) and compares the two schedules as minutes-of-day.

Kept out of the derivation's shell so ruff formats and lints it like every other script in
this repository, and so the failure messages can say something useful.
"""

from __future__ import annotations

import re
import sys

# `*-*-* 02,14:45:00` — a date part we ignore, then an hour LIST, one minute, one second.
# Deliberately narrow: a range (`02..04`), a `*`, a `/2` step or a weekday prefix all fail
# here rather than being interpreted, because none of them is a thing a dump timer should be
# doing and guessing at one is how the original bug got through.
NORMALISED = re.compile(
    r"^Normalized form:\s+\*-\*-\*\s+(?P<hours>\d{2}(?:,\d{2})*):(?P<minute>\d{2}):(?P<second>\d{2})$"
)


def minutes_of_day(path: str) -> list[int]:
    """Every minute-of-day the calendar in `path` fires at."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.readlines()
    for line in lines:
        m = NORMALISED.match(line.strip())
        if not m:
            continue
        if m["second"] != "00":
            sys.exit(
                f"FAIL: {path}: normalised to seconds={m['second']}, not 00.\n"
                "  A dump timer firing at a non-zero second is the fingerprint of the\n"
                '  "02:45,14:45" mistake — systemd read the second field as a time.\n'
                "  Write the hours as a list: 02,14:45"
            )
        return sorted(int(h) * 60 + int(m["minute"]) for h in m["hours"].split(","))
    sys.exit(
        f"FAIL: {path}: no normalised form this check can read.\n"
        "  Expected `Normalized form: *-*-* <HH[,HH...]>:<MM>:<SS>` — one minute, one\n"
        "  second, and the only list on the HOURS. A minute list here is the fingerprint\n"
        '  of the "02:45,14:45" mistake: systemd read the 45 as minutes and the second 45\n'
        "  as seconds. Two dumps a day is an hour list: 02,14:45. Got:\n"
        + "".join(f"    {line}" for line in lines)
    )


def hhmm(minute_of_day: int) -> str:
    return f"{minute_of_day // 60:02d}:{minute_of_day % 60:02d}"


def main() -> None:
    dump_file, backup_file, min_lead_s, max_lead_s = sys.argv[1:5]
    min_lead, max_lead = int(min_lead_s), int(max_lead_s)

    dumps = minutes_of_day(dump_file)
    backups = minutes_of_day(backup_file)

    print(f"ok: dump fires at {', '.join(map(hhmm, dumps))}")
    print(f"ok: restic fires at {', '.join(map(hhmm, backups))}")

    # Every restic run must be fed by a dump taken shortly before it. Checked in this
    # direction on purpose: it is the backup that must not carry stale history, so an
    # unfed run is the failure. (A dump with no run after it is harmless.)
    for backup in backups:
        leads = [backup - d for d in dumps if min_lead <= backup - d <= max_lead]
        if not leads:
            sys.exit(
                f"FAIL: the restic run at {hhmm(backup)} has no dump "
                f"{min_lead}-{max_lead} minutes before it.\n"
                f"  dumps:  {', '.join(map(hhmm, dumps))}\n"
                f"  restic: {', '.join(map(hhmm, backups))}\n"
                "  That snapshot would carry Home Assistant's configuration as it is now\n"
                "  against its history as of the last dump — which the freshness gate\n"
                "  tolerates (it allows one missed dump) and nothing else measures.\n"
                "  Move custom.profiles.homeassistant.backup.dump.onCalendar, and check the\n"
                "  spelling with: systemd-analyze calendar '<value>'"
            )
        print(
            f"ok: the {hhmm(backup)} restic run is fed by a dump {min(leads)}m earlier"
        )

    print(
        "SUCCESS: every restic run on rk1a is preceded by a recorder dump within "
        f"{min_lead}-{max_lead} minutes, as systemd itself parses both calendars."
    )


if __name__ == "__main__":
    main()
