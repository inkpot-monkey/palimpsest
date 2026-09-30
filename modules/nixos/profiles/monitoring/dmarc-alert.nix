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
# Signal: two triggers, each tracking a cumulative counter's baseline in
# $STATE_DIRECTORY and firing when it RISES. Cumulative counters only rise, so a DROP
# means the exporter's metrics.db was reset — rebaseline quietly, never alert.
# Runs where VictoriaMetrics is (rk1b), querying it over loopback.
#
#   1. ENFORCED (any rise): sum(dmarc_reject_total) + sum(dmarc_quarantine_total) — a
#      receiver ACTED on a DMARC failure. This is the consequential signal, and it covers
#      both cases above: legitimate mail failing alignment is rejected at p=reject, and a
#      spoofer reaching any enforcing receiver is rejected too.
#
#   2. BURST backstop (a rise of >= burstThreshold in ONE check): the raw non-compliant
#      count, sum(dmarc_total) − sum(dmarc_compliant_total). Covers the residual gap in
#      (1) — a receiver that reports but does not enforce logs genuine spoofing as
#      disposition=none, which never touches the reject/quarantine counters.
#
# WHY (1) IS NOT THE RAW NON-COMPLIANT COUNT, which is what this watcher alerted on until
# 2026-09-30: that count includes messages which failed DMARC but were DELIVERED ANYWAY,
# and in practice that class is entirely our own mail passing through a forwarder. A Gmail
# account auto-forwarding your mail breaks SPF (the relay is not in `v=spf1 mx -all`) and
# can mangle the body enough to break DKIM, and Google then delivers it regardless under
# its own ARC override — `disposition=none` with
# `<reason><type>local_policy</type><comment>arc=pass</comment></reason>`. That is
# inherent to SPF/DKIM plus forwarding, there is nothing to fix, and because the trigger
# watched a cumulative counter EVERY such forward re-tripped it (2026-09-04 and
# 2026-09-29 were both exactly this, same relay 209.85.220.69, both benign). Excluding it
# by reason would need a label dmarc-metrics-exporter does not expose — it aggregates
# source_ip and reason away — i.e. an upstream change. Keying on disposition gets the same
# exclusion for free, since an ARC-overridden forward is delivered by definition. The raw
# count stays on the Email dashboard, visible without paging.
#
# The burst backstop is deliberately WINDOW-scoped rather than cumulative: the baseline
# advances on every check, so sub-threshold rises are dropped instead of accumulating into
# an alert months later. That is the point — a slow trickle IS the known-benign forward
# class, and letting five of them add up would restore the noise this removes.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-dmarc-alert;

  # Shared delivery (see alert-post.nix): in-band to #infra-alerts, falling back to the
  # ADR-0020 push relay when that POST fails — the webhook routes through kelpy, so an
  # alert ABOUT kelpy was previously guaranteed to be dropped. The fallback is picked up
  # automatically on a host whose uptime watcher declares the relay, and is null (i.e.
  # previous behaviour, exactly) everywhere else.
  alertPost = import ../../../shared/alert-post.nix { inherit lib pkgs; };

  checkScript = pkgs.writeShellScript "monitoring-dmarc-alert-check" ''
    set -u
    state="$STATE_DIRECTORY"
    vm=${lib.escapeShellArg cfg.victoriaMetricsUrl}

    ${alertPost.mkPost {
      name = "dmarc-alert";
      inherit (cfg) webhookUrlFile;
      outOfBand = alertPost.oobFromWatcher config;
    }}

    vmq() { # $1 = promql → prints the scalar result value, or empty
      ${pkgs.curl}/bin/curl -sS -m 10 -G "$vm/api/v1/query" \
        --data-urlencode "query=$1" \
        | ${pkgs.jq}/bin/jq -r '.data.result[0].value[1] // empty'
    }

    # Best-effort per-sender-domain breakdown for an alert's context string. Matching
    # quirks here only affect the prose, never a trigger.
    breakdown() { # $1 = promql → "domain=n, domain=n", or empty
      ${pkgs.curl}/bin/curl -sS -m 10 -G "$vm/api/v1/query" \
        --data-urlencode "query=$1" \
        | ${pkgs.jq}/bin/jq -r '[.data.result[]? | "\(.metric.from_domain // "?")=\(.value[1]|tonumber|floor)"] | join(", ")'
    }

    # Rise-tracking against a baseline file: prints the delta when the counter rose by at
    # least $3, silent otherwise. Always leaves the baseline at the current value, so a
    # rise below the threshold is dropped rather than carried forward (window, not
    # cumulative — see the header), and a DROP is an exporter metrics.db reset, which
    # rebaselines without alerting.
    track() { # $1 = state file, $2 = current value, $3 = min delta to report
      local sf="$state/$1" prev delta
      if [ ! -e "$sf" ]; then
        # First observation on this host: seed the baseline and stay quiet. There is no
        # rise without a prior sample, and counting the seed as one would alert on the
        # entire accumulated history the first time the watcher runs (or any time its
        # StateDirectory is new), reporting years of counter as a single-check burst.
        printf '%s' "$2" > "$sf"
        return 0
      fi
      prev="$(cat "$sf" 2>/dev/null || true)"
      prev="''${prev:-0}" # a truncated write
      printf '%s' "$2" > "$sf"
      [ "$2" -gt "$prev" ] || return 0
      delta=$(( $2 - prev ))
      [ "$delta" -ge "$3" ] && printf '%s' "$delta"
      return 0
    }

    # Cumulative non-compliant across all domains/reporters. Every dmarc_* series carries
    # the same label set, so these label-less sums each resolve to one value; the guard
    # doubles as the "exporter has parsed no report yet" check.
    nc="$(vmq 'floor(sum(dmarc_total) - sum(dmarc_compliant_total))')"
    if [ -z "$nc" ]; then
      echo "dmarc-alert: no dmarc metrics in VictoriaMetrics yet — nothing to check" >&2
      exit 0
    fi
    nc="''${nc%.*}"

    # (1) Enforced: a receiver rejected or quarantined mail claiming one of our domains.
    # The exporter emits dmarc_reject_total/dmarc_quarantine_total for every label set it
    # emits dmarc_total for (at 0 until something is actually enforced), so $nc being
    # non-empty already proves these series exist. An empty result here is therefore a
    # transient query failure and NOT a zero: skip the trigger and leave the baseline
    # untouched, because treating it as 0 would rebaseline it as a counter reset and then
    # alert on the recovery.
    en="$(vmq 'floor(sum(dmarc_reject_total) + sum(dmarc_quarantine_total))')"
    if [ -z "$en" ]; then
      echo "dmarc-alert: enforced-disposition query returned nothing — skipping trigger 1" >&2
    else
      en="''${en%.*}"
      if [ -n "$(track enforced.count "$en" 1)" ]; then
        bd="$(breakdown 'sum by (from_domain) (dmarc_reject_total + dmarc_quarantine_total) > 0')"
        post "🚨 [dmarc] a receiver REJECTED or QUARANTINED mail claiming your domain (cumulative enforced: $en). By domain: ''${bd:-n/a}. Unlike a failed-but-delivered forward this is real: either your mail is failing SPF/DKIM alignment and is being rejected at p=reject, or someone is sending as your domain. Check the Email dashboard."
      fi
    fi

    # (2) Burst backstop on the raw count, for spoofing that a non-enforcing reporter logs
    # as disposition=none. A trickle of forwarder-mangled messages never reaches it.
    burst="$(track noncompliant.count "$nc" ${toString cfg.burstThreshold})"
    if [ -n "$burst" ]; then
      bd="$(breakdown 'sum by (from_domain) (dmarc_total - dmarc_compliant_total) > 0')"
      post "⚠️ [dmarc] $burst message(s) failed DMARC in a single check (cumulative non-compliant: $nc), over the burst threshold of ${toString cfg.burstThreshold}. By domain: ''${bd:-n/a}. Isolated failures are normally a forwarder breaking SPF/DKIM in transit and are not alerted; this many at once is not. Check the Email dashboard."
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

    burstThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        How many newly non-compliant messages in a single check trip the burst backstop.
        Sized above the forwarder noise floor: a message that fails DMARC but is
        DELIVERED anyway is, in practice, our own mail relayed by a forwarder that broke
        SPF/DKIM in transit, and those arrive one at a time. Enforced failures are the
        other trigger's job; this one exists purely for spoofing that a non-enforcing
        reporter logs as disposition=none.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar spec for the check (the exporter polls hourly).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.monitoring-dmarc-alert-check = {
      description = "Alert #infra-alerts when mail claiming our domain is rejected or quarantined (ADR-0019)";
      after = [ "victoriametrics.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-dmarc-alert";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-dmarc-alert-check = {
      description = "Periodic DMARC enforced-disposition check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
