# git-annex replication watcher — palimpsest#60. The alerting half of the health
# signal whose measuring half is `services.git-annex.metrics` (see
# modules/nixos/services/git-annex/metrics.nix, which explains what each series means
# and why last_commit is deliberately not one of them).
#
# The split is the point. The service module MEASURES: it knows the repos, owns the
# privilege drop, and publishes `git_annex_*` to the node-exporter textfile dir on
# every git-annex host, whether or not anybody alerts on it. This profile is POLICY:
# it reads those published series and decides what is worth waking someone for. So the
# module stays free of any webhook or Matrix coupling, and adding a repo anywhere on
# the fleet needs no change here — the series appear and are watched.
#
# Reading our own textfiles rather than querying VictoriaMetrics is deliberate: the
# check then runs on the host that owns the repo, needs no network, and keeps working
# when the very link it is reporting on is down. It costs one blind spot — a dead
# exporter leaves a stale file reading `1` forever — which is exactly what
# `git_annex_check_timestamp_seconds` and the staleness check below exist to close. A
# watcher that cannot notice its own source has died is not a watcher.
#
# Quiet semantics mirror the unit-state check: a condition must read bad for
# `failureThreshold` consecutive ticks before it alerts (absorbing deploy/restart
# blips), a recovery notice is sent when it clears, and there are no periodic
# re-alerts while it stays bad.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-git-annex-alert;
  repos = lib.attrNames config.services.git-annex.repositories;

  checkScript = pkgs.writeShellScript "monitoring-git-annex-alert-check" ''
    set -u
    host="$(${pkgs.inetutils}/bin/hostname)"
    url="$(cat ${lib.escapeShellArg cfg.webhookUrlFile} 2>/dev/null || true)"
    state="$STATE_DIRECTORY"
    metrics_dir=${lib.escapeShellArg cfg.metricsDir}
    now="$(${pkgs.coreutils}/bin/date +%s)"
    threshold=${toString cfg.failureThreshold}

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
      reported="$(cat "$rf" 2>/dev/null || echo up)"

      if [ "$2" = "1" ]; then
        rm -f "$cf"
        if [ "$reported" = "down" ]; then
          post "✅ [$host] git-annex — $4"
          printf up > "$rf"
        fi
      else
        count="$(cat "$cf" 2>/dev/null || echo 0)"
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
    for repo in ${lib.escapeShellArgs repos}; do
      f="$metrics_dir/git-annex-$repo.prom"

      if [ ! -e "$f" ]; then
        track "meta:$repo" 0 \
          "repo '$repo' has published no health metrics at all — git-annex-metrics-$repo.service has never completed, so this repo is UNMONITORED" \
          "repo '$repo' is publishing health metrics again"
        continue
      fi

      ts="$(${pkgs.gnugrep}/bin/grep '^git_annex_check_timestamp_seconds' "$f" | ${pkgs.gawk}/bin/awk '{print $NF}')"
      if [ -z "$ts" ]; then
        track "meta:$repo" 0 \
          "repo '$repo' publishes metrics with no check timestamp — cannot tell fresh data from stale" \
          "repo '$repo' is publishing a check timestamp again"
        continue
      fi

      age=$(( now - ts ))
      if [ "$age" -gt ${toString cfg.staleAfterSec} ]; then
        track "meta:$repo" 0 \
          "repo '$repo' health data is stale ($age s old) — git-annex-metrics-$repo.service has stopped running, so every reading below is frozen and meaningless" \
          "repo '$repo' health data is fresh again"
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
in
{
  options.custom.profiles.monitoring-git-annex-alert = {
    enable = lib.mkEnableOption ''
      the git-annex replication watcher (palimpsest#60). Reads the per-repo health
      metrics published by `services.git-annex.metrics` on this host and alerts
      #infra-alerts via the hookshot webhook when a repo stops replicating. Enable on
      every host that owns a git-annex repository; pass a webhookUrlFile on hosts that
      do not run custom.profiles.matrix.infraAlerts (which publishes the default)
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = config.custom.profiles.matrix.infraAlerts.webhookUrlFile;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile";
      description = "File holding the #infra-alerts hookshot webhook url the check posts to.";
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = config.services.git-annex.metrics.metricsDir;
      defaultText = lib.literalExpression "config.services.git-annex.metrics.metricsDir";
      description = "Directory holding the git-annex-<repo>.prom files this check reads.";
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How often (seconds) to re-read the published metrics. Cheap — this only reads
        local files; the SSH probing happens in the exporter, on its own slower timer.
      '';
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Consecutive bad reads before alerting (debounce that absorbs deploy/restart
        blips — a deploy restarts the assistant). With the default 60s interval, 2 ≈ a
        two-minute grace.
      '';
    };

    staleAfterSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        Age at which a repo's published metrics count as stale (and the repo as
        unmonitored) rather than as readings. Must comfortably clear
        `services.git-annex.metrics.interval` — the default 15min tolerates two missed
        five-minute checks before crying wolf.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Allow an explicit webhookUrlFile override (e.g. the watcher's template on
        # rk1b) without requiring the kelpy-only infraAlerts provisioner.
        assertion =
          cfg.webhookUrlFile != config.custom.profiles.matrix.infraAlerts.webhookUrlFile
          || config.custom.profiles.matrix.infraAlerts.enable;
        message = "custom.profiles.monitoring-git-annex-alert requires either custom.profiles.matrix.infraAlerts.enable or an explicit webhookUrlFile override.";
      }
      {
        assertion = config.services.git-annex.enable && config.services.git-annex.metrics.enable;
        message = "custom.profiles.monitoring-git-annex-alert reads the metrics published by services.git-annex.metrics — enable git-annex and its metrics on this host, or drop the alert profile.";
      }
      {
        assertion = repos != [ ];
        message = "custom.profiles.monitoring-git-annex-alert.enable is set but this host declares no services.git-annex.repositories — nothing would be checked.";
      }
      {
        assertion = cfg.staleAfterSec > cfg.intervalSec;
        message = "custom.profiles.monitoring-git-annex-alert: staleAfterSec must exceed intervalSec (and services.git-annex.metrics.interval), or every repo would read as stale.";
      }
    ];

    systemd.services.monitoring-git-annex-alert-check = {
      description = "Alert when a git-annex repository stops replicating (palimpsest#60)";
      after = [ "matrix-infra-alerts-room.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-git-annex-alert";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-git-annex-alert-check = {
      description = "Periodic git-annex replication check (palimpsest#60)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min"; # after the exporter's OnBootSec=2min, so the first read has data
        OnUnitActiveSec = "${toString cfg.intervalSec}s";
        AccuracySec = "10s";
      };
    };
  };
}
