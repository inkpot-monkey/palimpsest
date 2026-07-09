# DMARC non-compliance watcher. The white-box complement to the DMARC exporter
# (modules/.../dmarc-metrics-exporter): a periodic on-host check that queries
# VictoriaMetrics for messages that FAILED DMARC and alerts #infra-alerts via the
# hookshot loopback webhook. Mirrors the secret-expiry / unit-state checks (ADR-0019):
# the webhook POST IS the alert — the monitoring stack is collection-only (no vmalert).
#
# Why this matters at p=reject: a non-compliant message is either (a) YOUR legitimate
# mail failing SPF/DKIM alignment — which at p=reject means it is being REJECTED, silent
# breakage you want to catch — or (b) someone sending as your domain (spoofing). Either
# way it is the one DMARC signal worth acting on for a quiet personal domain; nobody
# watches the dashboard daily.
#
# Signal: track the cumulative non-compliant count (sum(dmarc_total) −
# sum(dmarc_compliant_total)) in $STATE_DIRECTORY and alert only when it INCREASES (new
# failures), with a best-effort per-domain breakdown. Cumulative counters only rise, so a
# drop means the exporter's metrics.db was reset — resync the baseline quietly, no alert.
# Runs where VictoriaMetrics is (rk1b), querying it over loopback.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-dmarc-alert;

  checkScript = pkgs.writeShellScript "monitoring-dmarc-alert-check" ''
    set -u
    url="$(cat ${lib.escapeShellArg cfg.webhookUrlFile} 2>/dev/null || true)"
    state="$STATE_DIRECTORY"
    vm=${lib.escapeShellArg cfg.victoriaMetricsUrl}

    post() { # $1 = message text
      if [ -z "$url" ]; then
        echo "dmarc-alert: webhook url not available yet, skipping post: $1" >&2
        return 0
      fi
      ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null \
        -H 'content-type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -nc --arg t "$1" '{text:$t}')" \
        "$url" \
        || echo "dmarc-alert: failed to POST alert (hookshot down?): $1" >&2
    }

    vmq() { # $1 = promql → prints the scalar result value, or empty
      ${pkgs.curl}/bin/curl -sS -m 10 -G "$vm/api/v1/query" \
        --data-urlencode "query=$1" \
        | ${pkgs.jq}/bin/jq -r '.data.result[0].value[1] // empty'
    }

    # Cumulative non-compliant across all domains/reporters. Both sums always exist while
    # any dmarc series does, so the label-less subtraction resolves to one value.
    nc="$(vmq 'floor(sum(dmarc_total) - sum(dmarc_compliant_total))')"
    if [ -z "$nc" ]; then
      echo "dmarc-alert: no dmarc metrics in VictoriaMetrics yet — nothing to check" >&2
      exit 0
    fi
    nc="''${nc%.*}"

    sf="$state/noncompliant.count"
    prev="$(cat "$sf" 2>/dev/null || echo 0)"

    if [ "$nc" -gt "$prev" ]; then
      delta=$(( nc - prev ))
      # Best-effort per-domain breakdown for the message (matching quirks only affect
      # this context string, never the trigger above).
      bd="$(${pkgs.curl}/bin/curl -sS -m 10 -G "$vm/api/v1/query" \
        --data-urlencode 'query=sum by (from_domain) (dmarc_total - dmarc_compliant_total) > 0' \
        | ${pkgs.jq}/bin/jq -r '[.data.result[]? | "\(.metric.from_domain // "?")=\(.value[1]|tonumber|floor)"] | join(", ")')"
      post "⚠️ [dmarc] $delta message(s) newly FAILED DMARC (cumulative non-compliant: $nc). By domain: ''${bd:-n/a}. Either your mail is failing SPF/DKIM alignment (rejected at p=reject) or someone is sending as your domain — check the dmarc dashboard."
      printf '%s' "$nc" > "$sf"
    elif [ "$nc" -lt "$prev" ]; then
      # Counter went backwards → exporter metrics.db reset. Rebaseline, don't alert.
      printf '%s' "$nc" > "$sf"
    fi
  '';
in
{
  options.custom.profiles.monitoring-dmarc-alert = {
    enable = lib.mkEnableOption ''
      the DMARC non-compliance watcher. Queries VictoriaMetrics and alerts #infra-alerts
      via the hookshot webhook when messages fail DMARC. Enable on the host that runs the
      DMARC exporter + VictoriaMetrics (rk1b); pass a webhookUrlFile (the watcher's
      gatus-webhook-url template on hosts that don't run matrix.infraAlerts).
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
      description = "Base URL of the VictoriaMetrics instance holding the dmarc_* metrics.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar spec for the check (the exporter polls hourly).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.monitoring-dmarc-alert-check = {
      description = "Alert #infra-alerts when mail fails DMARC (ADR-0019)";
      after = [ "victoriametrics.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-dmarc-alert";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-dmarc-alert-check = {
      description = "Periodic DMARC non-compliance check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
