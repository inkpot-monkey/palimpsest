# Secret-expiry watcher — ADR-0024. The declared-registry complement to the
# ADR-0019 alerting tier: a daily on-host check that reads the plaintext expiry
# registry (secrets/expiry.nix) and alerts #infra-alerts via the hookshot loopback
# webhook BEFORE a rotatable secret lapses.
#
# Why declared, not probed: a sops value's ciphertext carries no expiry metadata, so
# there is nothing to observe on-disk. The registry is the source of truth (bumped in
# the same commit that rotates the value — see secrets/expiry.nix). A live-probe tier
# (query the provider's API for the REAL expiry, self-healing registry drift) is
# deferred to Phase 2; this covers every secret uniformly with no extra credentials.
#
# Alert semantics mirror the unit-state check: one message when days-remaining first
# crosses each `warnDays` band (30 → 14 → 3 → EXPIRED by default), NO re-spam while it
# sits in a band, and a ✅ notice when the value is renewed (days-remaining climbs back
# above every threshold). Per-secret state lives in $STATE_DIRECTORY as the tightest
# band already alerted, so the daily timer is idempotent.
#
# It also writes `secret_expiry_timestamp_seconds{secret="…"}` to the node-exporter
# textfile dir, so Grafana gets a free "days remaining" gauge — the right idiom for a
# collection-only monitoring stack with no vmalert (the webhook POST IS the alert).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-secret-expiry;

  # Guarded import: on a public clone without the secrets input, fall back to {} (no
  # watched secrets) rather than getSecretPath's identities MOCK, whose shape would
  # crash the eval below.
  registryPath = "${inputs.secrets}/expiry.nix";
  registry = if builtins.pathExists registryPath then import registryPath else { };

  # A registry entry declares expiry as EITHER an absolute `expires` (YYYY-MM-DD) or
  # `issued` + `expiresDays`; resolve both to a single `date -d` spec. Day-math is done
  # in bash (Nix has no date arithmetic) — coreutils `date` resolves the spec at runtime.
  dateSpec = e: e.expires or "${e.issued} + ${toString e.expiresDays} days";

  # Per-secret: emit a `check_secret` invocation the script's loop consumes.
  warnCsv = e: lib.concatMapStringsSep "," toString (e.warnDays or cfg.defaultWarnDays);
  mkCall =
    name: e:
    lib.concatStringsSep " " [
      "check_secret"
      (lib.escapeShellArg name)
      (lib.escapeShellArg (dateSpec e))
      (lib.escapeShellArg (warnCsv e))
      (lib.escapeShellArg (e.runbook or ""))
    ];
  calls = lib.concatStringsSep "\n" (lib.mapAttrsToList mkCall registry);

  checkScript = pkgs.writeShellScript "monitoring-secret-expiry-check" ''
    set -u
    url="$(cat ${lib.escapeShellArg cfg.webhookUrlFile} 2>/dev/null || true)"
    state="$STATE_DIRECTORY"
    now="$(${pkgs.coreutils}/bin/date +%s)"

    # Metrics are best-effort: only when the node-exporter textfile dir exists (the
    # monitoring-exporters profile owns it), so this never fails the alert oneshot.
    metrics_tmp=""
    ${lib.optionalString cfg.writeMetrics ''
      metrics_dir=${lib.escapeShellArg cfg.metricsDir}
      if [ -d "$metrics_dir" ]; then
        metrics_tmp="$(mktemp "$metrics_dir/.secret-expiry.XXXXXX")"
        printf '# HELP secret_expiry_timestamp_seconds Unix time a rotatable secret expires (ADR-0024).\n' >> "$metrics_tmp"
        printf '# TYPE secret_expiry_timestamp_seconds gauge\n' >> "$metrics_tmp"
      else
        echo "secret-expiry: metrics dir $metrics_dir absent — skipping textfile metric" >&2
      fi
    ''}

    post() { # $1 = message text
      if [ -z "$url" ]; then
        echo "secret-expiry: webhook url not available yet, skipping post: $1" >&2
        return 0
      fi
      ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null \
        -H 'content-type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -nc --arg t "$1" '{text:$t}')" \
        "$url" \
        || echo "secret-expiry: failed to POST alert (hookshot down?): $1" >&2
    }

    check_secret() { # $1=name $2=dateSpec $3=warnCsv $4=runbook
      name="$1"; spec="$2"; warncsv="$3"; runbook="$4"

      expiry_epoch="$(${pkgs.coreutils}/bin/date -d "$spec" +%s 2>/dev/null || true)"
      if [ -z "$expiry_epoch" ]; then
        echo "secret-expiry: could not parse expiry for $name (spec=$spec)" >&2
        return 0
      fi
      expiry_date="$(${pkgs.coreutils}/bin/date -d "@$expiry_epoch" +%Y-%m-%d)"
      days_left=$(( (expiry_epoch - now) / 86400 ))

      ${lib.optionalString cfg.writeMetrics ''
        [ -n "$metrics_tmp" ] && printf 'secret_expiry_timestamp_seconds{secret="%s"} %s\n' "$name" "$expiry_epoch" >> "$metrics_tmp"
      ''}

      # Tightest breached band: the smallest warn threshold still >= days_left, or the
      # synthetic -1 band once expired. Unset means nothing breached (healthy).
      tightest=""
      if [ "$days_left" -le 0 ]; then
        tightest=-1
      else
        IFS=',' read -ra thresholds <<< "$warncsv"
        for t in "''${thresholds[@]}"; do
          if [ "$days_left" -le "$t" ] && { [ -z "$tightest" ] || [ "$t" -lt "$tightest" ]; }; then
            tightest="$t"
          fi
        done
      fi

      sf="$state/$name.band"
      prev="$(cat "$sf" 2>/dev/null || true)"

      if [ -n "$tightest" ]; then
        # Alert when entering a band we have not yet reported (first breach, or a
        # tighter band than last time). prev is "" (never), or a number, or "-1".
        if [ -z "$prev" ] || [ "$tightest" -lt "$prev" ]; then
          if [ "$tightest" = "-1" ]; then
            post "🚨 [expiry] $name EXPIRED $(( -days_left )) days ago ($expiry_date) — $runbook"
          else
            post "🔑 [expiry] $name expires in $days_left days ($expiry_date) — $runbook"
          fi
          printf '%s' "$tightest" > "$sf"
        fi
      else
        # Healthy (days_left above every threshold): if we had alerted, it was renewed.
        if [ -n "$prev" ]; then
          post "✅ [expiry] $name renewed — now expires in $days_left days ($expiry_date)"
          rm -f "$sf"
        fi
      fi
    }

    ${calls}

    ${lib.optionalString cfg.writeMetrics ''
      [ -n "$metrics_tmp" ] && ${pkgs.coreutils}/bin/mv -f "$metrics_tmp" "$metrics_dir/secret-expiry.prom"
    ''}
  '';
in
{
  options.custom.profiles.monitoring-secret-expiry = {
    enable = lib.mkEnableOption ''
      the daily secret-expiry watcher (ADR-0024). Reads the plaintext expiry registry
      (secrets/expiry.nix) and alerts #infra-alerts via the hookshot loopback webhook
      before a rotatable secret lapses. Enable on the host that runs
      custom.profiles.matrix.infraAlerts (kelpy), which publishes the webhook url file.
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = config.custom.profiles.matrix.infraAlerts.webhookUrlFile;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile";
      description = ''
        File holding the loopback webhook url, written by the infra-alerts room
        oneshot. The check posts alerts here.
      '';
    };

    defaultWarnDays = lib.mkOption {
      type = lib.types.listOf lib.types.ints.positive;
      default = [
        30
        14
        3
      ];
      description = ''
        Days-remaining thresholds at which to alert, for registry entries that do not
        set their own `warnDays`. One alert fires as each band is first entered.
      '';
    };

    writeMetrics = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also write `secret_expiry_timestamp_seconds{secret="…"}` to the node-exporter
        textfile directory, for a Grafana "days remaining" gauge. Requires the
        monitoring-exporters profile (which owns metricsDir).
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory (see monitoring-exporters).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.webhookUrlFile != config.custom.profiles.matrix.infraAlerts.webhookUrlFile
          || config.custom.profiles.matrix.infraAlerts.enable;
        message = "custom.profiles.monitoring-secret-expiry requires either custom.profiles.matrix.infraAlerts.enable or an explicit webhookUrlFile override.";
      }
    ]
    # Eval-time guard: every registered secret must point at a sops file that exists,
    # so a typo in expiry.nix fails the flake check, not silently at runtime. Skipped
    # when the registry is the {} public-clone fallback.
    ++ lib.mapAttrsToList (name: e: {
      assertion = builtins.pathExists "${inputs.secrets}/${e.file}";
      message = "monitoring-secret-expiry: registry entry '${name}' points at '${e.file}', which does not exist in the secrets input.";
    }) registry
    ++ lib.mapAttrsToList (name: e: {
      assertion = (e ? expires) || (e ? issued && e ? expiresDays);
      message = "monitoring-secret-expiry: registry entry '${name}' must declare either `expires` (absolute date) or `issued` + `expiresDays`.";
    }) registry;

    systemd.services.monitoring-secret-expiry-check = {
      description = "Alert before a rotatable secret expires (ADR-0024)";
      after = [ "matrix-infra-alerts-room.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-secret-expiry";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-secret-expiry-check = {
      description = "Daily secret-expiry check (ADR-0024)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true; # catch up a missed run (host off overnight) at next boot
        RandomizedDelaySec = "1h";
      };
    };
  };
}
