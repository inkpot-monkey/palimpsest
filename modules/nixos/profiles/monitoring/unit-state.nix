# The on-host unit-state check — ADR-0019, the white-box layer that complements
# the off-host Gatus reachability probe. Runs on the watched host itself and
# alerts to #infra-alerts (via the hookshot loopback webhook) when an
# expected-up systemd unit is not `active`.
#
# Why this exists ALONGSIDE the reachability probe: the two are blind in
# different places. The reachability probe misses a unit that exits cleanly yet
# dead (stalwart's store-misconfig abort exits 0 → `inactive`, never `failed`) on
# a port that another process or a stale socket still answers; this check sees
# `is-active != active` directly. Conversely it cannot see degraded-but-running
# (qbittorrent stayed `active` while broken) — that is the probe's job.
#
# It deliberately checks an EXPLICIT expected-up list, not "enabled but not
# active": oneshots and timer jobs are `inactive` by design and would spam. The
# list is curated per host (these unit names are host-specific) in the host
# config — see hosts/kelpy.
#
# Quiet semantics mirror the probe: a unit must read non-active for
# `failureThreshold` consecutive ticks (~2 min, absorbing deploy/restart blips)
# before alerting, a recovery notice is sent when it returns, and there are no
# periodic re-alerts while it stays down.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-unit-state;

  # Shared delivery (see alert-post.nix): in-band to #infra-alerts, falling back to the
  # ADR-0020 push relay when that POST fails — the webhook routes through kelpy, so an
  # alert ABOUT kelpy was previously guaranteed to be dropped. The fallback is picked up
  # automatically on a host whose uptime watcher declares the relay, and is null (i.e.
  # previous behaviour, exactly) everywhere else.
  alertPost = import ../../../shared/alert-post.nix { inherit lib pkgs; };

  checkScript = pkgs.writeShellScript "monitoring-unit-state-check" ''
    set -u
    host="$(${pkgs.inetutils}/bin/hostname)"
    state="$STATE_DIRECTORY"

    ${alertPost.mkPost {
      name = "unit-state";
      inherit (cfg) webhookUrlFile;
      outOfBand = alertPost.oobFromWatcher config;
    }}

    threshold=${toString cfg.failureThreshold}

    for u in ${lib.escapeShellArgs cfg.units}; do
      active="$(${pkgs.systemd}/bin/systemctl is-active "$u" 2>/dev/null || true)"
      cf="$state/$u.count"      # consecutive non-active ticks
      rf="$state/$u.reported"   # last reported state: up | down

      reported="$(cat "$rf" 2>/dev/null || echo up)"

      if [ "$active" = "active" ]; then
        rm -f "$cf"
        if [ "$reported" = "down" ]; then
          post "✅ [$host] $u recovered — now active"
          printf up > "$rf"
        fi
      else
        count="$(cat "$cf" 2>/dev/null || echo 0)"
        count=$((count + 1))
        printf '%s' "$count" > "$cf"
        if [ "$count" -ge "$threshold" ] && [ "$reported" != "down" ]; then
          post "🚨 [$host] $u is $active (expected active)"
          printf down > "$rf"
        fi
      fi
    done
  '';
in
{
  options.custom.profiles.monitoring-unit-state = {
    enable = lib.mkEnableOption ''
      the on-host systemd unit-state check (ADR-0019). Polls an explicit
      expected-up unit list and alerts to #infra-alerts via the hookshot loopback
      webhook when a unit is not active. Enable on the watched host (kelpy);
      requires custom.profiles.matrix.infraAlerts (which publishes the webhook
      url file).
    '';

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "caddy.service"
        "stalwart.service"
      ];
      description = ''
        The expected-up systemd units. Curated per host because these names are
        host-specific. A unit must read non-active for failureThreshold
        consecutive ticks before it alerts. Do NOT list oneshots or timer-driven
        jobs (they are inactive by design and would spam).
      '';
    };

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = config.custom.profiles.matrix.infraAlerts.webhookUrlFile;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile";
      description = ''
        File holding the loopback webhook url, written by the infra-alerts room
        oneshot. The check posts alerts here.
      '';
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "How often (seconds) to poll unit states.";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Consecutive non-active polls before alerting (debounce that absorbs
        deploy/restart blips). With the default 60s interval, 2 ≈ a 2-minute grace.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Allow an explicit webhookUrlFile override (e.g. from monitoring-watcher on rk1b)
        # without requiring the full matrix.infraAlerts provisioner.
        assertion =
          cfg.webhookUrlFile != config.custom.profiles.matrix.infraAlerts.webhookUrlFile
          || config.custom.profiles.matrix.infraAlerts.enable;
        message = "custom.profiles.monitoring-unit-state requires either custom.profiles.matrix.infraAlerts.enable or an explicit webhookUrlFile override.";
      }
      {
        assertion = cfg.units != [ ];
        message = "custom.profiles.monitoring-unit-state.enable is set but units is empty — nothing would be checked.";
      }
    ];

    systemd.services.monitoring-unit-state-check = {
      description = "Alert when an expected-up systemd unit is not active (ADR-0019)";
      after = [ "matrix-infra-alerts-room.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-unit-state";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-unit-state-check = {
      description = "Periodic on-host unit-state check (ADR-0019)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "${toString cfg.intervalSec}s";
        AccuracySec = "10s";
      };
    };
  };
}
