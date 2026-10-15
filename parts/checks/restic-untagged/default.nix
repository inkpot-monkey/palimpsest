{
  self,
  pkgs,
  ...
}:

# The untagged-snapshot predicate (modules/nixos/profiles/restic-untagged-snapshots.nix), which
# the probe in profiles/backup.nix runs daily on the elected maintainer (palimpsest#150).
#
# WHAT IS WORTH PINNING is not "does it parse JSON" — it is that the predicate cannot report
# ZERO while untagged snapshots exist. That is its only dangerous failure, and it is invisible:
# a repository with hidden orphans looks exactly like a clean one, which is the state that
# actually lasted seven months in the rsync.net repository while three accumulated. Every case
# below is therefore either "this shape must be reported" or "this shape must NOT be".
#
# Case 2 is the one the real repository would have exercised and a hand-written fixture would
# miss: restic does not spell an untagged snapshot one way. Depending on version it omits the
# `tags` key entirely or emits `null`, and `.tags | length` on a missing key is a jq ERROR that
# aborts the program — producing empty output, which the caller counts as zero. Absent and null
# must both land in the untagged set, which is what `.tags // []` is for.
#
# No VM and no restic: the contract is (snapshot JSON) -> (lines), so a derivation feeding the
# REAL script synthetic lists covers all of it. Imported from the same file backup.nix imports —
# deliberately not a copy, which would pass while the live one rotted.

let
  predicate = import (self + /modules/nixos/profiles/restic-untagged-snapshots.nix) {
    inherit pkgs;
  };
in
pkgs.runCommand "check-restic-untagged"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail

    # The snapshot lists are passed as ARGUMENTS, not heredocs. A heredoc terminator has to sit
    # at column 0 of the FINAL script, and this is a Nix indented string whose common leading
    # whitespace is stripped at evaluation — so the terminators only landed correctly by
    # arithmetic, and one future line indented more shallowly than them would have silently made
    # every heredoc run to end-of-file. `nix fmt` reindenting this file is enough to do it.
    #
    # ⚠ `$out` is the derivation's output path — never shadow it. The locals below are named away
    # from it deliberately; an earlier draft assigned `out=$(…)` and would have ended by touching
    # a file named after the predicate's output.
    expect() { # $1 = expected line count, $2 = description, $3 = snapshot json
      local want="$1" desc="$2" json="$3" said n
      said=$(printf '%s' "$json" | ${predicate} || true)
      n=$(printf '%s' "$said" | grep -c . || true)
      if [ "$n" != "$want" ]; then
        echo "FAIL: $desc — expected $want untagged, got $n" >&2
        echo "  predicate said:" >&2
        printf '%s\n' "$said" | sed 's/^/    /' >&2
        exit 1
      fi
      echo "ok ($n): $desc"
    }

    # 1. The shape the fleet runs: every snapshot tagged by its job. Must report nothing.
    expect 0 "a fully tagged repository reports none" \
      '[ {"short_id":"aaaaaaaa","time":"2026-10-15T03:00:10.1Z","hostname":"kelpy","tags":["daily"]},
         {"short_id":"bbbbbbbb","time":"2026-10-15T15:00:02.2Z","hostname":"rk1b","tags":["daily"]},
         {"short_id":"cccccccc","time":"2026-10-15T00:00:01.3Z","hostname":"rk1b","tags":["telemetry"]} ]'

    # 2. ⚠ THE CASE THE PREDICATE EXISTS FOR, in two of the three spellings restic uses. A
    #    missing `tags` key and an explicit null must BOTH count — and `.tags | length` without
    #    the `// []` would abort on the missing key, emitting nothing, which the caller counts as
    #    zero and reads as a clean repository.
    expect 2 "a missing tags key and an explicit null both count as untagged" \
      '[ {"short_id":"dddddddd","time":"2026-03-04T18:00:13.4Z","hostname":"kelpy"},
         {"short_id":"eeeeeeee","time":"2026-03-04T12:33:34.5Z","hostname":"kelpy","tags":null},
         {"short_id":"ffffffff","time":"2026-10-15T03:00:10.6Z","hostname":"kelpy","tags":["daily"]} ]'

    # 3. An empty tag LIST is the third spelling, and the most obvious one.
    expect 1 "an empty tags array counts as untagged" \
      '[ {"short_id":"11111111","time":"2026-03-04T18:00:06.7Z","hostname":"porcupineFish","tags":[]},
         {"short_id":"22222222","time":"2026-10-15T03:00:10.8Z","hostname":"kelpy","tags":["daily"]} ]'

    # 4. The three real orphans, as they actually sat in the repository (palimpsest#150) — two
    #    kelpy snapshots from one March afternoon and one from porcupineFish, among tagged
    #    dailies. The regression case, and it must come back 3: ONE was reported at the time,
    #    because the listing it was read from had been truncated to the last 25 lines.
    expect 3 "the three real March orphans among tagged dailies" \
      '[ {"short_id":"dc4c142d","time":"2026-03-04T18:00:13.0Z","hostname":"kelpy","tags":[]},
         {"short_id":"12fd0594","time":"2026-03-04T12:33:34.0Z","hostname":"kelpy"},
         {"short_id":"52e8ba85","time":"2026-03-04T18:00:06.0Z","hostname":"porcupineFish","tags":null},
         {"short_id":"3a868c83","time":"2026-10-14T22:20:33.0Z","hostname":"kelpy","tags":["daily"]},
         {"short_id":"d381fcf2","time":"2026-10-15T03:00:10.0Z","hostname":"kelpy","tags":["daily"]} ]'

    # 5. A tag that is not a RETENTION tag is still a tag, and this predicate must not pretend
    #    otherwise. The wider invariant — every (host, tag) pair reachable by some forget job —
    #    needs fleet-wide knowledge a single host does not have at runtime, and the profile
    #    header says so rather than implying this covers it. Pinned so nobody "fixes" the
    #    predicate into guessing.
    expect 0 "a snapshot tagged for no existing job is NOT reported (known gap, by design)" \
      '[ {"short_id":"33333333","time":"2026-10-15T03:00:10.0Z","hostname":"kelpy","tags":["weekly"]} ]'

    # 6. An empty repository is not a finding.
    expect 0 "an empty repository reports none" '[]'

    # 7. The output IS the alert's body, so it has to identify what to act on: the short id, the
    #    timestamp trimmed of restic's nanoseconds, and the host.
    line=$(printf '%s' \
      '[ {"short_id":"dc4c142d","time":"2026-03-04T18:00:13.123456789Z","hostname":"kelpy","tags":[]} ]' \
      | ${predicate})
    case "$line" in
      *dc4c142d*2026-03-04T18:00:13*kelpy*) echo "ok: the line names the id, the trimmed time and the host" ;;
      *) echo "FAIL: the reported line is not actionable: $line" >&2; exit 1 ;;
    esac
    case "$line" in
      *123456789*) echo "FAIL: restic's nanoseconds were not trimmed: $line" >&2; exit 1 ;;
      *) ;;
    esac

    echo
    echo "SUCCESS: the predicate reports untagged snapshots in all three spellings restic uses,"
    echo "         counts the real March orphans as 3, and stays silent on a tagged repository."
    touch "$out"
  ''
