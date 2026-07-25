# The git-annex replication watcher's check SCRIPT, shared by the NixOS profile
# (modules/nixos/profiles/monitoring/git-annex-alert.nix, a root system unit on the
# always-on hosts) and the home-manager alert (modules/homeManager/git-annex/alert.nix,
# a user unit on a workstation). Both reach the SAME #infra-alerts webhook with the SAME
# quiet/debounce/presence semantics; only where they run, which repos they watch, and
# where their webhook secret comes from differ — and those are the parameters.
#
# Why a user unit exists at all: on a workstation the webhook secret is decrypted by the
# user's own sops (the admin key already there), so a user-level check needs no host
# re-key and keeps the secret in the user's domain. Running as the user also means it
# only ticks while the session is up — which is exactly when a workstation's on-demand
# metrics are fresh — so the presence rule below is belt-and-suspenders there and load-
# bearing on any on-demand host that runs the check as a system unit.
#
# Reading local textfiles (not querying VictoriaMetrics) is deliberate: the check runs on
# the host that owns the repo, needs no network, and keeps working when the very link it
# reports on is down. The blind spot — a dead exporter leaving a stale file reading `1` —
# is closed by git_annex_check_timestamp_seconds and the staleness branch here.
{ lib, pkgs }:
{
  # Build the check script.
  #   name             the writeShellScript name (also the systemd unit's ExecStart)
  #   webhookUrlFile   file whose contents are the hookshot webhook url (may be null →
  #                    the check logs a skip and posts nothing, e.g. before a secret lands)
  #   metricsDir       node-exporter textfile dir holding git-annex-<tag>.prom
  #   repoTags         file tags to watch: "<repo>" (system) or "<user>-<repo>" (home)
  #   presence         "always-on" (strict staleness) | "on-demand" (stale/absent = quiet)
  #   failureThreshold consecutive bad reads before paging (debounce)
  #   staleAfterSec    age at which published metrics count as stale
  mkCheckScript =
    {
      name,
      webhookUrlFile,
      metricsDir,
      repoTags,
      presence,
      failureThreshold,
      staleAfterSec,
    }:
    pkgs.writeShellScript name ''
      set -u
      host="$(${pkgs.inetutils}/bin/hostname)"
      url="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg (toString webhookUrlFile)} 2>/dev/null || true)"
      state="$STATE_DIRECTORY"
      metrics_dir=${lib.escapeShellArg metricsDir}
      now="$(${pkgs.coreutils}/bin/date +%s)"
      threshold=${toString failureThreshold}
      presence=${lib.escapeShellArg presence}

      post() { # $1 = message text
        if [ -z "$url" ]; then
          echo "git-annex-alert: webhook url not available yet, skipping post: $1" >&2
          return 0
        fi
        ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null \
          -H 'content-type: application/json' \
          --data "$(${pkgs.jq}/bin/jq -nc --arg t "$1" '{text:$t}')" \
          "$url" \
          || echo "git-annex-alert: failed to POST alert (hookshot down?): $1" >&2
      }

      # $1=state key $2=1 healthy/0 bad $3=message when it goes bad $4=message when it clears
      track() {
        key="$(printf '%s' "$1" | ${pkgs.coreutils}/bin/tr -c 'A-Za-z0-9' '_')"
        cf="$state/$key.count"     # consecutive bad ticks
        rf="$state/$key.reported"  # last reported state: up | down
        reported="$(${pkgs.coreutils}/bin/cat "$rf" 2>/dev/null || echo up)"

        if [ "$2" = "1" ]; then
          ${pkgs.coreutils}/bin/rm -f "$cf"
          if [ "$reported" = "down" ]; then
            post "✅ [$host] git-annex — $4"
            printf up > "$rf"
          fi
        else
          count="$(${pkgs.coreutils}/bin/cat "$cf" 2>/dev/null || echo 0)"
          count=$((count + 1))
          printf '%s' "$count" > "$cf"
          if [ "$count" -ge "$threshold" ] && [ "$reported" != "down" ]; then
            post "🚨 [$host] git-annex — $3"
            printf down > "$rf"
          fi
        fi
      }

      label() { # $1 = series, $2 = label name → prints the label value
        printf '%s' "$1" | ${pkgs.gnused}/bin/sed -n "s/.*$2=\"\([^\"]*\)\".*/\1/p"
      }

      # --- is each repo's health data itself trustworthy? ----------------------
      # Checked FIRST and per declared repo, not per file, so a repo whose exporter never
      # ran (no file at all) is as visible as one whose exporter died (stale file). Both
      # otherwise present as silence, which is indistinguishable from health.
      #
      # $repo is a FILE TAG: a bare name for a system repo, or "<user>-<name>" for a
      # home-manager repo (matching the exporter's git-annex-<tag>.prom naming).
      for repo in ${lib.escapeShellArgs repoTags}; do
        f="$metrics_dir/git-annex-$repo.prom"

        # Decide first whether the data can be trusted, THEN what to do about it — because
        # the answer to "data absent or stale" depends on the host's presence.
        stale_reason=""
        if [ ! -e "$f" ]; then
          stale_reason="repo '$repo' has published no health metrics at all — git-annex-metrics-$repo has never completed, so this repo is UNMONITORED"
        else
          ts="$(${pkgs.gnugrep}/bin/grep '^git_annex_check_timestamp_seconds' "$f" | ${pkgs.gawk}/bin/awk '{print $NF}')"
          if [ -z "$ts" ]; then
            stale_reason="repo '$repo' publishes metrics with no check timestamp — cannot tell fresh data from stale"
          else
            age=$(( now - ts ))
            if [ "$age" -gt ${toString staleAfterSec} ]; then
              stale_reason="repo '$repo' health data is stale ($age s old) — git-annex-metrics-$repo has stopped running, so every reading below is frozen and meaningless"
            fi
          fi
        fi

        if [ -n "$stale_reason" ]; then
          # On an ON-DEMAND host (a workstation), absent/stale data is EXPECTED, not a dead
          # exporter: the user-run writer only publishes while the session is up, so a
          # closed lid legitimately freezes it. Skip WITHOUT touching state (Variant 1) —
          # a real bad signal that fired while the laptop was in use stays reported as down
          # and clears only when it next reads healthy, so a closed lid neither pages nor
          # spuriously "recovers". An ALWAYS-ON host has no such excuse: stale means the
          # exporter died, which is exactly the blind spot this check exists to close.
          if [ "$presence" = "on-demand" ]; then
            continue
          fi
          track "meta:$repo" 0 "$stale_reason" "repo '$repo' health data is fresh again"
          continue
        fi
        track "meta:$repo" 1 "" "repo '$repo' health data is fresh again"

        # --- the signals themselves ------------------------------------------
        # Only reached for a repo whose data is fresh, so a 1 here is a real 1.
        while read -r line; do
          [ -n "$line" ] || continue
          # Split from the RIGHT: the value is the last field, everything before it is
          # the series (whose label values may contain spaces).
          value="''${line##* }"
          series="''${line% *}"
          remote="$(label "$series" remote)"

          case "$series" in
            git_annex_assistant_up*)
              track "$series" "$value" \
                "repo '$repo': the assistant is NOT running — the repo has silently stopped replicating (init still reads active and nothing has failed)" \
                "repo '$repo': the assistant is running again"
              ;;
            git_annex_remote_reachable*)
              track "$series" "$value" \
                "repo '$repo': remote '$remote' is unreachable — history and content are not going anywhere (bad url, missing SSH identity, or the peer is down)" \
                "repo '$repo': remote '$remote' is reachable again"
              ;;
          esac
        done < <(${pkgs.gnugrep}/bin/grep -E '^git_annex_(assistant_up|remote_reachable)\{' "$f" || true)
      done
    '';
}
