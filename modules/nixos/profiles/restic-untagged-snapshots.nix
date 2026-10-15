# The predicate behind the untagged-snapshot probe (palimpsest#150): given `restic snapshots
# --json` on stdin, print one line per snapshot that carries NO tag.
#
# WHY IT IS ITS OWN FILE. Every `forget` unit on this fleet is scoped `--host X --tag <job>`,
# both filters load-bearing on a repository the whole fleet writes into — so a snapshot with no
# tag is outside every retention policy there is, permanently, by construction. Three of them
# accumulated in the rsync.net repository over seven months and nothing surfaced them: the
# Backups board reads per-host status files and no host was failing, and `restic check` verifies
# structure and pack data rather than policy, so they were perfectly intact. That is the whole
# reason the probe in profiles/backup.nix exists.
#
# Its failure mode is a SILENT FALSE NEGATIVE — report zero and the condition stays invisible,
# which is indistinguishable from a healthy repository and is exactly the state that lasted
# seven months. So the predicate lives here, out of the Nix string it is used in, and
# `parts/checks/restic-untagged` exercises THIS file against synthetic snapshot lists. A test
# over a copy of the jq would pass while the real one rotted — the same argument
# immich-db-dump-freshness.nix makes for being a file rather than an inline script.
#
# Output contract, relied on by both callers: one line per untagged snapshot, nothing at all
# when there are none. The caller counts lines; it does not need a second mode.
{ pkgs }:
pkgs.writeShellScript "restic-untagged-snapshots" ''
  set -euo pipefail

  # `.tags // []` is the load-bearing part. restic omits the key entirely for an untagged
  # snapshot in some versions and emits `null` in others, and `null | length` is 0 while
  # `.tags | length` on a missing key is an ERROR that would abort the whole program — turning
  # "there are untagged snapshots" into "the probe crashed", or worse, into an empty result
  # that reads as none. Both absent and null must land in the untagged set.
  #
  # The slice on `.time` is cosmetic (restic's timestamps carry nanoseconds and a zone); it is
  # trimmed for the alert text, not used for comparison.
  ${pkgs.lib.getExe pkgs.jq} -r '
    .[] | select((.tags // []) | length == 0)
    | "  \(.short_id)  \(.time[0:19])  \(.hostname)"
  '
''
