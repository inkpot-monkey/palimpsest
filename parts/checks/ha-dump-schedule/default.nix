{
  self,
  pkgs,
  ...
}:

# rk1a's recorder-dump timer against its restic timer, checked with systemd's OWN calendar
# parser rather than a reimplementation of it.
#
# WHY THIS EXISTS — it is a post-mortem, not a precaution. The dump's `OnCalendar` was first
# written `"02:45,14:45"`, which reads like "02:45 and 14:45" and is not that at all. An
# `OnCalendar` is `<hours>:<minutes>:<seconds>`, so two times a day is an HOUR LIST (`02,14:45`);
# systemd accepted the original happily and normalised it to `*-*-* 02:14,45:45` — 02:14:45 and
# 02:45:45, two runs in the small hours and nothing in the afternoon. It deployed green:
# `systemctl list-timers` said `Thu 02:14:45`, the dump unit worked perfectly, and the only
# visible symptom would have been the 15:00 snapshot carrying history 12 hours older than it
# should, which nothing on the fleet measures.
#
# The coupling it protects is real and invisible: the dump has to land BEFORE each restic run and
# close enough to it that the snapshot is an almost-consistent pair of history and configuration.
# The host's freshness gate (ha-dump-freshness) catches a dump that stopped, and `maxDumpAgeSeconds`
# tolerates one miss on purpose, so neither notices a dump that merely runs at the wrong time.
#
# ⚠ THE SUBJECT IS systemd'S NORMALISED FORM, not the string in nix. That is the whole point:
# a Nix-side regex on `"02:45,14:45"` would have agreed with the author's intention rather than
# with systemd, and passed. This runs `systemd-analyze calendar` — the same parser the timer
# uses — and reads what it says the value MEANS. (The lesson [[verify-with-the-parser-not-a-grep]]
# records, applied before it bit twice.)
#
# Only the normalised form is used, never "Next elapse" or "From now": those depend on the clock
# at build time and would make this derivation rebuild every day and mean nothing when it did.
#
# Both calendars are read from the LIVE host config, so this cannot drift from what rk1a runs.

let
  host = self.nixosConfigurations.rk1a.config;

  dumpCalendar = host.systemd.timers.ha-db-dump.timerConfig.OnCalendar;
  backupCalendar = host.systemd.timers.restic-backups-daily-rsyncnet.timerConfig.OnCalendar;

  # The window a dump must land in before its restic run. Lower bound so the dump has finished
  # (measured: 225 ms on rk1a's real database, so this is slack, not a budget); upper bound so
  # "before the backup" cannot quietly become "the previous run's dump".
  minLeadMinutes = 5;
  maxLeadMinutes = 30;
in
pkgs.runCommand "check-ha-dump-schedule"
  {
    nativeBuildInputs = [
      pkgs.systemd
      pkgs.python3
    ];
    inherit dumpCalendar backupCalendar;
  }
  ''
    set -euo pipefail

    # The real parser, on both values. A calendar systemd cannot parse at all exits non-zero
    # here, which is also a failure worth having.
    systemd-analyze calendar "$dumpCalendar"   > dump.txt
    systemd-analyze calendar "$backupCalendar" > backup.txt
    echo "dump   ($dumpCalendar): $(grep Normalized dump.txt)"
    echo "backup ($backupCalendar): $(grep Normalized backup.txt)"

    python3 ${./verify.py} dump.txt backup.txt \
      ${toString minLeadMinutes} ${toString maxLeadMinutes}

    touch $out
  ''
