# SMTP TLS Reporting failure watcher. The white-box complement to the TLSRPT
# poller (modules/.../monitoring/tlsrpt.nix): a periodic on-host check that queries
# VictoriaMetrics for FAILED TLS sessions and alerts #infra-alerts via the hookshot
# loopback webhook. Mirrors the dmarc-alert / secret-expiry / unit-state checks
# (ADR-0019): the webhook POST IS the alert — the stack is collection-only (no vmalert).
#
# Why this matters: a TLS failure in a report means a sending MTA that honours your
# MTA-STS/DANE policy could NOT establish secure TLS to your MX — a certificate
# problem, an expired/rotated cert not yet deployed, or an active downgrade attempt.
# At enforce mode those senders DEFER/bounce your inbound mail, so it's silent
# breakage worth catching. Successful-only reports (the normal case) never alert.
#
# Signal: cumulative failed sessions (sum(smtp_tls_report_failure_sessions_total));
# alert only when it INCREASES, with a best-effort per-domain/result-type breakdown.
# Counters only rise, so a drop means the poller's state was wiped (textfile reset) —
# rebaseline quietly, no alert. Runs where VictoriaMetrics is (rk1b).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-tlsrpt-alert;

  checkScript = pkgs.writeShellScript "monitoring-tlsrpt-alert-check" ''
    set -u
    url="$(cat ${lib.escapeShellArg cfg.webhookUrlFile} 2>/dev/null || true)"
    state="$STATE_DIRECTORY"
    vm=${lib.escapeShellArg cfg.victoriaMetricsUrl}

    post() { # $1 = message text
      if [ -z "$url" ]; then
        echo "tlsrpt-alert: webhook url not available yet, skipping post: $1" >&2
        return 0
      fi
      ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null \
        -H 'content-type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -nc --arg t "$1" '{text:$t}')" \
        "$url" \
        || echo "tlsrpt-alert: failed to POST alert (hookshot down?): $1" >&2
    }

    vmq() { # $1 = promql → prints the scalar result value, or empty
      ${pkgs.curl}/bin/curl -sS -m 10 -G "$vm/api/v1/query" \
        --data-urlencode "query=$1" \
        | ${pkgs.jq}/bin/jq -r '.data.result[0].value[1] // empty'
    }

    # Cumulative failed TLS sessions across all domains. The series exists only once a
    # report with any failure has been ingested, so guard for "no data yet".
    fc="$(vmq 'floor(sum(smtp_tls_report_failure_sessions_total))')"
    if [ -z "$fc" ]; then
      echo "tlsrpt-alert: no TLS-failure metric in VictoriaMetrics yet — nothing to check" >&2
      exit 0
    fi
    fc="''${fc%.*}"

    sf="$state/failures.count"
    prev="$(cat "$sf" 2>/dev/null || echo 0)"

    if [ "$fc" -gt "$prev" ]; then
      delta=$(( fc - prev ))
      # Best-effort per-domain + result-type breakdown for the message context.
      bd="$(${pkgs.curl}/bin/curl -sS -m 10 -G "$vm/api/v1/query" \
        --data-urlencode 'query=sum by (policy_domain, result_type) (smtp_tls_report_failures_total) > 0' \
        | ${pkgs.jq}/bin/jq -r '[.data.result[]? | "\(.metric.policy_domain // "?")/\(.metric.result_type // "?")=\(.value[1]|tonumber|floor)"] | join(", ")')"
      post "🔒 [tlsrpt] $delta new failed TLS session(s) reported (cumulative: $fc). A sender honouring your MTA-STS/DANE policy could not negotiate secure TLS to the MX — check for a cert problem or downgrade. Breakdown: ''${bd:-n/a}. See the SMTP TLS Reporting dashboard."
      printf '%s' "$fc" > "$sf"
    elif [ "$fc" -lt "$prev" ]; then
      # Counter went backwards → poller state/textfile reset. Rebaseline, don't alert.
      printf '%s' "$fc" > "$sf"
    fi
  '';
in
{
  options.custom.profiles.monitoring-tlsrpt-alert = {
    enable = lib.mkEnableOption ''
      the SMTP TLS Reporting failure watcher. Queries VictoriaMetrics and alerts
      #infra-alerts via the hookshot webhook when a TLS report records failed
      sessions. Enable on the host that runs the TLSRPT poller + VictoriaMetrics
      (rk1b); pass a webhookUrlFile (the watcher's gatus-webhook-url template on
      hosts that don't run matrix.infraAlerts).
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = config.custom.profiles.monitoring-watcher.webhookUrlFile;
      defaultText = lib.literalExpression "config.custom.profiles.monitoring-watcher.webhookUrlFile";
      description = "File holding the #infra-alerts hookshot webhook url the check posts to.";
    };

    victoriaMetricsUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:8428";
      description = "Base URL of the VictoriaMetrics instance holding the smtp_tls_report_* metrics.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar spec for the check (the poller runs hourly).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.monitoring-tlsrpt-alert-check = {
      description = "Alert #infra-alerts when a TLS report records failed sessions (ADR-0019)";
      after = [ "victoriametrics.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-tlsrpt-alert";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-tlsrpt-alert-check = {
      description = "Periodic SMTP TLS Reporting failure check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
